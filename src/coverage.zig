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
//! linking, with old bytes in it, so each Site is 128 bytes, 128-aligned and
//! tagged, and `catalog` steps through 128 bytes at a time, taking only what
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
    /// **THE NUMERIC COMPARISONS** (Antithesis's `AlwaysGreaterThan` and the
    /// rest): an `always` or a `sometimes` of `left` against `right`, which
    /// also remembers how close any call came to the edge (`Site.edge`).
    always_greater_than,
    always_greater_than_or_equal_to,
    always_less_than,
    always_less_than_or_equal_to,
    sometimes_greater_than,
    sometimes_greater_than_or_equal_to,
    sometimes_less_than,
    sometimes_less_than_or_equal_to,

    /// The plain kind a comparison is judged as: `always` or `sometimes`.
    pub fn basic(k: Kind) Kind {
        return switch (k) {
            .always_greater_than, .always_greater_than_or_equal_to, .always_less_than, .always_less_than_or_equal_to => .always,
            .sometimes_greater_than, .sometimes_greater_than_or_equal_to, .sometimes_less_than, .sometimes_less_than_or_equal_to => .sometimes,
            else => k,
        };
    }

    /// Whether it is a comparison, and so has an edge.
    pub fn guided(k: Kind) bool {
        return k.basic() != k;
    }

    /// **WHICH WAY THE EDGE LIES**, as the Go SDK steers: `left - right`
    /// maximized or minimized. An always is pushed toward breaking, a
    /// sometimes toward holding.
    pub fn maximize(k: Kind) bool {
        return switch (k) {
            .always_less_than, .always_less_than_or_equal_to, .sometimes_greater_than, .sometimes_greater_than_or_equal_to => true,
            else => false,
        };
    }

    /// The wire's `assert_type`.
    fn assertType(k: Kind) []const u8 {
        return switch (k.basic()) {
            .always, .always_or_unreachable => "always",
            .sometimes => "sometimes",
            .reachable, .@"unreachable" => "reachability",
            else => unreachable,
        };
    }

    /// The wire's `display_type`: a comparison's is its plain kind's, as the
    /// Go SDK writes it.
    fn display(k: Kind) []const u8 {
        return switch (k.basic()) {
            .always => "Always",
            .always_or_unreachable => "AlwaysOrUnreachable",
            .sometimes => "Sometimes",
            .reachable => "Reachable",
            .@"unreachable" => "Unreachable",
            else => unreachable,
        };
    }

    /// Whether a run that never reaches it fails it.
    fn mustHit(k: Kind) bool {
        return switch (k.basic()) {
            .always, .sometimes, .reachable => true,
            .always_or_unreachable, .@"unreachable" => false,
            else => unreachable,
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
    /// **A COMPARISON'S EDGE**: the call that came closest to it, which is
    /// the most or the least `left - right` (`Kind.maximize`).
    edge: Operands = .{},
    /// **HOW FAR `left` WENT**, the way the edge lies: the most `left` of a
    /// comparison that maximizes, the least of one that minimizes. Not the
    /// edge: a table of 256 slots full is the same edge as one of 2 full
    /// (`left - right` is 0 for both), and only this tells them apart.
    reach: Operands = .{},
    /// **WHAT THE STREAM HAS BEEN TOLD** (`compare`): guidance lines
    /// printed, and the coarse place of the last edge and reach printed.
    printed: u8 = 0,
    printed_edge: u8 = 0xFF,
    printed_reach: u8 = 0,
    /// To `site_size`, which the catalog steps by.
    reserved: [13]u8 = @splat(0),

    pub fn hit(s: *const Site) bool {
        return s.passes + s.fails > 0;
    }

    /// Not merely unmet but contradicted: an `always` seen false, an
    /// `unreachable` reached. The rest of what does not hold is a MISS: the
    /// run never got there. Antithesis fails both alike; this SDK tells
    /// them apart, because a MISS says the run was short of the case, not
    /// that the code is wrong (README.md, "Where this differs").
    pub fn broken(s: *const Site) bool {
        return s.fails > 0 and switch (s.kind.basic()) {
            .always, .always_or_unreachable, .@"unreachable" => true,
            .sometimes, .reachable => false,
            else => unreachable,
        };
    }

    /// The property's verdict, as Antithesis would give it for this run.
    pub fn holds(s: *const Site) bool {
        return switch (s.kind.basic()) {
            .always => s.hit() and s.fails == 0,
            .always_or_unreachable, .@"unreachable" => s.fails == 0,
            .sometimes, .reachable => s.passes > 0,
            else => unreachable,
        };
    }
};

/// **TWO NUMBERS COMPARED**, kept as their bits and what they are, so a
/// Site stays `extern`: signed and unsigned integers up to 64 bits, and
/// floats, as the Go SDK's operands are (int64, uint64, float64).
pub const Operands = extern struct {
    what: What = .none,
    left: u64 = 0,
    right: u64 = 0,

    pub const What = enum(u8) { none, signed, unsigned, float };

    pub fn of(left: anytype, right: anytype) Operands {
        const T = Operand(@TypeOf(left, right));
        const l: T = left;
        const r: T = right;
        return switch (@typeInfo(T)) {
            .float => .{ .what = .float, .left = @bitCast(@as(f64, @floatCast(l))), .right = @bitCast(@as(f64, @floatCast(r))) },
            .int => |i| if (i.signedness == .signed)
                .{ .what = .signed, .left = @bitCast(@as(i64, l)), .right = @bitCast(@as(i64, r)) }
            else
                .{ .what = .unsigned, .left = @as(u64, l), .right = @as(u64, r) },
            else => unreachable,
        };
    }

    /// `left - right`, exactly: an i128 holds any two 64-bit integers' gap.
    const Gap = union(enum) { int: i128, float: f64 };

    fn gap(o: Operands) Gap {
        return switch (o.what) {
            .signed => .{ .int = @as(i128, @as(i64, @bitCast(o.left))) - @as(i64, @bitCast(o.right)) },
            .unsigned => .{ .int = @as(i128, o.left) - @as(i128, o.right) },
            .float => .{ .float = @as(f64, @bitCast(o.left)) - @as(f64, @bitCast(o.right)) },
            .none => .{ .int = 0 },
        };
    }

    /// Whether `o`'s left is further than `reach`'s, which way `maximize`
    /// says.
    pub fn further(o: Operands, reach: Operands, maximize: bool) bool {
        if (reach.what == .none) return true;
        return switch (o.what) {
            .signed => if (maximize) @as(i64, @bitCast(o.left)) > @as(i64, @bitCast(reach.left)) else @as(i64, @bitCast(o.left)) < @as(i64, @bitCast(reach.left)),
            .unsigned => if (maximize) o.left > reach.left else o.left < reach.left,
            .float => if (maximize) @as(f64, @bitCast(o.left)) > @as(f64, @bitCast(reach.left)) else @as(f64, @bitCast(o.left)) < @as(f64, @bitCast(reach.left)),
            .none => false,
        };
    }

    /// Whether `o` is nearer the edge than `edge`, which way `maximize` says.
    pub fn nearer(o: Operands, edge: Operands, maximize: bool) bool {
        if (edge.what == .none) return true;
        const a = o.gap();
        const b = edge.gap();
        return switch (a) {
            .int => |x| if (b == .int) (if (maximize) x > b.int else x < b.int) else false,
            .float => |x| if (b == .float) (if (maximize) x > b.float else x < b.float) else false,
        };
    }

    fn write(o: Operands, w: *std.Io.Writer, comptime which: enum { left, right }) !void {
        const bits = if (which == .left) o.left else o.right;
        switch (o.what) {
            .signed => try w.print("{d}", .{@as(i64, @bitCast(bits))}),
            .unsigned => try w.print("{d}", .{bits}),
            .float => try std.json.Stringify.value(@as(f64, @bitCast(bits)), .{}, w),
            .none => try w.writeAll("null"),
        }
    }
};

/// The type both operands are compared as: a literal is an i64 or an f64.
fn Operand(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .comptime_int => i64,
        .comptime_float => f64,
        .int => |i| if (i.bits > 64) @compileError("operands are at most 64 bits, as the Go SDK's are") else T,
        .float => |f| if (f.bits > 64) @compileError("operands are at most 64 bits, as the Go SDK's are") else T,
        else => @compileError("a comparison's operands are numbers"),
    };
}

