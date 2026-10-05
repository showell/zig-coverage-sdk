//! **COVERAGE PROPERTIES FOR ZIG**: assertions that are properties of a whole
//! run, after the assertion half of Antithesis's SDK
//! (https://antithesis.com/docs/properties_assertions/) and cribbed from their
//! Go and Rust SDKs. Not endorsed by Antithesis, and not yet run against their
//! toolchain: README.md says what is and is not compatible.
//!
//! - `always(cond)`: true every time it is reached, and it is reached.
//! - `alwaysOrUnreachable(cond)`: true every time it is reached, if ever.
//! - `sometimes(cond)`: true at least once. The one ordinary tests cannot
//!   say: it fails when the case we hoped to exercise never happened.
//! - `reachable()`: reached at least once.
//! - `@"unreachable"()`: never reached.
//!
//! A run that breaks one carries on; the verdict is read at the end, from
//! `report`, or from the JSONL lines `sink` is handed.
//!
//! **THE CATALOG.** A `sometimes` that never ran must still be reported, so
//! every assertion has to be known before it is reached. Each call site owns
//! one `Site`, a static in the `zig_coverage_catalog` section, which the
//! linker's `__start_`/`__stop_` symbols bound. **IT IS NOT A PACKED ARRAY:**
//! zig's own linker (Debug) leaves room after each static for incremental
//! linking, with old bytes in it, so each Site is 64 bytes, 64-aligned and
//! tagged, and `catalog` steps through 64 bytes at a time, taking only what
//! carries the tag. A freestanding program's link script must keep the
//! section. **A site is in the catalog when its function is compiled** — Zig
//! compiles only what is referenced — **or when its file is scanned**:
//! tools/scan.zig reads the source and `catalogFile` registers what it found.
//!
//! **THE WIRE** is Antithesis's documented JSONL, as their SDKs write it: on
//! the first event of the run, one `antithesis_sdk` line and a declaration
//! (`hit: false`) of every site; then a line for the FIRST pass and the FIRST
//! failure of each site, and nothing for the rest. Each line goes to `sink`,
//! a function pointer, so the program decides where: a file, a serial port.
//!
//! **ONE THREAD.** The counters and the line buffer are plain statics.
const std = @import("std");

pub const Kind = enum(u8) {
    always,
    always_or_unreachable,
    sometimes,
    reachable,
    @"unreachable",

    /// The wire's `assert_type`.
    fn assertType(k: Kind) []const u8 {
        return switch (k) {
            .always, .always_or_unreachable => "always",
            .sometimes => "sometimes",
            .reachable, .@"unreachable" => "reachability",
        };
    }

    /// The wire's `display_type`.
    fn display(k: Kind) []const u8 {
        return switch (k) {
            .always => "Always",
            .always_or_unreachable => "AlwaysOrUnreachable",
            .sometimes => "Sometimes",
            .reachable => "Reachable",
            .@"unreachable" => "Unreachable",
        };
    }

    /// Whether a run that never reaches it fails it.
    fn mustHit(k: Kind) bool {
        return switch (k) {
            .always, .sometimes, .reachable => true,
            .always_or_unreachable, .@"unreachable" => false,
        };
    }
};

/// One assertion's place in the source, and what the run has seen there.
/// `extern` so its layout is fixed: the catalog is walked as an array.
pub const Site = extern struct {
    /// What tells a Site from the slack beside it (see the top of the file).
    tag: u64 = site_tag,
    kind: Kind,
    message: [*:0]const u8,
    file: [*:0]const u8,
    function: [*:0]const u8,
    module: [*:0]const u8,
    line: u32,
    column: u32,
    /// Times reached with the condition true, and false. `reachable` counts
    /// a pass and `unreachable` a failure, as the Go SDK records them.
    passes: u32 = 0,
    fails: u32 = 0,

    pub fn hit(s: *const Site) bool {
        return s.passes + s.fails > 0;
    }

    /// Not merely unmet but contradicted: an `always` seen false, an
    /// `unreachable` reached. The rest of what does not hold is a MISS: the
    /// run never got there. Antithesis fails both alike; this SDK tells
    /// them apart, because a MISS says the run was short of the case, not
    /// that the code is wrong (README.md, "Where this differs").
    pub fn broken(s: *const Site) bool {
        return s.fails > 0 and switch (s.kind) {
            .always, .always_or_unreachable, .@"unreachable" => true,
            .sometimes, .reachable => false,
        };
    }

    /// The property's verdict, as Antithesis would give it for this run.
    pub fn holds(s: *const Site) bool {
        return switch (s.kind) {
            .always => s.hit() and s.fails == 0,
            .always_or_unreachable, .@"unreachable" => s.fails == 0,
            .sometimes, .reachable => s.passes > 0,
        };
    }
};

