//! **WHICH LINES OF A SOURCE FILE A TEST BINARY RAN**: line coverage for
//! zig's unit tests, with no kcov (zig-metal-unikernel's tools/linecov.py,
//! ported; metal-vmm QUEUE 241 B).
//!
//!     linecov src/tcp.zig <test binary> [<test binary> ...]
//!     linecov <source> [<source> ...] -- <test binary> [<test binary> ...]
//!
//! The second form (not the Python's) measures every source named over one
//! run of each binary, and prints each one's report, in the order named, as
//! the first form prints it: a binary that runs a minute is run once, not
//! once a file.
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
//! are, so what is left to compare is the tracing. `decodedline` prints no
//! column, so each row's comes from the raw line program (`rawline`), which
//! makes the same rows in the same order: the two are read side by side, and
//! a row at another address than its column's stops the measure.
//!
//! **A ROW IS REFUSED, AND COUNTED,** when its line is past the file's end,
//! holds no code, or ends before the row's column (`refused`): Zig 0.17.0's
//! misplaced generic rows (metal-vmm QUEUE 243). The report says how many.

const std = @import("std");
const linux = std.os.linux;

const PTRACE = linux.PTRACE;
/// user_regs_struct's rip, in 8-byte words.
const rip = 16;

/// A source measured: its path as named, the two names readelf may give
/// it, and its lines.
const Source = struct {
    path: []const u8,
    abs: []const u8,
    base: []const u8,
    text: []const []const u8,
};

/// A line of a source: `source << 32 | line`.
const Key = u64;

fn key(source: usize, line: u32) Key {
    return @as(Key, source) << 32 | line;
}

/// {address: the lines of the sources whose first row is there} in `binary`,
/// and how many rows of each source were refused.
const Table = struct {
    lines: std.AutoArrayHashMapUnmanaged(usize, []const Key),
    refused: []usize,
};

/// A row of the line program, as readelf's `rawline` dump gives it: the
/// address and the column `decodedline` leaves out.
const Column = struct { addr: usize, column: u32 };

fn lineTable(a: std.mem.Allocator, io: std.Io, binary: []const u8, sources: []const Source) !Table {
    const decoded = try std.process.run(a, io, .{
        .argv = &.{ "readelf", "--debug-dump=decodedline", binary },
        .stdout_limit = .unlimited,
    });
    const raw = try std.process.run(a, io, .{
        .argv = &.{ "readelf", "--debug-dump=rawline", binary },
        .stdout_limit = .unlimited,
    });
    return parseTable(a, decoded.stdout, try parseColumns(a, raw.stdout), sources);
}

/// Every row's address and column, in the order the line programs make them,
/// which is the order `decodedline` lists them in.
fn parseColumns(a: std.mem.Allocator, raw: []const u8) ![]const Column {
    var rows: std.ArrayList(Column) = .empty;
    var addr: usize = 0;
    var column: u32 = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |l| {
        if (after(l, "Set column to ")) |rest| {
            column = std.fmt.parseInt(u32, firstWord(rest), 10) catch continue;
        } else if (after(l, "set Address to 0x")) |rest| {
            addr = std.fmt.parseInt(usize, firstWord(rest), 16) catch continue;
        } else if (std.mem.indexOf(u8, l, "Advance PC by ") != null) {
            addr = std.fmt.parseInt(usize, firstWord(after(l, " to 0x") orelse continue), 16) catch continue;
        } else if (std.mem.indexOf(u8, l, "Special opcode ") != null) {
            addr = std.fmt.parseInt(usize, firstWord(after(l, " to 0x") orelse continue), 16) catch continue;
            try rows.append(a, .{ .addr = addr, .column = column });
        } else if (std.mem.indexOf(u8, l, "]  Copy") != null) {
            try rows.append(a, .{ .addr = addr, .column = column });
        } else if (std.mem.indexOf(u8, l, "End of Sequence") != null) {
            try rows.append(a, .{ .addr = addr, .column = column });
            // A sequence's end resets the registers.
            column = 0;
        }
    }
    return rows.items;
}

