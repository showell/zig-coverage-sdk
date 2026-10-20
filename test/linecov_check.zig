//! **WHAT linecov SAYS OF THE FORK FIXTURE** (test/linecov_fork.zig): it
//! runs `linecov test/linecov_fork.zig <its test binary>` and holds it to:
//! exit 0 (the binary finished: no child died of a breakpoint it
//! inherited); the thread's line and the vfork child's counted as run (they
//! share the traced memory, so their breakpoints are the leader's); the
//! forked child's line not (its copy was put back and let go, unmeasured).
//!
//!     linecov_check <linecov> <source> <fixture binary>

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const r = try std.process.run(a, init.io, .{ .argv = &.{ args[1], args[2], args[3] } });
    var bad = false;
    if (r.term != .exited or r.term.exited != 0) {
        std.debug.print("linecov_check: linecov ended {any}, not exit 0\n", .{r.term});
        bad = true;
    }
    const missed = struct {
        fn is(out: []const u8, text: []const u8) bool {
            var lines = std.mem.splitScalar(u8, out, '\n');
            while (lines.next()) |l| {
                if (std.mem.startsWith(u8, l, "  ") and std.mem.indexOf(u8, l, text) != null) return true;
            }
            return false;
        }
    }.is;
    if (!missed(r.stdout, "run only in the forked child")) {
        std.debug.print("linecov_check: the forked child's line is counted as run\n", .{});
        bad = true;
    }
    for ([_][]const u8{ "run only in the thread", "run only in the vfork child" }) |t| {
        if (missed(r.stdout, t)) {
            std.debug.print("linecov_check: the line \"{s}\" is listed as not run\n", .{t});
            bad = true;
        }
    }
    if (bad) {
        std.debug.print("linecov said:\n{s}", .{r.stdout});
        return 1;
    }
    return 0;
}