/// Where each line goes, newline included. Null: nowhere, and `report` is
/// the only way to read the run.
pub var sink: ?*const fn (line: []const u8) void = null;

/// **A MOMENT**: called when a site does something no call before it did
/// since the last `reset`: its first pass, its first failure, or a
/// comparison whose edge or reach moved. An explorer records where in a run
/// each moment came, to return there (src/explore.zig, `Options.moment`).
/// Null: nothing is called.
pub var on_moment: ?*const fn (s: *Site) void = null;

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

/// **THE NUMERIC COMPARISONS**, after Antithesis's `AlwaysGreaterThan` and
/// the rest: `always(left > right)` and so on, with `left` and `right` added
/// to the details, and the edge remembered: the call that came closest to
/// breaking an always, or to making a sometimes hold. So a report can say
/// "the most slots any run had in use", and an explorer can steer there.
pub fn alwaysGreaterThan(comptime src: std.builtin.SourceLocation, left: anytype, right: anytype, comptime message: [:0]const u8, details: anytype) void {
    compare(src, .always_greater_than, left, right, message, details);
}

pub fn alwaysGreaterThanOrEqualTo(comptime src: std.builtin.SourceLocation, left: anytype, right: anytype, comptime message: [:0]const u8, details: anytype) void {
    compare(src, .always_greater_than_or_equal_to, left, right, message, details);
}

