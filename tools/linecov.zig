//! **WHICH LINES OF A SOURCE FILE A TEST BINARY RAN**: line coverage for
//! zig's unit tests, with no kcov (zig-metal-unikernel's tools/linecov.py,
//! ported; metal-vmm QUEUE 241 B).
//!
//!     linecov src/tcp.zig <test binary> [<test binary> ...]
//!
//! Each binary is run once under ptrace with a one-shot breakpoint (0xCC) at
//! the first address of every line of the file, from its DWARF line table
//! (`readelf --debug-dump=decodedline`); a breakpoint hit records its lines
//! and is put back as it was. The verdict is the union over the binaries:
//! lines run, lines with code that never ran, each printed with its text.
//!
//! A line the compiler emitted no code for (a comment, a declaration, code
//! it inlined away) has no address, so it is neither run nor missed. Nor is
//! a line that is only a closing brace: Debug code gives a function's `}` an
//! address of its own, which a function that ends in `return` never reaches.
//! A binary must be a fixed-address (non-PIE) x86-64 Linux executable, as
//! `zig build test` makes them; one that does not exit 0 fails the measure,
//! since its coverage is short.
//!
//! **THE LINE TABLE IS readelf's, NOT std.debug.Dwarf's**: Zig's keeps one
//! row per address (`LineNumberProgram.addRow` puts it in a map keyed by the
//! address, a later row replacing an earlier), where readelf lists every
//! row and linecov.py takes every line a row names at an address. Reading
//! the same table as the Python makes the two agree on what a file's lines
//! are, so what is left to compare is the tracing.

const std = @import("std");
const linux = std.os.linux;

const PTRACE = linux.PTRACE;
/// user_regs_struct's rip, in 8-byte words.
const rip = 16;

/// {address: lines} for the lines of `source` (a path ending) in `binary`.
const Table = std.AutoArrayHashMapUnmanaged(usize, []const u32);

fn lineTable(a: std.mem.Allocator, io: std.Io, binary: []const u8, source_abs: []const u8, source_base: []const u8) !Table {
    const out = try std.process.run(a, io, .{
        .argv = &.{ "readelf", "--debug-dump=decodedline", binary },
        .stdout_limit = .unlimited,
    });
    var lists: std.AutoArrayHashMapUnmanaged(usize, std.ArrayList(u32)) = .empty;
    // A test's root file is named bare (`tcp.zig:`); every other file by
    // its whole path.
    var current: []const u8 = "";
    var rows = std.mem.splitScalar(u8, out.stdout, '\n');
    rows: while (rows.next()) |row| {
        if (row.len > 0 and row[row.len - 1] == ':' and std.mem.indexOfScalar(u8, row, ' ') == null) {
            current = row[0 .. row.len - 1];
            continue;
        }
        if (!(std.mem.eql(u8, current, source_abs) or std.mem.eql(u8, current, source_base))) continue;
        // `(\S+)\s+(\d+)\s+(0x[0-9a-f]+)` from the row's start.
        if (row.len == 0 or std.ascii.isWhitespace(row[0])) continue;
        var words = std.mem.tokenizeAny(u8, row, " \t\r\x0b\x0c");
        _ = words.next() orelse continue;
        const line_word = words.next() orelse continue;
        const addr_word = words.next() orelse continue;
        for (line_word) |c| if (!std.ascii.isDigit(c)) continue :rows;
        const line = std.fmt.parseInt(u32, line_word, 10) catch continue;
        if (!std.mem.startsWith(u8, addr_word, "0x")) continue;
        var end: usize = 2;
        while (end < addr_word.len and (std.ascii.isDigit(addr_word[end]) or (addr_word[end] >= 'a' and addr_word[end] <= 'f'))) end += 1;
        if (end == 2) continue;
        const addr = std.fmt.parseInt(usize, addr_word[2..end], 16) catch continue;
        const slot = try lists.getOrPut(a, addr);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        for (slot.value_ptr.items) |l| {
            if (l == line) break;
        } else try slot.value_ptr.append(a, line);
    }
    var table: Table = .empty;
    for (lists.keys(), lists.values()) |addr, l| try table.put(a, addr, l.items);
    return table;
}

fn check(rc: usize, what: []const u8) !void {
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        std.debug.print("linecov: {s}: {t}\n", .{ what, e });
        return error.Ptrace;
    }
}

fn peek(pid: linux.pid_t, addr: usize) !usize {
    var word: usize = undefined;
    try check(linux.ptrace(PTRACE.PEEKTEXT, pid, addr, @intFromPtr(&word), 0), "peek");
    return word;
}

/// Writes one byte at `addr`; returns the byte that was there.
fn pokeByte(pid: linux.pid_t, addr: usize, byte: u8) !u8 {
    const base = addr & ~@as(usize, 7);
    var word = try peek(pid, base);
    const shift: u6 = @intCast((addr - base) * 8);
    const old: u8 = @truncate(word >> shift);
    word = (word & ~(@as(usize, 0xFF) << shift)) | (@as(usize, byte) << shift);
    try check(linux.ptrace(PTRACE.POKETEXT, pid, base, word, 0), "poke");
    return old;
}

const Regs = [27]u64;

