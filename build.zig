// zig-coverage-sdk: one module, `coverage`, over src/coverage.zig.
//
//   zig build test     the SDK's own tests, Debug and ReleaseSafe
//
// A program uses it by path, as a sibling checkout: in its build.zig,
//   b.createModule(.{ .root_source_file = .{ .cwd_relative = "<checkout>/src/coverage.zig" } })
// added to its modules' imports as "coverage".
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const test_step = b.step("test", "the SDK's own tests, Debug and ReleaseSafe");
    // Both: ReleaseSafe is where the optimizer once dropped sites, Debug
    // where zig's own linker leaves slack between them (src/coverage.zig).
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe }) |mode| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/coverage.zig"),
            .target = target,
            .optimize = mode,
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    _ = b.addModule("coverage", .{ .root_source_file = b.path("src/coverage.zig") });
}