pub fn alwaysLessThan(comptime src: std.builtin.SourceLocation, left: anytype, right: anytype, comptime message: [:0]const u8, details: anytype) void {
    compare(src, .always_less_than, left, right, message, details);
}

pub fn alwaysLessThanOrEqualTo(comptime src: std.builtin.SourceLocation, left: anytype, right: anytype, comptime message: [:0]const u8, details: anytype) void {
    compare(src, .always_less_than_or_equal_to, left, right, message, details);
}

pub fn sometimesGreaterThan(comptime src: std.builtin.SourceLocation, left: anytype, right: anytype, comptime message: [:0]const u8, details: anytype) void {
    compare(src, .sometimes_greater_than, left, right, message, details);
}

pub fn sometimesGreaterThanOrEqualTo(comptime src: std.builtin.SourceLocation, left: anytype, right: anytype, comptime message: [:0]const u8, details: anytype) void {
    compare(src, .sometimes_greater_than_or_equal_to, left, right, message, details);
}

pub fn sometimesLessThan(comptime src: std.builtin.SourceLocation, left: anytype, right: anytype, comptime message: [:0]const u8, details: anytype) void {
    compare(src, .sometimes_less_than, left, right, message, details);
}

pub fn sometimesLessThanOrEqualTo(comptime src: std.builtin.SourceLocation, left: anytype, right: anytype, comptime message: [:0]const u8, details: anytype) void {
    compare(src, .sometimes_less_than_or_equal_to, left, right, message, details);
}

fn compare(comptime src: std.builtin.SourceLocation, comptime kind: Kind, left: anytype, right: anytype, comptime message: [:0]const u8, details: anytype) void {
    const T = Operand(@TypeOf(left, right));
    const l: T = left;
    const r: T = right;
    const cond = switch (kind) {
        .always_greater_than, .sometimes_greater_than => l > r,
        .always_greater_than_or_equal_to, .sometimes_greater_than_or_equal_to => l >= r,
        .always_less_than, .sometimes_less_than => l < r,
        .always_less_than_or_equal_to, .sometimes_less_than_or_equal_to => l <= r,
        else => comptime unreachable,
    };
    const s = site(src, kind, message);
    const ops = Operands.of(l, r);
    recordWith(s, cond, details, ops);
    // **A GUIDANCE LINE AT EACH NEW EDGE, AND EACH NEW REACH**: the first
    // call, every one nearer the edge than any before, and every one whose
    // `left` went further, thinned after the first 16 (`worthPrinting`).
    // Each line is the call's own operands, so a reader that keeps the best
    // `left - right` gets the edge within a factor of two, and one that
    // keeps the furthest `left` gets the reach within a factor of two; the
    // record here stays exact. The Go SDK keeps the same edge;
    // when it emits is this SDK's rule (README.md, "The numeric comparisons").
    const nearer = ops.nearer(s.edge, kind.maximize());
    const further = ops.further(s.reach, kind.maximize());
    if (!nearer and !further) return;
    if (nearer) s.edge = ops;
    if (further) s.reach = ops;
    if (on_moment) |f| f(s);
    const out = sink orelse return;
    if (!worthPrinting(s, ops, nearer, further, kind.maximize())) return;
    declare();
    emitGuidance(out, s, ops);
}

/// Guidance lines a comparison prints before only the coarse ones.
const free_lines = 16;