/// What follows `marker` in `l`, or null.
fn after(l: []const u8, marker: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, l, marker) orelse return null;
    return l[at + marker.len ..];
}

fn firstWord(s: []const u8) []const u8 {
    var end: usize = 0;
    while (end < s.len and std.ascii.isAlphanumeric(s[end])) end += 1;
    return s[0..end];
}

/// **A ROW IS REFUSED** when its line is not in the source, or holds no code
/// (a blank line, a comment alone), or its column is past the line's end
/// plus one: Zig 0.17.0 gives a generic instance's first and last rows lines
/// its source never had (metal-vmm QUEUE 243), inside the file or past its
/// end, and a row there would credit or blame a line with nothing to run.
fn refused(text: []const []const u8, line: u32, column: u32) bool {
    if (line == 0 or line > text.len) return true;
    const t = text[line - 1];
    const code = std.mem.trim(u8, t, " \t\r\x0b\x0c");
    if (code.len == 0 or std.mem.startsWith(u8, code, "//")) return true;
    return column > t.len + 1;
}

/// `lineTable` of readelf's `decodedline` text, each row held to its column
/// in `columns` (`parseColumns`, the same rows in the same order).
fn parseTable(a: std.mem.Allocator, decoded: []const u8, columns: []const Column, sources: []const Source) !Table {
    var lists: std.AutoArrayHashMapUnmanaged(usize, std.ArrayList(Key)) = .empty;
    const refusals = try a.alloc(usize, sources.len);
    @memset(refusals, 0);
    var row_index: usize = 0;
    // A test's root file is named bare (`tcp.zig:`); every other file by
    // its whole path.
    var current: []const u8 = "";
    var rows = std.mem.splitScalar(u8, decoded, '\n');
    rows: while (rows.next()) |row| {
        if (row.len > 0 and row[row.len - 1] == ':' and std.mem.indexOfScalar(u8, row, ' ') == null) {
            current = row[0 .. row.len - 1];
            continue;
        }
        // `(\S+)\s+(\d+)\s+(0x[0-9a-f]+)` from the row's start.
        if (row.len == 0 or std.ascii.isWhitespace(row[0])) continue;
        var words = std.mem.tokenizeAny(u8, row, " \t\r\x0b\x0c");
        const row_file = words.next() orelse continue;
        const line_word = words.next() orelse continue;
        const addr_word = words.next() orelse continue;
        if (!std.mem.startsWith(u8, addr_word, "0x")) continue;
        var end: usize = 2;
        while (end < addr_word.len and (std.ascii.isDigit(addr_word[end]) or (addr_word[end] >= 'a' and addr_word[end] <= 'f'))) end += 1;
        if (end == 2) continue;
        const addr = std.fmt.parseInt(usize, addr_word[2..end], 16) catch continue;
        // A row, its line a number or `-` (a sequence's end): the next of
        // `columns`, which must be at the same address.
        if (!std.mem.eql(u8, line_word, "-")) for (line_word) |c| if (!std.ascii.isDigit(c)) continue :rows;
        if (row_index >= columns.len or columns[row_index].addr != addr) return error.ColumnsDisagree;
        const column = columns[row_index].column;
        row_index += 1;
        if (std.mem.eql(u8, line_word, "-")) continue;
        const line = std.fmt.parseInt(u32, line_word, 10) catch continue;
        for (sources, 0..) |src, i| {
            if (!(std.mem.eql(u8, current, src.abs) or std.mem.eql(u8, current, src.base))) continue;
            // readelf names a row's own file in its first column, and does not
            // always print a new header when a line program moves to another
            // file: a row of std's process.zig can follow a header naming the
            // test's root. A row is the source's only when both say so.
            if (!(std.mem.eql(u8, row_file, src.base) or endsWithPath(src.abs, row_file))) continue;
            if (refused(src.text, line, column)) {
                refusals[i] += 1;
                continue;
            }
            const slot = try lists.getOrPut(a, addr);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            const k = key(i, line);
            for (slot.value_ptr.items) |l| {
                if (l == k) break;
            } else try slot.value_ptr.append(a, k);
        }
    }
    if (row_index != columns.len) return error.ColumnsDisagree;
    var table: Table = .{ .lines = .empty, .refused = refusals };
    for (lists.keys(), lists.values()) |addr, l| try table.lines.put(a, addr, l.items);
    return table;
}

