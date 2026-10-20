//! **THE ZIG linecov HELD TO THE PYTHON ONE** (metal-vmm QUEUE 241 B):
//! zig-metal-unikernel's tools/linecov.py, copied to test/linecov.py, is the
//! judge until the kernel switches to tools/linecov.zig. For each source
//! named, both are run over the same binaries; their output and exit code
//! must be the same, byte for byte. Then linecov's own form for several
//! sources (`<source>... -- <binary>...`, one run of each binary) must print
//! what the Python printed for each, in order.
//!
//!     linecov_agree <linecov.py> <linecov> <source>... -- <binary>...

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    const dash = for (args, 0..) |s, i| {
        if (std.mem.eql(u8, s, "--")) break i;
    } else return error.Usage;
    const sources = args[3..dash];
    const binaries = args[dash + 1 ..];
    var differ: usize = 0;
    var each: std.ArrayList(u8) = .empty;
    for (sources) |source| {
        var py: std.ArrayList([]const u8) = .empty;
        try py.appendSlice(a, &.{ "python3", args[1], source });
        try py.appendSlice(a, binaries);
        var zig: std.ArrayList([]const u8) = .empty;
        try zig.appendSlice(a, &.{ args[2], source });
        try zig.appendSlice(a, binaries);
        const want = try std.process.run(a, io, .{ .argv = py.items });
        const got = try std.process.run(a, io, .{ .argv = zig.items });
        try each.appendSlice(a, want.stdout);
        const same_end = want.term == .exited and got.term == .exited and want.term.exited == got.term.exited;
        if (!same_end or !std.mem.eql(u8, want.stdout, got.stdout)) {
            differ += 1;
            std.debug.print("linecov_agree: {s}: the two differ\n-- linecov.py ({any}):\n{s}-- linecov ({any}):\n{s}", .{ source, want.term, want.stdout, got.term, got.stdout });
        }
    }
    var all: std.ArrayList([]const u8) = .empty;
    try all.append(a, args[2]);
    try all.appendSlice(a, sources);
    try all.append(a, "--");
    try all.appendSlice(a, binaries);
    const together = try std.process.run(a, io, .{ .argv = all.items });
    if (!std.mem.eql(u8, each.items, together.stdout)) {
        differ += 1;
        std.debug.print("linecov_agree: the sources together differ from each alone\n-- each ({d}):\n{s}-- together ({any}):\n{s}", .{ sources.len, each.items, together.term, together.stdout });
    }
    return if (differ == 0) 0 else 1;
}