/// **THE STREAM THINS, THE RECORD DOES NOT.** A comparison over a count that
/// only grows (a log's next byte, the bytes a cache holds) sets a new reach
/// at every call, and a line at each one flooded a kernel's console: about
/// 450 lines of 300 bytes in one boot, at an exit a byte under metal-vmm,
/// long enough to change what the run did (gopher-metal v19's lossy sweep,
/// 2026-10-07). So the first `free_lines` new edges and reaches print, and
/// after them only an edge whose distance from the limit halved, or a reach
/// that crossed a power of two. `edge` and `reach` keep every call exact for
/// `report`; a reader of the stream sees each within a factor of two.
fn worthPrinting(s: *Site, ops: Operands, nearer: bool, further: bool, maximize: bool) bool {
    const eb = gapBucket(ops);
    const rk = reachKey(ops);
    const worth = s.printed < free_lines or
        (nearer and eb < s.printed_edge) or
        (further and (if (maximize) rk > s.printed_reach else rk < s.printed_reach));
    if (!worth) return false;
    s.printed +|= 1;
    s.printed_edge = @min(s.printed_edge, eb);
    s.printed_reach = if (s.printed == 1) rk else if (maximize) @max(s.printed_reach, rk) else @min(s.printed_reach, rk);
    return true;
}

/// How many bits the distance from the limit takes: halving it drops one.
fn gapBucket(o: Operands) u8 {
    const g = o.gap();
    const mag: u128 = switch (g) {
        .int => |x| @abs(x),
        .float => |x| if (x != x) 0 else @intFromFloat(@min(@abs(x), 1.0e30)),
    };
    return @intCast(128 - @clz(mag));
}

