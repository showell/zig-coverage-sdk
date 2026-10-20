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
    b.step("lab", "the explorer against blind runs on the synthetic stories in src/explore_lab.zig").dependOn(&b.addRunArtifact(lab).step);

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
    // **A SITE IT CANNOT CATALOG IS REFUSED** (metal-vmm QUEUE 165): the scan
    // of test/refused.zig must fail, naming the site, where it once warned
    // and passed.
    const refuses = b.addRunArtifact(scan);
    _ = refuses.addOutputFileArg("refused_catalog.zig");
    refuses.addDirectoryArg(b.path("test"));
    refuses.addArg("refused.zig");
    refuses.addFileInput(b.path("test/refused.zig"));
    refuses.expectExitCode(1);
    refuses.addCheck(.{ .expect_stderr_match = "refused.zig:8:" });
    test_step.dependOn(&refuses.step);
    // **LINE COVERAGE** (tools/linecov.zig, metal-vmm QUEUE 241 B): the
    // lines of a source file its test binaries ran, under ptrace. An
    // application runs `sdk.artifact("linecov")` with the file and the
    // binaries (Debug, non-PIE x86-64 Linux, as `zig build test` makes).
    const linecov = b.addExecutable(.{
        .name = "linecov",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/linecov.zig"),
            .target = b.graph.host,
        }),
    });
    b.installArtifact(linecov);
    // Its tests: a binary that forks, vforks and spawns a thread, each
    // running a measured line (test/linecov_fork.zig, judged by
    // test/linecov_check.zig); and the Python it ports as its judge, on the
    // SDK's own Debug unit binaries (test/linecov_agree.zig).
    const tool = struct {
        fn exe(bb: *std.Build, name: []const u8, path: []const u8) *std.Build.Step.Compile {
            return bb.addExecutable(.{ .name = name, .root_module = bb.createModule(.{
                .root_source_file = bb.path(path),
                .target = bb.graph.host,
            }) });
        }
    }.exe;
    const fork_fixture = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/linecov_fork.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    }) });
    const fork_check = b.addRunArtifact(tool(b, "linecov_check", "test/linecov_check.zig"));
    fork_check.addArtifactArg(linecov);
    fork_check.addArg("test/linecov_fork.zig");
    fork_check.addArtifactArg(fork_fixture);
    fork_check.addFileInput(b.path("test/linecov_fork.zig"));
    test_step.dependOn(&fork_check.step);
    const agree = b.addRunArtifact(tool(b, "linecov_agree", "test/linecov_agree.zig"));
    agree.addFileArg(b.path("test/linecov.py"));
    agree.addArtifactArg(linecov);
    // Not src/explore.zig: Zig 0.17's x86_64 backend gives some generic
    // functions' first and last rows lines past the end of their file (pick's,
    // lines 1291 and 1541 of a 1,221-line file), and linecov.py dies of an
    // IndexError there; linecov leaves such a line out.
    agree.addArgs(&.{ "src/coverage.zig", "test/linecov_fork.zig", "--" });
    agree.addFileInput(b.path("src/coverage.zig"));
    agree.addFileInput(b.path("test/linecov_fork.zig"));
    test_step.dependOn(&agree.step);
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
        if (mode == .debug) {
            agree.addArtifactArg(unit);
            agree.addArtifactArg(explore_unit);
        }
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
