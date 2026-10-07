// zig-coverage-sdk: the `coverage` module, and the scanner that catalogs
// assertions in code nothing calls (tools/scan.zig).
//
//   zig build test     the SDK's own tests, Debug and ReleaseSafe, and the
//                      scanner judged on test/fixture.zig
//
// A program takes it as a dependency (build.zig.zon), then in its build.zig:
//
//   const sdk = b.dependency("zig_coverage_sdk", .{});
//   const coverage = sdk.module("coverage");
//   const catalog = @import("zig_coverage_sdk").addCatalog(b, sdk.artifact("coverage-scan"),
//       coverage, b.path("src"), &.{"tcp.zig"});
//
// and adds both to the imports of every module that compiles a scanned file,
// as "coverage" and "coverage_catalog".
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const coverage = b.addModule("coverage", .{ .root_source_file = b.path("src/coverage.zig") });
    // The seed explorer's tape and named choices (src/explore.zig): for
    // simulators and tools, never the kernel.
    const explore = b.addModule("explore", .{
        .root_source_file = b.path("src/explore.zig"),
        .imports = &.{.{ .name = "coverage", .module = coverage }},
    });

    // **THE EXPLORER'S LAB** (src/explore_lab.zig): a synthetic story shaped
    // like fat_sim, so a change to the explorer is measured in seconds.
    const lab = b.addExecutable(.{
        .name = "explore-lab",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/explore_lab.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "coverage", .module = coverage },
                .{ .name = "explore", .module = explore },
            },
        }),
    });
    b.step("lab", "the explorer against blind runs on a synthetic story, in seconds").dependOn(&b.addRunArtifact(lab).step);

    const scan = b.addExecutable(.{
        .name = "coverage-scan",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/scan.zig"),
            .target = b.graph.host,
        }),
    });
    b.installArtifact(scan);

    const test_step = b.step("test", "the SDK's own tests, Debug and ReleaseSafe, and the scanner");
    // Both: ReleaseSafe is where the optimizer once dropped sites, Debug
    // where zig's own linker leaves slack between them (src/coverage.zig).
    const catalog = addCatalog(b, scan, coverage, b.path("test"), &.{"fixture.zig"});
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe }) |mode| {
        const unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/coverage.zig"),
            .target = target,
            .optimize = mode,
        }) });
        test_step.dependOn(&b.addRunArtifact(unit).step);
        const scanned = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("test/catalog_test.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{
                .{ .name = "coverage", .module = coverage },
                .{ .name = "coverage_catalog", .module = catalog },
            },
        }) });
        test_step.dependOn(&b.addRunArtifact(scanned).step);
        const explore_unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/explore.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{.{ .name = "coverage", .module = coverage }},
        }) });
        test_step.dependOn(&b.addRunArtifact(explore_unit).step);
    }
}

/// **THE CATALOG OF `files`**, as a module: tools/scan.zig run over them (paths
/// relative to `root`, as `@src().file` gives them), again whenever one
/// changes. Import it as "coverage_catalog" into every module that compiles
/// one of the files, beside `coverage` as "coverage"; each file then says
/// `coverage.catalogFile(...)` once (src/coverage.zig).
pub fn addCatalog(
    b: *std.Build,
    scan: *std.Build.Step.Compile,
    coverage: *std.Build.Module,
    root: std.Build.LazyPath,
    files: []const []const u8,
) *std.Build.Module {
    const run = b.addRunArtifact(scan);
    const generated = run.addOutputFileArg("coverage_catalog.zig");
    run.addDirectoryArg(root);
    for (files) |f| {
        run.addArg(f);
        run.addFileInput(root.path(b, f));
    }
    return b.createModule(.{
        .root_source_file = generated,
        .imports = &.{.{ .name = "coverage", .module = coverage }},
    });
}