/// `left`, coarsely and in order: a power of two crossed, either sign.
fn reachKey(o: Operands) u8 {
    const v: i128 = switch (o.what) {
        .signed => @as(i64, @bitCast(o.left)),
        .unsigned => o.left,
        .float => blk: {
            const f: f64 = @bitCast(o.left);
            break :blk if (f != f) 0 else @intFromFloat(std.math.clamp(f, -1.0e30, 1.0e30));
        },
        .none => 0,
    };
    const bits: i32 = @intCast(128 - @clz(@abs(v)));
    return @intCast(if (v >= 0) 128 + bits else 127 - bits);
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
///
/// **A FILE OF MANY SITES NEEDS MORE COMPTIME THAN ZIG'S DEFAULT.** Every site
/// is registered in one comptime evaluation, each costing some hundreds of
/// branches (its function's name searched, its strings copied and hashed), so
/// a file past about seventy sites ran out of the default 1000 (gopher-metal's
/// fat16.zig, metal-vmm QUEUE item 76). The quota is a ceiling, not a cost.
pub fn catalogFile(comptime generated: type, comptime here: std.builtin.SourceLocation) void {
    @setEvalBranchQuota(10_000_000);
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

const site_size = 128;
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
    recordWith(s, cond, details, null);
}

fn recordWith(s: *Site, cond: bool, details: anytype, ops: ?Operands) void {
    const first = if (cond) s.passes == 0 else s.fails == 0;
    if (cond) s.passes +|= 1 else s.fails +|= 1;
    if (!first) return;
    if (on_moment) |f| f(s);
    const out = sink orelse return;
    declare();
    emitWith(out, s, true, cond, details, ops);
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
    while (it.next()) |s| {
        emit(out, s, false, false, null);
        if (s.kind.guided()) emitGuidance(out, s, null);
    }
}

/// Long enough for any location; details past it are dropped, not the line.
var line_buf: [4096]u8 = undefined;

fn emit(out: *const fn ([]const u8) void, s: *const Site, hit: bool, cond: bool, details: anytype) void {
    emitWith(out, s, hit, cond, details, null);
}

fn emitWith(out: *const fn ([]const u8) void, s: *const Site, hit: bool, cond: bool, details: anytype, ops: ?Operands) void {
    var w: std.Io.Writer = .fixed(&line_buf);
    writeLine(&w, s, hit, cond, details, ops) catch {
        w = .fixed(&line_buf);
        writeLine(&w, s, hit, cond, .{ .coverage_sdk = "details too long for the line buffer" }, ops) catch return;
    };
    out(w.buffered());
}

/// **THE GUIDANCE LINE**, as the Go SDK writes `guidanceInfo`, in its order:
/// `{"antithesis_guidance":{"guidance_data":{"left":..,"right":..},
/// "location":{..},"guidance_type":"numeric","message":..,"id":..,
/// "maximize":..,"hit":..}}`; a declaration (`hit: false`) has no data.
fn emitGuidance(out: *const fn ([]const u8) void, s: *const Site, ops: ?Operands) void {
    var w: std.Io.Writer = .fixed(&line_buf);
    writeGuidance(&w, s, ops) catch return;
    out(w.buffered());
}

fn writeGuidance(w: *std.Io.Writer, s: *const Site, ops: ?Operands) !void {
    const message = std.mem.span(s.message);
    const hit = ops != null;
    try w.writeAll("{\"antithesis_guidance\":{");
    if (ops) |o| {
        try w.writeAll("\"guidance_data\":{\"left\":");
        try o.write(w, .left);
        try w.writeAll(",\"right\":");
        try o.write(w, .right);
        try w.writeAll("},");
    }
    try w.writeAll("\"location\":");
    try writeLocation(w, s);
    try w.writeAll(",\"guidance_type\":\"numeric\",\"message\":");
    try std.json.Stringify.encodeJsonString(message, .{}, w);
    try w.writeAll(",\"id\":");
    try std.json.Stringify.encodeJsonString(message, .{}, w);
    try w.print(",\"maximize\":{},\"hit\":{}}}}}\n", .{ s.kind.maximize(), hit });
}

fn writeLocation(w: *std.Io.Writer, s: *const Site) !void {
    try w.writeAll("{\"class\":");
    try std.json.Stringify.encodeJsonString(std.mem.span(s.module), .{}, w);
    try w.writeAll(",\"function\":");
    try std.json.Stringify.encodeJsonString(std.mem.span(s.function), .{}, w);
    try w.writeAll(",\"file\":");
    try std.json.Stringify.encodeJsonString(std.mem.span(s.file), .{}, w);
    try w.print(",\"begin_line\":{d},\"begin_column\":{d}}}", .{ s.line, s.column });
}

/// The details of a comparison: `left` and `right`, and the caller's own
/// fields beside them when they are an object, as the Go SDK merges them;
/// anything else the caller gave goes under `details`.
fn writeDetails(w: *std.Io.Writer, details: anytype, ops: Operands) !void {
    try w.writeAll("{\"left\":");
    try ops.write(w, .left);
    try w.writeAll(",\"right\":");
    try ops.write(w, .right);
    if (@TypeOf(details) != @TypeOf(null)) {
        var buf: [2048]u8 = undefined;
        var inner: std.Io.Writer = .fixed(&buf);
        try std.json.Stringify.value(details, .{}, &inner);
        const text = inner.buffered();
        if (text.len > 2 and text[0] == '{') {
            try w.writeAll(",");
            try w.writeAll(text[1 .. text.len - 1]);
        } else if (!std.mem.eql(u8, text, "{}")) {
            try w.writeAll(",\"details\":");
            try w.writeAll(text);
        }
    }
    try w.writeAll("}");
}

fn writeLine(w: *std.Io.Writer, s: *const Site, hit: bool, cond: bool, details: anytype, ops: ?Operands) !void {
    const message = std.mem.span(s.message);
    try w.writeAll("{\"antithesis_assert\":{\"hit\":");
    try w.writeAll(if (hit) "true" else "false");
    try w.print(",\"must_hit\":{},\"assert_type\":\"{s}\",\"display_type\":\"{s}\",\"message\":", .{
        s.kind.mustHit(), s.kind.assertType(), s.kind.display(),
    });
    try std.json.Stringify.encodeJsonString(message, .{}, w);
    try w.print(",\"condition\":{},\"id\":", .{cond});
    try std.json.Stringify.encodeJsonString(message, .{}, w);
    try w.writeAll(",\"location\":");
    try writeLocation(w, s);
    if (ops) |o| {
        try w.writeAll(",\"details\":");
        try writeDetails(w, details, o);
    } else if (@TypeOf(details) != @TypeOf(null)) {
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
            try w.print("{s} {s:<19} {s}  ({s}:{d}; {d} true, {d} false", .{
                if (pass) "ok  " else if (s.broken()) "FAIL" else "MISS", s.kind.display(), s.message,
                s.file,                                                   s.line,           s.passes,
                s.fails,
            });
            if (s.kind.guided() and s.edge.what != .none) {
                try w.writeAll("; its edge: left ");
                try s.edge.write(w, .left);
                try w.writeAll(", right ");
                try s.edge.write(w, .right);
                if (s.reach.left != s.edge.left) {
                    try w.writeAll("; its reach: left ");
                    try s.reach.write(w, .left);
                    try w.writeAll(", right ");
                    try s.reach.write(w, .right);
                }
            }
            try w.writeAll(")\n");
        }
    }
    return failed;
}