/// Where each line goes, newline included. Null: nowhere, and `report` is
/// the only way to read the run.
pub var sink: ?*const fn (line: []const u8) void = null;

pub fn always(comptime src: std.builtin.SourceLocation, cond: bool, comptime message: [:0]const u8, details: anytype) void {
    record(site(src, .always, message), cond, details);
}

pub fn alwaysOrUnreachable(comptime src: std.builtin.SourceLocation, cond: bool, comptime message: [:0]const u8, details: anytype) void {
    record(site(src, .always_or_unreachable, message), cond, details);
}

pub fn sometimes(comptime src: std.builtin.SourceLocation, cond: bool, comptime message: [:0]const u8, details: anytype) void {
    record(site(src, .sometimes, message), cond, details);
}

pub fn reachable(comptime src: std.builtin.SourceLocation, comptime message: [:0]const u8, details: anytype) void {
    record(site(src, .reachable, message), true, details);
}

pub fn @"unreachable"(comptime src: std.builtin.SourceLocation, comptime message: [:0]const u8, details: anytype) void {
    record(site(src, .@"unreachable", message), false, details);
}

/// **A SITE THE SOURCE HAS, WHETHER OR NOT ITS CODE IS COMPILED.** Called by
/// the file tools/scan.zig generates, with the place `@src()` would give the
/// real call: the same Site, so registering one is the same as compiling it.
pub fn register(comptime src: std.builtin.SourceLocation, comptime kind: Kind, comptime message: [:0]const u8) void {
    _ = site(src, kind, message);
}

/// **EVERY ASSERTION IN THIS FILE, IN THE CATALOG.** A file the scanner reads
/// says, once, at container level:
///
///     comptime {
///         coverage.catalogFile(@import("coverage_catalog"), here());
///     }
///     fn here() std.builtin.SourceLocation {
///         return @src();
///     }
///
/// (`@src()` is refused outside a function.) Its sites are then in the
/// catalog of every program that compiles the file, even the ones in
/// functions nothing calls; build.zig's `addCatalog` makes the module.
pub fn catalogFile(comptime generated: type, comptime here: std.builtin.SourceLocation) void {
    generated.sites(here.module, here.file);
}

/// This call site's one `Site`.
///
/// **ONE PER PLACE IN THE SOURCE, HOWEVER MANY INSTANTIATIONS.** In a generic
/// or `anytype` function `@src().fn_name` names the instantiation
/// (`transmit__anon_44394`), so each instantiation was a Site of its own, and
/// their exported names collided: a compile error the moment such a function
/// was called with two types. The suffix is cut, and every string is passed
/// to `siteOf` as an array, which comptime compares by content; a slice
/// compares by pointer, and two equal names would still be two Sites.
fn site(comptime src: std.builtin.SourceLocation, comptime kind: Kind, comptime message: [:0]const u8) *Site {
    const function = comptime if (std.mem.indexOf(u8, src.fn_name, "__anon_")) |cut| src.fn_name[0..cut] else src.fn_name;
    return siteOf(kind, arr(src.module), arr(src.file), arr(function), src.line, src.column, arr(message));
}

fn arr(comptime s: []const u8) [s.len:0]u8 {
    comptime {
        var a: [s.len:0]u8 = undefined;
        @memcpy(a[0..s.len], s);
        return a;
    }
}

fn siteOf(
    comptime kind: Kind,
    comptime module: anytype,
    comptime file: anytype,
    comptime function: anytype,
    comptime line: u32,
    comptime column: u32,
    comptime message: anytype,
) *Site {
    const S = struct {
        const module_ = module;
        const file_ = file;
        const function_ = function;
        const message_ = message;
        var s: Site align(site_size) linksection("zig_coverage_catalog") = .{
            .kind = kind,
            .message = &message_,
            .file = &file_,
            .function = &function_,
            .module = &module_,
            .line = line,
            .column = column,
        };
        // **EXPORTED, SO DEAD CODE CANNOT TAKE IT.** A site the optimizer
        // proves unreachable is the one the catalog most needs to report,
        // and without this it went with the branch around it (ReleaseSafe).
        comptime {
            @export(&s, .{ .name = symbol, .visibility = .hidden });
        }
        const symbol = std.fmt.comptimePrint("zig_coverage_site_{x}", .{std.hash.Wyhash.hash(0, std.fmt.comptimePrint(
            "{s}\x00{s}\x00{s}\x00{d}\x00{d}\x00{s}\x00{s}",
            .{ &module_, &file_, &function_, line, column, @tagName(kind), &message_ },
        ))});
    };
    return &S.s;
}