/// Whether `path` ends with `tail` at a `/`: readelf's file column is a bare
/// name for the self-hosted backends and a path relative to the module's
/// root (`std/process.zig`) for LLVM's.
fn endsWithPath(path: []const u8, tail: []const u8) bool {
    return std.mem.endsWith(u8, path, tail) and path.len > tail.len and path[path.len - tail.len - 1] == '/';
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

/// What a traced task is to the breakpoints. `shared`: it runs in the
/// leader's memory (the leader, a thread, a vfork child before its exec),
/// so a breakpoint it hits is the leader's: recorded and put back, for all.
/// A forked child is never one: it gets a copy of the patched text, which
/// is put back as it was, and it is let go.
const Kind = enum { shared, copy };

/// `wait4`'s `__WALL`: threads (`CLONE_VM` children) too.
const wall = 0x40000000;

/// **A CHILD THAT FORKS MUST NOT DIE OF OUR BREAKPOINTS** (metal-vmm QUEUE
/// 241 B; Shale's tests fork and exec the fixture and `shale --reap`): the
/// tracer follows every fork, vfork and clone. A forked child, stopped
/// before it runs, has the original bytes put back at every address ever
/// patched (its copy may hold breakpoints the leader's threads have since
/// put back in the leader) and is detached: its lines are not measured. A
/// thread, or a vfork child until its exec, shares the leader's memory: it
/// is traced as the leader is, a breakpoint any of them hits put back for
/// all, and a task that hits one another already put back is stepped back
/// to run the original. At its exec a vfork child is let go.
///
/// Runs `binary` to its end, the lines it hit added to `hit`; its exit
/// status, or minus the signal that ended it.
fn run(a: std.mem.Allocator, binary: [:0]const u8, envp: [*:null]const ?[*:0]const u8, table: Table, hit: *std.AutoArrayHashMapUnmanaged(Key, void)) !i32 {
    const fork_rc = linux.fork();
    try check(fork_rc, "fork");
    const leader: linux.pid_t = @intCast(fork_rc);
    if (leader == 0) {
        _ = linux.ptrace(PTRACE.TRACEME, 0, 0, 0, 0);
        const argv = [_:null]?[*:0]const u8{binary.ptr};
        _ = linux.execve(binary.ptr, &argv, envp);
        linux.exit(127);
    }
    var status: u32 = undefined;
    try check(linux.waitpid(leader, @ptrCast(&status), 0), "wait"); // stopped at the exec
    const O = PTRACE.O;
    try check(linux.ptrace(PTRACE.SETOPTIONS, leader, 0, O.TRACEFORK | O.TRACEVFORK | O.TRACECLONE | O.TRACEEXEC | O.EXITKILL, 0), "setoptions");
    // The original byte at every address patched, kept for a forked child.
    var original: std.AutoArrayHashMapUnmanaged(usize, u8) = .empty;
    // The addresses still patched in the leader's memory.
    var saved: std.AutoArrayHashMapUnmanaged(usize, void) = .empty;
    for (table.lines.keys()) |addr| {
        try original.put(a, addr, try pokeByte(leader, addr, 0xCC));
        try saved.put(a, addr, {});
    }
    var tasks: std.AutoArrayHashMapUnmanaged(linux.pid_t, void) = .empty;
    try tasks.put(a, leader, {});
    // A new task announced by its parent's event, not yet seen stopped;
    // and one seen stopped before its parent's event said what it is.
    var announced: std.AutoArrayHashMapUnmanaged(linux.pid_t, Kind) = .empty;
    var unannounced: std.AutoArrayHashMapUnmanaged(linux.pid_t, void) = .empty;
    var leader_end: ?i32 = null;
    try check(linux.ptrace(PTRACE.CONT, leader, 0, 0, 0), "cont");
    while (true) {
        const rc = linux.wait4(-1, @ptrCast(&status), wall, null);
        if (linux.errno(rc) == .CHILD) break;
        if (linux.errno(rc) == .INTR) continue;
        try check(rc, "wait");
        const pid: linux.pid_t = @intCast(rc);
        if (linux.W.IFEXITED(status) or linux.W.IFSIGNALED(status)) {
            _ = tasks.swapRemove(pid);
            if (pid == leader) leader_end = if (linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else -@as(i32, @intCast(@backingInt(linux.W.TERMSIG(status))));
            continue;
        }
        if (!linux.W.IFSTOPPED(status)) continue;
        const stop = linux.W.STOPSIG(status);
        const event = status >> 16;
        if (!tasks.contains(pid)) {
            // A new task's first stop.
            if (announced.fetchSwapRemove(pid)) |kv| try adopt(a, pid, kv.value, &tasks, original) else try unannounced.put(a, pid, {});
            continue;
        }
        if (stop == .TRAP and event != 0) {
            if (event == PTRACE.EVENT.FORK or event == PTRACE.EVENT.VFORK or event == PTRACE.EVENT.CLONE) {
                var new: usize = undefined;
                try check(linux.ptrace(PTRACE.GETEVENTMSG, pid, 0, @intFromPtr(&new), 0), "geteventmsg");
                const child: linux.pid_t = @intCast(new);
                const kind: Kind = if (event == PTRACE.EVENT.FORK) .copy else .shared;
                if (unannounced.swapRemove(child)) try adopt(a, child, kind, &tasks, original) else try announced.put(a, child, kind);
            } else if (event == PTRACE.EVENT.EXEC and pid != leader) {
                // A vfork child at its exec: its new image was never patched.
                _ = tasks.swapRemove(pid);
                try check(linux.ptrace(PTRACE.DETACH, pid, 0, 0, 0), "detach");
                continue;
            }
            try check(linux.ptrace(PTRACE.CONT, pid, 0, 0, 0), "cont");
            continue;
        }
        var sig: usize = @backingInt(stop);
        if (stop == .TRAP) {
            var regs: Regs = undefined;
            try check(linux.ptrace(PTRACE.GETREGS, pid, 0, @intFromPtr(&regs), 0), "getregs");
            const at = regs[rip] -% 1;
            if (original.get(at)) |byte| {
                if (saved.swapRemove(at)) {
                    for (table.lines.get(at).?) |l| try hit.put(a, l, {});
                    _ = try pokeByte(pid, at, byte);
                }
                // Hit here, or by another task that hit it before it was put back.
                regs[rip] = at;
                try check(linux.ptrace(PTRACE.SETREGS, pid, 0, @intFromPtr(&regs), 0), "setregs");
                sig = 0;
            }
        }
        // Any other signal is passed on to the program.
        try check(linux.ptrace(PTRACE.CONT, pid, 0, sig, 0), "cont");
    }
    return leader_end orelse error.LeaderLost;
}

/// A new task, stopped before it ran: a thread or vfork child joins the
/// traced; a forked child gets its text put back and is let go.
fn adopt(a: std.mem.Allocator, pid: linux.pid_t, kind: Kind, tasks: *std.AutoArrayHashMapUnmanaged(linux.pid_t, void), original: std.AutoArrayHashMapUnmanaged(usize, u8)) !void {
    switch (kind) {
        .shared => {
            try tasks.put(a, pid, {});
            try check(linux.ptrace(PTRACE.CONT, pid, 0, 0, 0), "cont");
        },
        .copy => {
            for (original.keys(), original.values()) |addr, byte| _ = try pokeByte(pid, addr, byte);
            try check(linux.ptrace(PTRACE.DETACH, pid, 0, 0, 0), "detach");
        },
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
    const dash = for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) break i;
    } else null;
    const named, const binaries = if (dash) |d| .{ args[1..d], args[d + 1 ..] } else if (args.len >= 3) .{ args[1..2], args[2..] } else .{ args[0..0], args[0..0] };
    if (named.len == 0 or binaries.len == 0) {
        try out.writeAll("linecov src/tcp.zig <test binary> [<test binary> ...]\n" ++
            "linecov <source> [<source> ...] -- <test binary> [<test binary> ...]\n");
        return 2;
    }
    const cwd = try std.process.currentPathAlloc(io, a);
    const sources = try a.alloc(Source, named.len);
    for (named, sources) |path, *src| {
        const file_text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
        var text: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, file_text, '\n');
        while (it.next()) |l| try text.append(a, std.mem.trimEnd(u8, l, "\r"));
        if (text.items.len > 0 and std.mem.endsWith(u8, file_text, "\n")) _ = text.pop();
        src.* = .{ .path = path, .abs = try std.fs.path.resolve(a, &.{ cwd, path }), .base = std.fs.path.basename(path), .text = text.items };
    }
    const envp: [*:null]const ?[*:0]const u8 = init.minimal.environ.block.slice.ptr;

    // `have` is the lines with code (a closing brace alone is not one),
    // `ran` the ones run, of every source.
    var have: std.AutoArrayHashMapUnmanaged(Key, void) = .empty;
    var ran: std.AutoArrayHashMapUnmanaged(Key, void) = .empty;
    var crashed: std.ArrayList([]const u8) = .empty;
    // Rows refused (`refused`), each source's, over every binary.
    const refusals = try a.alloc(usize, sources.len);
    @memset(refusals, 0);
    for (binaries) |b| {
        const table = lineTable(a, io, b, sources) catch |e| switch (e) {
            error.ColumnsDisagree => {
                try out.print("linecov: {s}: readelf's decoded rows and its raw line program disagree; no row's column is known\n", .{std.fs.path.basename(b)});
                return 1;
            },
            else => return e,
        };
        for (table.refused, refusals) |n, *total| total.* += n;
        if (table.lines.count() == 0) continue; // another binary's tests reach these files, not this one's
        for (table.lines.values()) |keys| for (keys) |k| {
            const text = sources[@intCast(k >> 32)].text;
            const n: u32 = @truncate(k);
            if (!std.mem.eql(u8, std.mem.trim(u8, text[n - 1], " \t\r\n\x0b\x0c"), "}")) try have.put(a, k, {});
        };
        const code = try run(a, b, envp, table, &ran);
        if (code != 0) {
            try out.print("linecov: {s} exited {d}: its coverage is short\n", .{ std.fs.path.basename(b), code });
            try crashed.append(a, std.fs.path.basename(b));
        }
    }
    var exit: u8 = 0;
    for (sources, 0..) |src, i| {
        var have_count: usize = 0;
        var ran_count: usize = 0;
        var missed: std.ArrayList(u32) = .empty;
        for (have.keys()) |k| {
            if (k >> 32 != i) continue;
            have_count += 1;
            if (ran.contains(k)) ran_count += 1 else try missed.append(a, @truncate(k));
        }
        if (have_count == 0) {
            try out.print("linecov: none of the {d} binaries has a line of {s}\n", .{ binaries.len, src.path });
            if (sources.len == 1) return 2;
            exit = 2;
            continue;
        }
        std.mem.sort(u32, missed.items, {}, lessThan);
        const pct = 100.0 * @as(f64, @floatFromInt(ran_count)) / @as(f64, @floatFromInt(have_count));
        try out.print("{s}: {d} of {d} lines with code ran ({d:.1}%), over {d} binaries\n", .{ src.path, ran_count, have_count, pct, binaries.len });
        // Never silent: the misplaced rows are Zig's, and the next such bug's.
        if (refusals[i] > 0) try out.print("  {d} rows refused: line or column outside the source, or a line with no code\n", .{refusals[i]});
        for (missed.items) |n| {
            const line = std.mem.trim(u8, src.text[n - 1], " \t\r\n\x0b\x0c");
            try out.print("  {d:>5}  {s}\n", .{ n, firstCodepoints(line, 100) });
        }
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
    return exit;
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

test "a row is the source's only when its own file column names it, whatever the header before it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // As readelf prints a test binary's root line program: the header names
    // s.zig, and rows of std's process.zig follow with no new header.
    const decoded =
        \\/w/s.zig:
        \\s.zig                                      1           0x12545a0               x
        \\s.zig                                      2           0x12545a4               x
        \\process.zig                              808           0x1045170               x
        \\std/process.zig                          809           0x1045180               x
        \\
        \\/w/t.zig:
        \\t.zig                                      3           0x2000000               x
        \\
    ;
    const sources = [_]Source{.{ .path = "s.zig", .abs = "/w/s.zig", .base = "s.zig", .text = &.{ "const x = 1;", "const y = 2;" } }};
    const columns = [_]Column{ .{ .addr = 0x12545a0, .column = 1 }, .{ .addr = 0x12545a4, .column = 7 }, .{ .addr = 0x1045170, .column = 5 }, .{ .addr = 0x1045180, .column = 5 }, .{ .addr = 0x2000000, .column = 1 } };
    const table = try parseTable(a, decoded, &columns, &sources);
    try std.testing.expectEqual(@as(usize, 2), table.lines.count());
    try std.testing.expectEqualSlices(Key, &.{key(0, 1)}, table.lines.get(0x12545a0).?);
    try std.testing.expectEqualSlices(Key, &.{key(0, 2)}, table.lines.get(0x12545a4).?);
    try std.testing.expect(table.lines.get(0x1045170) == null and table.lines.get(0x1045180) == null);
    try std.testing.expectEqual(@as(usize, 0), table.refused[0]);
}

test "a row is refused when its line is not the source's, holds no code, or ends before its column; and a row out of step with the columns stops the read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decoded =
        \\/w/s.zig:
        \\s.zig                                      1           0x1000               x
        \\s.zig                                      2           0x1004               x
        \\s.zig                                      3           0x1008               x
        \\s.zig                                      4           0x100c               x
        \\s.zig                                      9           0x1010               x
        \\s.zig                                      -           0x1014
        \\
    ;
    const sources = [_]Source{.{ .path = "s.zig", .abs = "/w/s.zig", .base = "s.zig", .text = &.{ "const x = 1;", "", "// a comment", "f();" } }};
    // Line 1 holds; 2 is blank; 3 a comment; 4 has 4 bytes, so column 6 is past
    // its end plus one; 9 is past the file's end.
    const columns = [_]Column{ .{ .addr = 0x1000, .column = 13 }, .{ .addr = 0x1004, .column = 1 }, .{ .addr = 0x1008, .column = 1 }, .{ .addr = 0x100c, .column = 6 }, .{ .addr = 0x1010, .column = 1 }, .{ .addr = 0x1014, .column = 0 } };
    const table = try parseTable(a, decoded, &columns, &sources);
    try std.testing.expectEqual(@as(usize, 1), table.lines.count());
    try std.testing.expectEqualSlices(Key, &.{key(0, 1)}, table.lines.get(0x1000).?);
    try std.testing.expectEqual(@as(usize, 4), table.refused[0]);
    var out_of_step = columns;
    out_of_step[2].addr = 0x2000;
    try std.testing.expectError(error.ColumnsDisagree, parseTable(a, decoded, &out_of_step, &sources));
    try std.testing.expectError(error.ColumnsDisagree, parseTable(a, decoded, columns[0..5], &sources));
}