/// **THE FLOOR**: the properties a run is expected to reach, one message per
/// line, `#` for comments (tools/report.py reads the same file). Answers how
/// many fall under it, naming each: a property on it that does not hold for
/// want of being reached (a MISS), or a line that names no site in this
/// program, which is a floor gone stale. A FAIL is `report`'s, not this.
pub fn checkFloor(floor: []const u8, w: *std.Io.Writer) !usize {
    var under: usize = 0;
    var lines = std.mem.splitScalar(u8, floor, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var found = false;
        var missed = false;
        var it = catalog();
        while (it.next()) |s| {
            if (!std.mem.eql(u8, std.mem.span(s.message), line)) continue;
            found = true;
            if (!s.holds() and !s.broken()) missed = true;
        }
        if (!found) {
            under += 1;
            try w.print("STALE  on the floor, but no such property: {s}\n", .{line});
        } else if (missed) {
            under += 1;
            try w.print("FLOOR  never reached: {s}\n", .{line});
        }
    }
    return under;
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
        s.edge = .{};
        s.reach = .{};
        s.printed = 0;
        s.printed_edge = 0xFF;
        s.printed_reach = 0;
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
        // A comparison's guidance lines (their own test) are not asserts.
        if (parsed.value.object.get("antithesis_guidance") != null) continue;
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

test "the floor: a property on it that was never reached is under it, and so is one that does not exist" {
    reset();
    sink = null;
    exercise(10);
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const floor =
        \\# what ten turns must reach
        \\k reaches three
        \\a thousand
        \\no such property
        \\
    ;
    try testing.expectEqual(@as(usize, 2), try checkFloor(floor, &w));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "FLOOR  never reached: a thousand") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "STALE  on the floor, but no such property: no such property") != null);
}

fn generic(wire: anytype) void {
    _ = wire;
    sometimes(@src(), true, "inside a generic, called with two types", null);
}

var counted_lines: usize = 0;
fn countLines(line: []const u8) void {
    if (std.mem.indexOf(u8, line, "a ring's next byte is inside it") != null) counted_lines += 1;
}

test "a count that only grows prints a few guidance lines, and the record stays exact" {
    reset();
    counted_lines = 0;
    sink = countLines;
    defer sink = null;
    var i: u32 = 0;
    while (i < 65536) : (i += 1) alwaysLessThan(@src(), i, @as(u32, 65536), "a ring's next byte is inside it", null);
    // The free lines, then a halving of the gap or a power of two crossed:
    // about fifty, where every new reach printed would be 65,536.
    try testing.expect(counted_lines >= free_lines);
    try testing.expect(counted_lines <= free_lines + 2 * 18);
    const s = mine("a ring's next byte is inside it");
    try testing.expectEqual(@as(u64, 65535), s.reach.left);
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

fn slots(n: u32) void {
    alwaysLessThanOrEqualTo(@src(), n, 256, "slots in use stay within the table", .{ .conn = n });
}

fn freeClusters(n: i64) void {
    sometimesLessThan(@src(), n, 10, "free clusters run low", null);
}

test "a comparison is its plain kind's verdict, and remembers its edge" {
    reset();
    sink = null;
    const s = mine("slots in use stay within the table");
    try testing.expect(s.kind.guided());
    try testing.expect(!s.holds()); // never reached: an always's MISS
    for ([_]u32{ 3, 200, 17 }) |n| slots(n);
    try testing.expect(s.holds());
    // Always(left <= right) is pushed toward breaking: the most left - right.
    try testing.expectEqual(@as(u64, 200), s.edge.left);
    slots(300);
    try testing.expect(s.broken());
    try testing.expectEqual(@as(u64, 300), s.edge.left);

    const f = mine("free clusters run low");
    for ([_]i64{ 400, 30, 90 }) |n| freeClusters(n);
    try testing.expect(!f.holds()); // a sometimes never true: a MISS, not a FAIL
    try testing.expect(!f.broken());
    // Sometimes(left < right) is pushed toward holding: the least left - right.
    try testing.expectEqual(@as(i64, 30), @as(i64, @bitCast(f.edge.left)));
    freeClusters(-2);
    try testing.expect(f.holds());

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try report(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "slots in use stay within the table  (coverage.zig") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "its edge: left 300, right 256)") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "its edge: left -2, right 10)") != null);
}