/// **THE SECTION'S ANCHOR.** With no site in live code, lld's --gc-sections
/// dropped the whole section — it does not count `__start_`/`__stop_` as
/// references — and an optimized build failed to link. Untagged, so the
/// walk skips it.
var anchor: [site_size]u8 align(site_size) linksection("zig_coverage_catalog") = @splat(0);

extern var __start_zig_coverage_catalog: Site;
extern var __stop_zig_coverage_catalog: Site;

const site_size = 64;
const site_tag: u64 = std.mem.readInt(u64, "zigcover", .little);
comptime {
    std.debug.assert(@sizeOf(Site) == site_size);
}

/// Every assertion this program was compiled with, reached or not.
pub fn catalog() Catalog {
    std.mem.doNotOptimizeAway(&anchor);
    return .{
        .at = @intFromPtr(&__start_zig_coverage_catalog),
        .end = @intFromPtr(&__stop_zig_coverage_catalog),
    };
}

pub const Catalog = struct {
    at: usize,
    end: usize,

    pub fn next(c: *Catalog) ?*Site {
        while (c.at + site_size <= c.end) {
            const s: *Site = @ptrFromInt(c.at);
            c.at += site_size;
            if (s.tag == site_tag) return s;
        }
        return null;
    }

    pub fn count(c: Catalog) usize {
        var it = c;
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n;
    }
};

var declared = false;

fn record(s: *Site, cond: bool, details: anytype) void {
    const first = if (cond) s.passes == 0 else s.fails == 0;
    if (cond) s.passes +|= 1 else s.fails +|= 1;
    if (!first) return;
    const out = sink orelse return;
    declare();
    emit(out, s, true, cond, details);
}

/// The version line and every site's declaration, once a run. Done on the
/// first event, as both SDKs do; a harness may call it at startup instead.
pub fn declare() void {
    if (declared) return;
    declared = true;
    const out = sink orelse return;
    out("{\"antithesis_sdk\":{\"language\":{\"name\":\"Zig\",\"version\":\"" ++
        @import("builtin").zig_version_string ++
        "\"},\"sdk_version\":\"0.0.1\",\"protocol_version\":\"1.1.0\"}}\n");
    var it = catalog();
    while (it.next()) |s| emit(out, s, false, false, null);
}

/// Long enough for any location; details past it are dropped, not the line.
var line_buf: [4096]u8 = undefined;

fn emit(out: *const fn ([]const u8) void, s: *const Site, hit: bool, cond: bool, details: anytype) void {
    var w: std.Io.Writer = .fixed(&line_buf);
    writeLine(&w, s, hit, cond, details) catch {
        w = .fixed(&line_buf);
        writeLine(&w, s, hit, cond, .{ .coverage_sdk = "details too long for the line buffer" }) catch return;
    };
    out(w.buffered());
}

fn writeLine(w: *std.Io.Writer, s: *const Site, hit: bool, cond: bool, details: anytype) !void {
    const message = std.mem.span(s.message);
    try w.writeAll("{\"antithesis_assert\":{\"hit\":");
    try w.writeAll(if (hit) "true" else "false");
    try w.print(",\"must_hit\":{},\"assert_type\":\"{s}\",\"display_type\":\"{s}\",\"message\":", .{
        s.kind.mustHit(), s.kind.assertType(), s.kind.display(),
    });
    try std.json.Stringify.encodeJsonString(message, .{}, w);
    try w.print(",\"condition\":{},\"id\":", .{cond});
    try std.json.Stringify.encodeJsonString(message, .{}, w);
    try w.writeAll(",\"location\":{\"class\":");
    try std.json.Stringify.encodeJsonString(std.mem.span(s.module), .{}, w);
    try w.writeAll(",\"function\":");
    try std.json.Stringify.encodeJsonString(std.mem.span(s.function), .{}, w);
    try w.writeAll(",\"file\":");
    try std.json.Stringify.encodeJsonString(std.mem.span(s.file), .{}, w);
    try w.print(",\"begin_line\":{d},\"begin_column\":{d}}}", .{ s.line, s.column });
    if (@TypeOf(details) != @TypeOf(null)) {
        try w.writeAll(",\"details\":");
        try std.json.Stringify.value(details, .{}, w);
    }
    try w.writeAll("}}\n");
}

/// The run's verdict on every assertion, failures first; the number failing.
pub fn report(w: *std.Io.Writer) !usize {
    var failed: usize = 0;
    for ([_]bool{ false, true }) |pass| {
        var it = catalog();
        while (it.next()) |s| {
            if (s.holds() != pass) continue;
            if (!pass) failed += 1;
            try w.print("{s} {s:<19} {s}  ({s}:{d}; {d} true, {d} false)\n", .{
                if (pass) "ok  " else if (s.broken()) "FAIL" else "MISS", s.kind.display(), s.message,
                s.file,                                                   s.line,           s.passes,
                s.fails,
            });
        }
    }
    return failed;
}

