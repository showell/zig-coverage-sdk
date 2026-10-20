//! **WHAT linecov SAYS OF A GENERIC'S MISPLACED ROWS** (test/linecov_generic.zig):
//! it runs `linecov test/linecov_generic.zig <its test binary>` and holds it
//! to: exit 0; no line listed as not run that holds no code (a blank line or
//! a comment alone) or that a misplaced row names (`const m = 1;`, which
//! emits none); and the report saying that
//! rows were refused, so a refusal is never silent.
//!
//!     linecov_generic_check <linecov> <source> <fixture binary>

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const r = try std.process.run(a, init.io, .{ .argv = &.{ args[1], args[2], args[3] } });
    var bad = false;
    if (r.term != .exited or r.term.exited != 0) {
        std.debug.print("linecov_generic_check: linecov ended {any}, not exit 0\n", .{r.term});
        bad = true;
    }
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |l| {
        // A missed line: `  <number>  <text>`.
        const t = std.mem.trimStart(u8, l, " ");
        if (t.len == l.len) continue;
        const sp = std.mem.indexOf(u8, t, "  ") orelse continue;
        _ = std.fmt.parseInt(u32, t[0..sp], 10) catch continue;
        const text = std.mem.trim(u8, t[sp..], " ");
        if (text.len == 0 or std.mem.startsWith(u8, text, "//") or std.mem.eql(u8, text, "const m = 1;")) {
            std.debug.print("linecov_generic_check: a line with no code is counted: {s}\n", .{l});
            bad = true;
        }
    }
    if (std.mem.indexOf(u8, r.stdout, " rows refused: ") == null) {
        std.debug.print("linecov_generic_check: the report does not say rows were refused\n", .{});
        bad = true;
    }
    if (bad) {
        std.debug.print("linecov said:\n{s}", .{r.stdout});
        return 1;
    }
    return 0;
}
