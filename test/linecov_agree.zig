//! **THE ZIG linecov HELD TO THE PYTHON ONE** (metal-vmm QUEUE 241 B):
//! zig-metal-unikernel's tools/linecov.py, copied to test/linecov.py, is the
//! judge until the kernel switches to tools/linecov.zig. For each source
//! named, both are run over the same binaries; their output and exit code
//! must be the same, byte for byte.
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
    for (sources) |source| {
        var py: std.ArrayList([]const u8) = .empty;
        try py.appendSlice(a, &.{ "python3", args[1], source });
        try py.appendSlice(a, binaries);
        var zig: std.ArrayList([]const u8) = .empty;
        try zig.appendSlice(a, &.{ args[2], source });
        try zig.appendSlice(a, binaries);
        const want = try std.process.run(a, io, .{ .argv = py.items });
        const got = try std.process.run(a, io, .{ .argv = zig.items });
        const same_end = want.term == .exited and got.term == .exited and want.term.exited == got.term.exited;
        if (!same_end or !std.mem.eql(u8, want.stdout, got.stdout)) {
            differ += 1;
            std.debug.print("linecov_agree: {s}: the two differ\n-- linecov.py ({any}):\n{s}-- linecov ({any}):\n{s}", .{ source, want.term, want.stdout, got.term, got.stdout });
        }
    }
    return if (differ == 0) 0 else 1;
}