/// The sites failing now.
pub fn failing() usize {
    var n: usize = 0;
    var it = catalog();
    while (it.next()) |s| {
        if (!s.holds()) n += 1;
    }
    return n;
}

/// Forgets the run: every count to zero, and the declarations owed again.
pub fn reset() void {
    var it = catalog();
    while (it.next()) |s| {
        s.passes = 0;
        s.fails = 0;
    }
    declared = false;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

var captured: [16 * 1024]u8 = undefined;
var captured_len: usize = 0;

fn capture(line: []const u8) void {
    @memcpy(captured[captured_len..][0..line.len], line);
    captured_len += line.len;
}

fn mine(name: []const u8) *Site {
    var it = catalog();
    while (it.next()) |s| if (std.mem.eql(u8, std.mem.span(s.message), name)) return s;
    @panic("no such site");
}

fn exercise(n: u32) void {
    for (0..n) |k| {
        always(@src(), k < 100, "k stays small", .{ .k = k });
        alwaysOrUnreachable(@src(), true, "never reached is fine", null);
        sometimes(@src(), k == 3, "k reaches three", .{ .k = k });
        if (k == 1_000) reachable(@src(), "a thousand", null);
        if (k == 7) @"unreachable"(@src(), "seven is \"forbidden\"", .{ .k = k });
    }
}

test "every site is in the catalog before it runs, and judged by its kind" {
    reset();
    sink = null;
    // Nothing ran: the musts fail, the may-nots hold.
    try testing.expect(!mine("k stays small").holds());
    try testing.expect(mine("never reached is fine").holds());
    try testing.expect(!mine("k reaches three").holds());
    try testing.expect(!mine("a thousand").holds());
    try testing.expect(mine("seven is \"forbidden\"").holds());

    exercise(5);
    try testing.expect(mine("k stays small").holds());
    try testing.expect(mine("k reaches three").holds());
    try testing.expect(!mine("a thousand").holds());
    try testing.expectEqual(@as(u32, 5), mine("k stays small").passes);

    exercise(10);
    try testing.expect(!mine("seven is \"forbidden\"").holds());
}

test "the wire: version, declarations, then only the first pass and first failure" {
    reset();
    captured_len = 0;
    sink = capture;
    defer sink = null;
    exercise(10);
    exercise(10);
    const text = captured[0..captured_len];

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var declarations: usize = 0;
    var hits: usize = 0;
    var first = true;
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        if (first) {
            try testing.expect(parsed.value.object.get("antithesis_sdk") != null);
            first = false;
            continue;
        }
        const a = parsed.value.object.get("antithesis_assert").?.object;
        if (a.get("hit").?.bool) hits += 1 else declarations += 1;
    }
    try testing.expectEqual(catalog().count(), declarations);
    // k stays small: one pass. never reached is fine: one pass. k reaches
    // three: one false, one true. seven: one. A thousand never ran.
    try testing.expectEqual(@as(usize, 5), hits);
    try testing.expect(std.mem.indexOf(u8, text, "\"details\":{\"k\":7}") != null);
    try testing.expect(std.mem.indexOf(u8, text, "seven is \\\"forbidden\\\"") != null);
}

fn generic(wire: anytype) void {
    _ = wire;
    sometimes(@src(), true, "inside a generic, called with two types", null);
}

test "a generic called with two types is one site" {
    reset();
    sink = null;
    generic(@as(u8, 1));
    generic(@as(u16, 1));
    const s = mine("inside a generic, called with two types");
    try testing.expectEqual(@as(u32, 2), s.passes);
    try testing.expectEqualStrings("generic", std.mem.span(s.function));
}

test "report names the failures first" {
    reset();
    sink = null;
    exercise(10);
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const n = try report(&w);
    try testing.expectEqual(n, failing());
    // Nothing unmet after the first "ok".
    const first_ok = std.mem.indexOf(u8, w.buffered(), "ok  ").?;
    try testing.expect(std.mem.indexOf(u8, w.buffered()[first_ok..], "FAIL") == null);
    try testing.expect(std.mem.indexOf(u8, w.buffered()[first_ok..], "MISS") == null);
    // Of `exercise`'s: "a thousand" never ran, and seven was reached. (The
    // catalog holds every other site in the program too.)
    var mine_failing: usize = 0;
    var it = catalog();
    while (it.next()) |s| {
        if (std.mem.eql(u8, std.mem.span(s.function), "exercise") and !s.holds()) mine_failing += 1;
    }
    try testing.expectEqual(@as(usize, 2), mine_failing);
}
