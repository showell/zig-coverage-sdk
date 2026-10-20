//! **THE LINE TOOL'S FORK FIXTURE** (tools/linecov.zig, metal-vmm QUEUE 241
//! B): a test that runs a measured line in a forked child, in a vfork child
//! before its exec, and in a thread. A child the tracer does not follow
//! inherits the patched text, and dies of SIGTRAP at the first measured
//! line it runs; test/linecov_check.zig judges what linecov says of this
//! file.

const std = @import("std");
const linux = std.os.linux;

fn forkWork(x: u32) u32 {
    return x * 3 + 1; // run only in the forked child
}

fn vforkWork(x: u32) u32 {
    return x * 5 + 2; // run only in the vfork child, before its exec
}

fn threadWork(out: *u32) void {
    out.* = 42; // run only in the thread
}

var vfork_stack: [64 * 1024]u8 align(16) = undefined;

/// The vfork child, on a stack of its own (a `vfork` through a call would
/// share the parent's frames): a measured line, then an exec.
fn vforkChild(_: usize) callconv(.c) u8 {
    if (vforkWork(4) != 22) linux.exit_group(1);
    const argv = [_:null]?[*:0]const u8{"/bin/true"};
    const envp = [_:null]?[*:0]const u8{};
    _ = linux.execve("/bin/true", &argv, &envp);
    linux.exit_group(127);
}

fn waitOk(pid: usize) !void {
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), @ptrCast(&status), 0);
    try std.testing.expect(linux.W.IFEXITED(status));
    try std.testing.expectEqual(@as(u8, 0), linux.W.EXITSTATUS(status));
}

test "a forked child, a vfork child and a thread each run a measured line" {
    const forked = linux.fork();
    if (forked == 0) linux.exit_group(if (forkWork(4) == 13) 0 else 1);
    try waitOk(forked);

    const top = @intFromPtr(&vfork_stack) + vfork_stack.len;
    const vforked = linux.clone(vforkChild, top, linux.CLONE.VM | linux.CLONE.VFORK | @intFromEnum(linux.SIG.CHLD), 0, null, 0, null);
    try waitOk(vforked);

    var got: u32 = 0;
    const t = try std.Thread.spawn(.{}, threadWork, .{&got});
    t.join();
    try std.testing.expectEqual(@as(u32, 42), got);
}