/// Runs `binary` to its end, the lines it hit added to `hit`; its exit
/// status, or minus the signal that ended it.
fn run(a: std.mem.Allocator, binary: [:0]const u8, envp: [*:null]const ?[*:0]const u8, table: Table, hit: *std.AutoArrayHashMapUnmanaged(u32, void)) !i32 {
    const fork_rc = linux.fork();
    try check(fork_rc, "fork");
    const pid: linux.pid_t = @intCast(fork_rc);
    if (pid == 0) {
        _ = linux.ptrace(PTRACE.TRACEME, 0, 0, 0, 0);
        const argv = [_:null]?[*:0]const u8{binary.ptr};
        _ = linux.execve(binary.ptr, &argv, envp);
        linux.exit(127);
    }
    var status: u32 = undefined;
    try check(linux.waitpid(pid, @ptrCast(&status), 0), "wait"); // stopped at the exec
    var saved: std.AutoArrayHashMapUnmanaged(usize, u8) = .empty;
    for (table.keys()) |addr| try saved.put(a, addr, try pokeByte(pid, addr, 0xCC));
    var sig: usize = 0;
    while (true) {
        try check(linux.ptrace(PTRACE.CONT, pid, 0, sig, 0), "cont");
        try check(linux.waitpid(pid, @ptrCast(&status), 0), "wait");
        if (linux.W.IFEXITED(status)) return linux.W.EXITSTATUS(status);
        if (linux.W.IFSIGNALED(status)) return -@as(i32, @intCast(@backingInt(linux.W.TERMSIG(status))));
        const stop = linux.W.STOPSIG(status);
        sig = @backingInt(stop);
        if (stop != .TRAP) continue; // passed on to the program at the next continue
        var regs: Regs = undefined;
        try check(linux.ptrace(PTRACE.GETREGS, pid, 0, @intFromPtr(&regs), 0), "getregs");
        const at = regs[rip] -% 1;
        if (saved.fetchSwapRemove(at)) |kv| {
            for (table.get(at).?) |l| try hit.put(a, l, {});
            _ = try pokeByte(pid, at, kv.value);
            regs[rip] = at;
            try check(linux.ptrace(PTRACE.SETREGS, pid, 0, @intFromPtr(&regs), 0), "setregs");
            sig = 0;
        }
    }
}

fn lessThan(_: void, x: u32, y: u32) bool {
    return x < y;
}

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    var out_buf: [4096]u8 = undefined;
    var out_w = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};
    if (args.len < 3) {
        try out.writeAll("linecov src/tcp.zig <test binary> [<test binary> ...]\n");
        return 2;
    }
    const source = args[1];
    const binaries = args[2..];
    const cwd = try std.process.currentPathAlloc(io, a);
    const source_abs = try std.fs.path.resolve(a, &.{ cwd, source });
    const source_base = std.fs.path.basename(source);
    const file_text = try std.Io.Dir.cwd().readFileAlloc(io, source, a, .unlimited);
    var text: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, file_text, '\n');
    while (it.next()) |l| try text.append(a, std.mem.trimEnd(u8, l, "\r"));
    if (text.items.len > 0 and std.mem.endsWith(u8, file_text, "\n")) _ = text.pop();
    const envp: [*:null]const ?[*:0]const u8 = init.minimal.environ.block.slice.ptr;

    var have: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    var ran: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    var crashed: std.ArrayList([]const u8) = .empty;
    for (binaries) |b| {
        const table = try lineTable(a, io, b, source_abs, source_base);
        if (table.count() == 0) continue; // another binary's tests reach this file, not this one's
        for (table.values()) |lines| for (lines) |n| {
            if (n == 0 or n > text.items.len) continue;
            if (!std.mem.eql(u8, std.mem.trim(u8, text.items[n - 1], " \t\r\n\x0b\x0c"), "}")) try have.put(a, n, {});
        };
        const code = try run(a, b, envp, table, &ran);
        if (code != 0) {
            try out.print("linecov: {s} exited {d}: its coverage is short\n", .{ std.fs.path.basename(b), code });
            try crashed.append(a, std.fs.path.basename(b));
        }
    }
    if (have.count() == 0) {
        try out.print("linecov: none of the {d} binaries has a line of {s}\n", .{ binaries.len, source });
        return 2;
    }
    var ran_count: usize = 0;
    var missed: std.ArrayList(u32) = .empty;
    for (have.keys()) |n| {
        if (ran.contains(n)) ran_count += 1 else try missed.append(a, n);
    }
    std.mem.sort(u32, missed.items, {}, lessThan);
    const pct = 100.0 * @as(f64, @floatFromInt(ran_count)) / @as(f64, @floatFromInt(have.count()));
    try out.print("{s}: {d} of {d} lines with code ran ({d:.1}%), over {d} binaries\n", .{ source, ran_count, have.count(), pct, binaries.len });
    for (missed.items) |n| {
        const line = std.mem.trim(u8, text.items[n - 1], " \t\r\n\x0b\x0c");
        try out.print("  {d:>5}  {s}\n", .{ n, firstCodepoints(line, 100) });
    }
    // **A BINARY THAT DID NOT FINISH FAILS THE MEASURE** (metal-vmm 146(d)):
    // a crash anywhere cuts every file's coverage short, and a short measure
    // read as a clean one hides it.
    if (crashed.items.len > 0) {
        try out.writeAll("linecov: FAILED: ");
        for (crashed.items, 0..) |c, i| try out.print("{s}{s}", .{ if (i == 0) "" else ", ", c });
        try out.writeAll(" did not finish; the lines above are short\n");
        return 1;
    }
    return 0;
}

/// The first `n` code points of `s` (Python's `s[:n]`), or its bytes as they
/// are where it is not UTF-8.
fn firstCodepoints(s: []const u8, n: usize) []const u8 {
    var view = std.unicode.Utf8View.init(s) catch return s[0..@min(s.len, n)];
    var iter = view.iterator();
    var count: usize = 0;
    while (count < n) : (count += 1) {
        _ = iter.nextCodepointSlice() orelse break;
    }
    return s[0..iter.i];
}