test "the wire: a comparison's details carry left and right, and a guidance line goes out at each new edge" {
    reset();
    captured_len = 0;
    sink = capture;
    defer sink = null;
    for ([_]u32{ 3, 200, 17, 250 }) |n| slots(n);
    const text = captured[0..captured_len];
    var guidance_hit: usize = 0;
    var guidance_declared: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        if (parsed.value.object.get("antithesis_assert")) |a| {
            if (!std.mem.eql(u8, a.object.get("message").?.string, "slots in use stay within the table")) continue;
            try testing.expectEqualStrings("Always", a.object.get("display_type").?.string);
            if (a.object.get("hit").?.bool) {
                const d = a.object.get("details").?.object;
                try testing.expectEqual(@as(i64, 3), d.get("left").?.integer);
                try testing.expectEqual(@as(i64, 256), d.get("right").?.integer);
                try testing.expectEqual(@as(i64, 3), d.get("conn").?.integer);
            }
        }
        const g = (parsed.value.object.get("antithesis_guidance") orelse continue).object;
        if (!std.mem.eql(u8, g.get("message").?.string, "slots in use stay within the table")) continue;
        try testing.expectEqualStrings("numeric", g.get("guidance_type").?.string);
        try testing.expect(g.get("maximize").?.bool);
        try testing.expectEqualStrings("coverage.zig", g.get("location").?.object.get("file").?.string);
        if (!g.get("hit").?.bool) {
            guidance_declared += 1;
            try testing.expect(g.get("guidance_data") == null);
            continue;
        }
        guidance_hit += 1;
        try testing.expectEqual(@as(i64, 256), g.get("guidance_data").?.object.get("right").?.integer);
    }
    try testing.expectEqual(@as(usize, 1), guidance_declared);
    // 3, then 200, then 250: each nearer the edge; 17 is not.
    try testing.expectEqual(@as(usize, 3), guidance_hit);
    try testing.expect(std.mem.indexOf(u8, text, "\"guidance_data\":{\"left\":250,\"right\":256}") != null);
}

fn tableFull(in_use: u32, len: u32) void {
    alwaysLessThanOrEqualTo(@src(), in_use, len, "a table is never past full", null);
}

test "reach: a full table of 203 is the same edge as one of 2, and a further reach" {
    reset();
    captured_len = 0;
    sink = capture;
    defer sink = null;
    tableFull(2, 2);
    tableFull(1, 2);
    tableFull(203, 203);
    tableFull(100, 203);
    const s = mine("a table is never past full");
    try testing.expectEqual(@as(u64, 2), s.edge.left); // the first gap of 0 is kept
    try testing.expectEqual(@as(u64, 203), s.reach.left);
    // Guidance lines: the declaration, (2,2) as edge and reach, (203,203)
    // as reach only; (1,2) and (100,203) are neither.
    const text = captured[0..captured_len];
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, "\"message\":\"a table is never past full\",\"id\"")) |i| : (at = i + 1) {
        if (std.mem.lastIndexOf(u8, text[0..i], "antithesis_guidance")) |g| if (std.mem.lastIndexOfScalar(u8, text[0..i], '\n') orelse 0 <= g) {
            n += 1;
        };
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expect(std.mem.indexOf(u8, text, "\"guidance_data\":{\"left\":203,\"right\":203}") != null);
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try report(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "its edge: left 2, right 2; its reach: left 203, right 203)") != null);
}

test "operands: literals, signed and unsigned, floats, and the gap between 64-bit extremes exactly" {
    const a = Operands.of(@as(u64, std.math.maxInt(u64)), @as(u64, 0));
    const b = Operands.of(@as(u64, std.math.maxInt(u64) - 1), @as(u64, 0));
    try testing.expect(a.nearer(b, true));
    try testing.expect(!b.nearer(a, true));
    const c = Operands.of(-5, 3);
    try testing.expectEqual(Operands.What.signed, c.what);
    const f = Operands.of(@as(f32, 1.5), 2.0);
    try testing.expectEqual(Operands.What.float, f.what);
    try testing.expect(f.nearer(Operands.of(@as(f64, 9.0), 2.0), false));
}
