//! **STEERING A SIMULATOR**: the tape and the named choices under the seed
//! explorer (essays: notes/the-seed-explorer.md, notes/steering-by-design.md).
//!
//! A simulator takes its randomness through a `std.Random`. A `Tape` is one:
//! it records every `fill` it answers, so a run can be played again, and it
//! can replay the first `k` fills of an earlier run and then draw fresh ones,
//! which keeps a run's past and re-rolls its future. A run's **position** is
//! the number of fills so far.
//!
//! On top of the tape, `pick` is a **named choice**: the code says what it is
//! deciding and what the alternatives are. With a plain `std.Random` it draws
//! as any weighted choice does. Under a `Tape` it is also logged by name, and
//! the explorer can force it to another alternative while the run still
//! consumes the same draw, so every later position means what it meant.
//!
//! The kernel never imports this module; it is for simulators and tools.

const std = @import("std");
const Allocator = std.mem.Allocator;
const coverage = @import("coverage");

/// One named choice a run made: where in the tape it was drawn, and which
/// alternative it took out of how many.
pub const Choice = struct {
    name: []const u8,
    position: u32,
    chosen: u32,
    alternatives: u32,
};

/// A choice the explorer overrides: the `index`th choice of the run takes
/// alternative `alternative`.
pub const Force = struct {
    index: u32,
    alternative: u32,
};

pub const Tape = struct {
    gpa: Allocator,
    /// The seed fresh draws come from, for a run's report.
    seed: u64,
    prng: std.Random.DefaultPrng,
    /// Every fill answered, end to end, and where each one ends in `bytes`.
    bytes: std.ArrayList(u8) = .empty,
    ends: std.ArrayList(u32) = .empty,
    /// The named choices made, in order.
    choices: std.ArrayList(Choice) = .empty,
    /// Replaying: the earlier run whose first `replay_upto` fills are answered
    /// again, byte for byte.
    replay: ?*const Tape = null,
    replay_upto: u32 = 0,
    /// Replayed fill `i` is `replay`'s fill `replay_from + i`: a twin run
    /// can replay the stretch of a tape its first run drew.
    replay_from: u32 = 0,
    /// A replayed fill whose length differed from the recorded one: the run
    /// went another way than the tape it replays, so its past is not that
    /// tape's. Fresh bytes answer it and every fill after it (a past that
    /// has come apart is not replayed further), and this says it happened.
    drifted: bool = false,
    /// The record stopped (out of memory): `bytes` and `ends` hold the fills
    /// up to there, consistently, and the run goes on unrecorded.
    truncated: bool = false,
    force: ?Force = null,
    /// A forced choice whose draw could not be rewritten (it took more than
    /// one fill), so replaying this tape does not take the flip.
    unfaithful: bool = false,

    /// A tape that draws from `seed`: a run under it is the run `seed`'s
    /// PRNG gives, recorded.
    pub fn init(gpa: Allocator, seed: u64) Tape {
        return .{ .gpa = gpa, .seed = seed, .prng = .init(seed) };
    }

    /// A tape that answers `old`'s first `upto` fills again, then draws from
    /// `seed`; `force`, if any, overrides one named choice.
    pub fn branch(gpa: Allocator, old: *const Tape, upto: u32, seed: u64, force: ?Force) Tape {
        var t = init(gpa, seed);
        t.replay = old;
        t.replay_upto = @min(upto, old.position());
        t.force = force;
        return t;
    }

    /// A tape that answers `old`'s fills `from` to `to` again, in order,
    /// then draws from `seed`: the same draws, for a second run of the same
    /// story (a twin that must reach the same end by another road).
    pub fn twin(gpa: Allocator, old: *const Tape, from: u32, to: u32, seed: u64) Tape {
        var t = init(gpa, seed);
        t.replay = old;
        t.replay_from = @min(from, old.position());
        t.replay_upto = @min(to, old.position()) -| t.replay_from;
        return t;
    }

    pub fn deinit(t: *Tape) void {
        t.bytes.deinit(t.gpa);
        t.ends.deinit(t.gpa);
        t.choices.deinit(t.gpa);
    }

    pub fn position(t: *const Tape) u32 {
        return @intCast(t.ends.items.len);
    }

    /// Rewrites fill `i`, one `uintLessThan(Draw, total)` drawn in one fill,
    /// to bytes that draw `want`.
    fn rewrite(t: *Tape, i: u32, comptime Draw: type, total: u64, want: u64) void {
        const start = if (i == 0) 0 else t.ends.items[i - 1];
        const slot = t.bytes.items[start..t.ends.items[i]];
        if (slot.len != @sizeOf(Draw)) {
            t.unfaithful = true;
            return;
        }
        // The value `uintLessThan` maps to `want` is near `want`'s share of
        // the range; try it and its neighbours, keeping one that is drawn in
        // a single fill.
        const span: u128 = @as(u128, std.math.maxInt(Draw)) + 1;
        const guess: u128 = (@as(u128, want) * span + total - 1) / total;
        var k: u128 = 0;
        while (k < 4) : (k += 1) {
            const x: Draw = @intCast(@min(guess + k, span - 1));
            var one = Single{ .bytes = std.mem.asBytes(&x) };
            const got = one.random().uintLessThan(Draw, @intCast(total));
            if (got == want and one.used == 1) {
                @memcpy(slot, std.mem.asBytes(&x));
                return;
            }
        }
        t.unfaithful = true;
    }

    /// Rewrites fill `i`, one `boolean()` drawn in one fill, to draw `want`.
    fn rewriteFlag(t: *Tape, i: u32, want: bool) void {
        const start = if (i == 0) 0 else t.ends.items[i - 1];
        const slot = t.bytes.items[start..t.ends.items[i]];
        const x: u8 = @intFromBool(want);
        var one = Single{ .bytes = std.mem.asBytes(&x) };
        if (slot.len == 1 and one.random().boolean() == want and one.used == 1) slot[0] = x else t.unfaithful = true;
    }

    /// Logs a named choice, and answers the alternative the run takes: the
    /// forced one if the explorer forced this choice, else `drawn`.
    fn named(t: *Tape, name: []const u8, at: u32, drawn: u32, alternatives: u32) ?u32 {
        const index: u32 = @intCast(t.choices.items.len);
        var chosen = drawn;
        var forced: ?u32 = null;
        if (t.force) |force| if (force.index == index and force.alternative < alternatives and force.alternative != drawn) {
            chosen = force.alternative;
            forced = chosen;
        };
        t.choices.append(t.gpa, .{ .name = name, .position = at, .chosen = chosen, .alternatives = alternatives }) catch {};
        return forced;
    }

    /// The bytes of fill `i`.
    pub fn fillAt(t: *const Tape, i: u32) []const u8 {
        const start = if (i == 0) 0 else t.ends.items[i - 1];
        return t.bytes.items[start..t.ends.items[i]];
    }

    pub fn random(t: *Tape) std.Random {
        return .{ .ptr = t, .fillFn = fill };
    }

    /// The tape under `r`, if `r` is one.
    pub fn of(r: std.Random) ?*Tape {
        return if (r.fillFn == &fill) @ptrCast(@alignCast(r.ptr)) else null;
    }

    fn fill(ptr: *anyopaque, buf: []u8) void {
        const t: *Tape = @ptrCast(@alignCast(ptr));
        const at = t.position();
        answer: {
            if (t.replay) |old| if (!t.drifted and at < t.replay_upto) {
                const was = old.fillAt(t.replay_from + at);
                if (was.len == buf.len) {
                    @memcpy(buf, was);
                    break :answer;
                }
                t.drifted = true;
            };
            t.prng.random().bytes(buf);
        }
        // Out of memory ends the run's record, not the run: the draw is
        // answered either way, and a short tape only replays less. Room for
        // both is made first, so the two lists never fall out of step.
        if (t.truncated) return;
        t.bytes.ensureUnusedCapacity(t.gpa, buf.len) catch {
            t.truncated = true;
            return;
        };
        t.ends.ensureUnusedCapacity(t.gpa, 1) catch {
            t.truncated = true;
            return;
        };
        t.bytes.appendSliceAssumeCapacity(buf);
        t.ends.appendAssumeCapacity(@intCast(t.bytes.items.len));
    }
};

/// A source of one fill, for `Tape.rewrite` to test a candidate draw.
const Single = struct {
    bytes: []const u8,
    used: u32 = 0,
    fn random(o: *Single) std.Random {
        return .init(o, fill);
    }
    fn fill(o: *Single, buf: []u8) void {
        o.used += 1;
        if (o.used == 1 and buf.len == o.bytes.len) @memcpy(buf, o.bytes) else @memset(buf, 0xFF);
    }
};

/// **A NAMED CHOICE** among the fields of `weights`, an anonymous struct of
/// comptime integer weights: `pick(r, "fat: the volume is FAT32", .{ .no = 3,
/// .yes = 1 })` answers `.no` or `.yes`. The alternatives take the draw's
/// values in field order, so **replacing `uintLessThan(u8, 4) == 0` keeps a
/// seed's run only as `.{ .yes = 1, .no = 3 }`**: the alternative the old
/// test took on 0 comes first. One draw, whatever the source: `uintLessThan(u8,
/// total)` when the total fits a byte (else `u32`), so a pick can replace an
/// existing `uintLessThan(u8, n)` without changing a seed's run; `pickAs`
/// names the type when the existing draw is another. Under a `Tape` the
/// choice is logged, and a forced one takes the forced alternative, with the
/// draw on the tape rewritten to one that gives it, so replaying the tape (a
/// twin, a reproduction) takes the flip too.
pub fn pick(r: std.Random, comptime name: []const u8, comptime weights: anytype) std.meta.FieldEnum(@TypeOf(weights)) {
    comptime var total: u64 = 0;
    inline for (@typeInfo(@TypeOf(weights)).@"struct".fields) |f| total += @field(weights, f.name);
    return pickAs(r, if (total <= 255) u8 else u32, name, weights);
}

/// `pick`, drawn as `uintLessThan(Draw, total)`.
pub fn pickAs(r: std.Random, comptime Draw: type, comptime name: []const u8, comptime weights: anytype) std.meta.FieldEnum(@TypeOf(weights)) {
    const fields = @typeInfo(@TypeOf(weights)).@"struct".fields;
    const starts = comptime blk: {
        var at: [fields.len + 1]u64 = undefined;
        var sum: u64 = 0;
        for (fields, 0..) |f, i| {
            at[i] = sum;
            sum += @field(weights, f.name);
        }
        at[fields.len] = sum;
        break :blk at;
    };
    const total = starts[fields.len];
    const tape = Tape.of(r);
    const at: u32 = if (tape) |t| t.position() else 0;
    const draw: u64 = r.uintLessThan(Draw, total);
    var chosen: u32 = 0;
    inline for (1..fields.len) |i| {
        if (draw >= starts[i]) chosen = i;
    }
    if (tape) |t| if (t.named(name, at, chosen, fields.len)) |forced| {
        chosen = forced;
        if (t.position() == at + 1) t.rewrite(at, Draw, total, @intCast(starts[forced])) else t.unfaithful = true;
    };
    return @enumFromInt(chosen);
}

/// **A NAMED YES OR NO**, drawn exactly as `r.boolean()`, so it can replace
/// one without changing a seed's run.
pub fn flag(r: std.Random, comptime name: []const u8) bool {
    const tape = Tape.of(r);
    const at: u32 = if (tape) |t| t.position() else 0;
    var yes = r.boolean();
    if (tape) |t| if (t.named(name, at, @intFromBool(yes), 2)) |forced| {
        yes = forced == 1;
        if (t.position() == at + 1) t.rewriteFlag(at, yes) else t.unfaithful = true;
    };
    return yes;
}

// ── the explorer ────────────────────────────────────────────────────────────

/// One run of a simulator, its whole story drawn from the tape it is given.
/// An error is an oracle that failed.
pub const RunFn = *const fn (tape: *Tape) anyerror!void;

pub const Options = struct {
    /// How many runs.
    budget: u32,
    /// The explorer's own seed: an exploration repeats exactly.
    seed: u64,
    /// The share of runs that are blind: a fresh seed, as `properties` runs.
    blind: f32 = 0.2,
    /// Of the rest, the share that flip one named choice (SAGE's move); the
    /// others re-roll the future from a point in a run (Antithesis's).
    flip: f32 = 0.5,
    /// **AIMED FLIPS**: flip toward the alternative of a named choice that
    /// runs have taken least, and count a run that takes one never taken
    /// before as new. False: a flip picks its choice and alternative at
    /// random.
    aim: bool = true,
};

/// How a run was made.
pub const Move = enum { blind, branch, flip };

/// What an exploration found, for its report.
pub const Report = struct {
    runs: u32 = 0,
    corpus: u32 = 0,
    /// Alternatives of named choices taken for the first time.
    decisions: u32 = 0,
    /// Runs whose replay came apart from the tape they replayed: their
    /// moves are counted as made, but what they did was closer to a blind
    /// run. A simulator whose runs drift is not a function of its tape, and
    /// a benchmark of it is not one of steering.
    drifted: u32 = 0,
    by_move: [3]u32 = @splat(0),
    /// Runs that found something new to the explorer, by move.
    new_by_move: [3]u32 = @splat(0),
    /// The tapes of runs whose oracle failed, in the order found. The
    /// caller owns them (`deinit`).
    failures: std.ArrayList(Tape) = .empty,
    /// Per catalog site, in catalog order: the run that first reached it in
    /// this exploration, and by which move; null if none did.
    first: []?First = &.{},

    pub const First = struct { run: u32, move: Move };

    pub fn deinit(r: *Report, gpa: Allocator) void {
        for (r.failures.items) |*t| t.deinit();
        r.failures.deinit(gpa);
        gpa.free(r.first);
    }
};

const Seen = struct { passes: u32, fails: u32, reach: coverage.Operands, edge: coverage.Operands };

const Entry = struct {
    tape: Tape,
    /// Catalog indices of the sites this run reached.
    hits: []u32,
};

/// **THE LOOP.** Runs `run` `options.budget` times. A blind run draws from a
/// fresh seed. Otherwise it starts from a run in the corpus, chosen by the
/// rarity of what that run reached, and either replays it to a random point
/// and draws fresh from there, or replays it to one of its named choices,
/// forces another alternative there, and draws fresh after. A run joins the
/// corpus if it did something no run before it in this exploration did: a
/// site reached for the first time, or a comparison's reach or edge moved
/// (the catalog's own counts say which). Coverage accumulates in the catalog
/// as for any sweep, so `coverage.report` afterwards judges the whole
/// exploration.
pub fn explore(gpa: Allocator, run: RunFn, options: Options) !Report {
    var report: Report = .{};
    errdefer report.deinit(gpa);
    var own = std.Random.DefaultPrng.init(options.seed);
    const r = own.random();

    var sites: std.ArrayList(*coverage.Site) = .empty;
    defer sites.deinit(gpa);
    var it = coverage.catalog();
    while (it.next()) |site| try sites.append(gpa, site);
    const n = sites.items.len;
    report.first = try gpa.alloc(?Report.First, n);
    @memset(report.first, null);
    const before = try gpa.alloc(Seen, n);
    defer gpa.free(before);
    // How many corpus runs reached each site, for rarity.
    const reached_by = try gpa.alloc(u32, n);
    defer gpa.free(reached_by);
    @memset(reached_by, 0);
    // Whether any run of this exploration reached each site.
    const ever = try gpa.alloc(bool, n);
    defer gpa.free(ever);
    for (sites.items, ever) |site, *e| e.* = site.hit();

    var corpus: std.ArrayList(Entry) = .empty;
    defer {
        for (corpus.items) |*e| {
            e.tape.deinit();
            gpa.free(e.hits);
        }
        corpus.deinit(gpa);
    }
    var hits: std.ArrayList(u32) = .empty;
    defer hits.deinit(gpa);
    // How often each alternative of each named choice has been taken, by
    // every run of this exploration: the branches of the named decisions.
    var taken: std.StringHashMap([]u32) = .init(gpa);
    defer {
        var vit = taken.valueIterator();
        while (vit.next()) |v| gpa.free(v.*);
        taken.deinit();
    }

    while (report.runs < options.budget) : (report.runs += 1) {
        const fresh = r.int(u64);
        var move: Move = .blind;
        var tape = if (corpus.items.len == 0 or r.float(f32) < options.blind)
            Tape.init(gpa, fresh)
        else blk: {
            const from = &corpus.items[pickEntry(r, corpus.items, reached_by)].tape;
            if (from.choices.items.len > 0 and r.float(f32) < options.flip) {
                const aimed = if (options.aim) aimFlip(r, from.choices.items, &taken) else null;
                const index = if (aimed) |a| a.index else r.uintLessThan(usize, from.choices.items.len);
                const c = from.choices.items[index];
                if (c.alternatives > 1) {
                    var alt = if (aimed) |a| a.alternative else r.uintLessThan(u32, c.alternatives - 1);
                    if (aimed == null and alt >= c.chosen) alt += 1;
                    move = .flip;
                    break :blk Tape.branch(gpa, from, c.position, fresh, .{ .index = @intCast(index), .alternative = alt });
                }
            }
            move = .branch;
            break :blk Tape.branch(gpa, from, r.uintAtMost(u32, from.position()), fresh, null);
        };
        var keep = false;
        defer if (!keep) tape.deinit();
        // A tape kept points at no other: the corpus moves and is freed.
        defer if (keep) {
            tape.replay = null;
            tape.replay_upto = 0;
            tape.replay_from = 0;
        };
        report.by_move[@intFromEnum(move)] += 1;

        for (sites.items, before) |site, *b| b.* = .{ .passes = site.passes, .fails = site.fails, .reach = site.reach, .edge = site.edge };
        const failed = if (run(&tape)) false else |_| true;

        hits.clearRetainingCapacity();
        var new = false;
        for (sites.items, before, 0..) |site, b, i| {
            if (site.passes == b.passes and site.fails == b.fails) continue;
            try hits.append(gpa, @intCast(i));
            if (!ever[i]) {
                ever[i] = true;
                report.first[i] = .{ .run = report.runs, .move = move };
                new = true;
            }
            if (site.fails > 0 and b.fails == 0) new = true;
            if (!std.meta.eql(site.reach, b.reach) or !std.meta.eql(site.edge, b.edge)) new = true;
        }
        if (tape.drifted) report.drifted += 1;
        for (tape.choices.items) |c| {
            const counts = taken.get(c.name) orelse blk: {
                const fresh_counts = try gpa.alloc(u32, c.alternatives);
                @memset(fresh_counts, 0);
                try taken.put(c.name, fresh_counts);
                break :blk fresh_counts;
            };
            if (c.chosen >= counts.len) continue;
            if (counts[c.chosen] == 0) {
                new = true;
                report.decisions += 1;
            }
            counts[c.chosen] += 1;
        }
        if (failed) {
            keep = true;
            try report.failures.append(gpa, tape);
            continue;
        }
        if (new) {
            report.new_by_move[@intFromEnum(move)] += 1;
            for (hits.items) |i| reached_by[i] += 1;
            try corpus.append(gpa, .{ .tape = tape, .hits = try gpa.dupe(u32, hits.items) });
            keep = true;
        }
    }
    report.corpus = @intCast(corpus.items.len);
    return report;
}

/// **WHERE TO FLIP, AIMED**: among a run's named choices, the one whose
/// least-taken other alternative has been taken least, weighted so a choice
/// never flipped that way is likeliest; and that alternative.
fn aimFlip(r: std.Random, choices: []const Choice, taken: *const std.StringHashMap([]u32)) ?Force {
    var total: f64 = 0;
    for (choices) |c| total += aimWeight(c, taken).weight;
    if (total <= 0) return null;
    var at = r.float(f64) * total;
    for (choices, 0..) |c, i| {
        const w = aimWeight(c, taken);
        at -= w.weight;
        if (at <= 0 and w.weight > 0) return .{ .index = @intCast(i), .alternative = w.alternative };
    }
    return null;
}

fn aimWeight(c: Choice, taken: *const std.StringHashMap([]u32)) struct { weight: f64, alternative: u32 } {
    if (c.alternatives < 2) return .{ .weight = 0, .alternative = 0 };
    const counts = taken.get(c.name) orelse return .{ .weight = 1, .alternative = if (c.chosen == 0) 1 else 0 };
    var best: u32 = std.math.maxInt(u32);
    var alt: u32 = 0;
    var a: u32 = 0;
    while (a < c.alternatives) : (a += 1) {
        if (a == c.chosen) continue;
        const n = if (a < counts.len) counts[a] else 0;
        if (n < best) {
            best = n;
            alt = a;
        }
    }
    // A never-taken alternative weighs most, falling with the square of
    // how often it has been taken.
    return .{ .weight = 1.0 / (1.0 + @as(f64, @floatFromInt(best)) * @as(f64, @floatFromInt(best))), .alternative = alt };
}

/// A corpus run, weighted by what it reached that few others did: each site
/// it reached counts one over the number of corpus runs that reached it.
fn pickEntry(r: std.Random, corpus: []const Entry, reached_by: []const u32) usize {
    var total: f64 = 0;
    for (corpus) |e| total += weight(e, reached_by);
    var at = r.float(f64) * total;
    for (corpus, 0..) |e, i| {
        at -= weight(e, reached_by);
        if (at <= 0) return i;
    }
    return corpus.len - 1;
}

fn weight(e: Entry, reached_by: []const u32) f64 {
    var w: f64 = 0.01;
    for (e.hits) |i| w += 1.0 / @as(f64, @floatFromInt(@max(reached_by[i], 1)));
    return w;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A small "simulator": draws of several sizes, a named choice, and a draw
/// whose size depends on that choice, so a forced choice changes what the
/// run asks for afterwards.
fn story(r: std.Random, out: *std.ArrayList(u64)) !void {
    try out.append(testing.allocator, r.int(u64));
    try out.append(testing.allocator, r.uintLessThan(u8, 10));
    const big = pick(r, "story: big", .{ .no = 3, .yes = 1 });
    try out.append(testing.allocator, @intFromEnum(big));
    const n: usize = if (big == .yes) 20 else 3;
    for (0..n) |_| try out.append(testing.allocator, r.intRangeAtMost(u64, 0, 1000));
    try out.append(testing.allocator, @intFromBool(r.boolean()));
}

test "a tape's run is the run its seed gives, recorded" {
    var plain: std.ArrayList(u64) = .empty;
    defer plain.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(42);
    try story(prng.random(), &plain);

    var tape = Tape.init(testing.allocator, 42);
    defer tape.deinit();
    var taped: std.ArrayList(u64) = .empty;
    defer taped.deinit(testing.allocator);
    try story(tape.random(), &taped);

    try testing.expectEqualSlices(u64, plain.items, taped.items);
    try testing.expect(tape.position() > 0);
    try testing.expectEqual(@as(usize, 1), tape.choices.items.len);
    try testing.expectEqualStrings("story: big", tape.choices.items[0].name);
}

test "replaying a whole tape gives the same fills and the same run" {
    for (0..200) |seed| {
        var first = Tape.init(testing.allocator, seed);
        defer first.deinit();
        var a: std.ArrayList(u64) = .empty;
        defer a.deinit(testing.allocator);
        try story(first.random(), &a);

        // A different fresh seed: nothing past the tape may be drawn.
        var again = Tape.branch(testing.allocator, &first, first.position(), seed +% 7777, null);
        defer again.deinit();
        var b: std.ArrayList(u64) = .empty;
        defer b.deinit(testing.allocator);
        try story(again.random(), &b);

        try testing.expectEqualSlices(u64, a.items, b.items);
        try testing.expectEqualSlices(u8, first.bytes.items, again.bytes.items);
        try testing.expectEqualSlices(u32, first.ends.items, again.ends.items);
        try testing.expect(!again.drifted);
    }
}

test "a branch keeps the past and re-rolls the future" {
    var first = Tape.init(testing.allocator, 1);
    defer first.deinit();
    var a: std.ArrayList(u64) = .empty;
    defer a.deinit(testing.allocator);
    try story(first.random(), &a);

    var differed = false;
    for (0..20) |fresh| {
        var b_tape = Tape.branch(testing.allocator, &first, 2, 1000 + fresh, null);
        defer b_tape.deinit();
        var b: std.ArrayList(u64) = .empty;
        defer b.deinit(testing.allocator);
        try story(b_tape.random(), &b);
        // The first two draws are the past.
        try testing.expectEqualSlices(u64, a.items[0..2], b.items[0..2]);
        if (!std.mem.eql(u64, a.items, b.items)) differed = true;
    }
    try testing.expect(differed);
}

test "a forced choice takes the other way, and the draws after it keep their places" {
    // Find a seed whose run did not choose big.
    var seed: u64 = 0;
    while (true) : (seed += 1) {
        var probe = Tape.init(testing.allocator, seed);
        defer probe.deinit();
        var out: std.ArrayList(u64) = .empty;
        defer out.deinit(testing.allocator);
        try story(probe.random(), &out);
        if (probe.choices.items[0].chosen == 0) break;
    }
    var first = Tape.init(testing.allocator, seed);
    defer first.deinit();
    var a: std.ArrayList(u64) = .empty;
    defer a.deinit(testing.allocator);
    try story(first.random(), &a);
    const c = first.choices.items[0];

    // Flip it: replay up to the choice, force `.yes`, draw fresh after.
    var flipped = Tape.branch(testing.allocator, &first, c.position, 99, .{ .index = 0, .alternative = 1 });
    defer flipped.deinit();
    var b: std.ArrayList(u64) = .empty;
    defer b.deinit(testing.allocator);
    try story(flipped.random(), &b);

    try testing.expectEqualSlices(u64, a.items[0..2], b.items[0..2]);
    try testing.expectEqual(@as(u64, 1), b.items[2]);
    try testing.expectEqual(@as(u32, 1), flipped.choices.items[0].chosen);
    try testing.expectEqual(c.position, flipped.choices.items[0].position);
    try testing.expectEqual(@as(usize, 2 + 1 + 20 + 1), b.items.len);
    try testing.expect(!flipped.drifted);
}

test "a flipped tape, replayed, takes the flip" {
    for (0..200) |seed| {
        var first = Tape.init(testing.allocator, seed);
        defer first.deinit();
        var a: std.ArrayList(u64) = .empty;
        defer a.deinit(testing.allocator);
        try story(first.random(), &a);
        const c = first.choices.items[0];
        var flipped = Tape.branch(testing.allocator, &first, c.position, seed + 500, .{ .index = 0, .alternative = 1 - c.chosen });
        defer flipped.deinit();
        var b: std.ArrayList(u64) = .empty;
        defer b.deinit(testing.allocator);
        try story(flipped.random(), &b);
        try testing.expect(!flipped.unfaithful);

        var again = Tape.branch(testing.allocator, &flipped, flipped.position(), seed + 900, null);
        defer again.deinit();
        var d: std.ArrayList(u64) = .empty;
        defer d.deinit(testing.allocator);
        try story(again.random(), &d);
        try testing.expectEqualSlices(u64, b.items, d.items);
        try testing.expectEqual(1 - c.chosen, again.choices.items[0].chosen);
    }
}

fn wide(r: std.Random, out: *std.ArrayList(u64)) !void {
    try out.append(testing.allocator, r.int(u16));
    const k = pickAs(r, usize, "wide: one of fourteen", .{ .a = 1, .b = 1, .c = 1, .d = 1, .e = 1, .f = 1, .g = 1, .h = 1, .i = 1, .j = 1, .k = 1, .l = 1, .m = 1, .n = 1 });
    try out.append(testing.allocator, @intFromEnum(k));
    const y = flag(r, "wide: yes");
    try out.append(testing.allocator, @intFromBool(y));
    for (0..@as(usize, if (y) 9 else 2) + @intFromEnum(k)) |_| try out.append(testing.allocator, r.uintLessThan(u64, 77));
}

test "pickAs and flag draw as the calls they replace, and their flips replay" {
    for (0..100) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        _ = r.int(u16);
        const plain_k = r.uintLessThan(usize, 14);
        const plain_y = r.boolean();
        var tape = Tape.init(testing.allocator, seed);
        defer tape.deinit();
        var a: std.ArrayList(u64) = .empty;
        defer a.deinit(testing.allocator);
        try wide(tape.random(), &a);
        try testing.expectEqual(@as(u64, plain_k), a.items[1]);
        try testing.expectEqual(@as(u64, @intFromBool(plain_y)), a.items[2]);

        for (tape.choices.items, 0..) |c, index| {
            const alt: u32 = (c.chosen + 1 + @as(u32, @intCast(seed % (c.alternatives - 1)))) % c.alternatives;
            var flipped = Tape.branch(testing.allocator, &tape, c.position, seed + 1, .{ .index = @intCast(index), .alternative = alt });
            defer flipped.deinit();
            var b: std.ArrayList(u64) = .empty;
            defer b.deinit(testing.allocator);
            try wide(flipped.random(), &b);
            try testing.expect(!flipped.unfaithful);
            try testing.expectEqual(alt, flipped.choices.items[index].chosen);
            var again = Tape.branch(testing.allocator, &flipped, flipped.position(), seed + 2, null);
            defer again.deinit();
            var d: std.ArrayList(u64) = .empty;
            defer d.deinit(testing.allocator);
            try wide(again.random(), &d);
            try testing.expectEqualSlices(u64, b.items, d.items);
        }
    }
}

test "pick without a tape is a plain weighted choice" {
    var prng = std.Random.DefaultPrng.init(3);
    var yes: u32 = 0;
    for (0..4000) |_| {
        if (pick(prng.random(), "plain", .{ .no = 3, .yes = 1 }) == .yes) yes += 1;
    }
    try testing.expect(yes > 800 and yes < 1200);
}

/// A story whose deepest property needs three rare named choices in a row
/// (one in sixteen each): blind seeds reach it about one run in 4,096.
fn deep(tape: *Tape) anyerror!void {
    const r = tape.random();
    _ = r.int(u64);
    if (pick(r, "deep: the first door", .{ .shut = 15, .open = 1 }) == .shut) return;
    coverage.reachable(@src(), "deep: past the first door", null);
    _ = r.int(u32);
    if (pick(r, "deep: the second door", .{ .shut = 15, .open = 1 }) == .shut) return;
    coverage.reachable(@src(), "deep: past the second door", null);
    if (pick(r, "deep: the third door", .{ .shut = 15, .open = 1 }) == .shut) return;
    coverage.reachable(@src(), "deep: past the third door", null);
}

fn deepSite() *coverage.Site {
    var it = coverage.catalog();
    while (it.next()) |site| {
        if (std.mem.eql(u8, std.mem.span(site.message), "deep: past the third door")) return site;
    }
    unreachable;
}

test "the explorer reaches what three rare choices guard, and blind seeds at the same budget do not" {
    coverage.reset();
    var blind = try explore(testing.allocator, deep, .{ .budget = 400, .seed = 1, .blind = 1.0 });
    defer blind.deinit(testing.allocator);
    const blind_reached = deepSite().hit();

    coverage.reset();
    var steered = try explore(testing.allocator, deep, .{ .budget = 400, .seed = 1 });
    defer steered.deinit(testing.allocator);
    try testing.expect(!blind_reached);
    try testing.expect(deepSite().hit());
}

test "an exploration repeats exactly" {
    coverage.reset();
    var a = try explore(testing.allocator, deep, .{ .budget = 300, .seed = 9 });
    defer a.deinit(testing.allocator);
    const passes_a = deepSite().passes;
    coverage.reset();
    var b = try explore(testing.allocator, deep, .{ .budget = 300, .seed = 9 });
    defer b.deinit(testing.allocator);
    try testing.expectEqual(passes_a, deepSite().passes);
    try testing.expectEqual(a.corpus, b.corpus);
    try testing.expectEqualSlices(u32, &a.by_move, &b.by_move);
    try testing.expectEqualSlices(u32, &a.new_by_move, &b.new_by_move);
}

test "aimed flips open three rare doors in a few runs" {
    coverage.reset();
    var aimed = try explore(testing.allocator, deep, .{ .budget = 30, .seed = 4, .blind = 0.0 });
    defer aimed.deinit(testing.allocator);
    try testing.expect(deepSite().hit());
    try testing.expect(aimed.decisions >= 6);
}

/// A "simulator" that is not a function of its tape: every other call draws
/// one byte more.
var odd_calls: u32 = 0;
fn unsteady(tape: *Tape) anyerror!void {
    const r = tape.random();
    odd_calls +%= 1;
    if (odd_calls % 2 == 0) _ = r.int(u8);
    _ = pick(r, "unsteady: a door", .{ .shut = 3, .open = 1 });
    for (0..5) |_| _ = r.int(u32);
}

test "a run that drifts from the tape it replays is counted, and replays no further" {
    coverage.reset();
    odd_calls = 0;
    var report = try explore(testing.allocator, unsteady, .{ .budget = 200, .seed = 3, .blind = 0.2 });
    defer report.deinit(testing.allocator);
    try testing.expect(report.drifted > 0);

    // A replay that drifts at its first fill answers every later one fresh.
    var first = Tape.init(testing.allocator, 1);
    defer first.deinit();
    const r1 = first.random();
    _ = r1.int(u8);
    _ = r1.int(u32);
    var again = Tape.branch(testing.allocator, &first, first.position(), 99, null);
    defer again.deinit();
    const r2 = again.random();
    const x = r2.int(u32); // four bytes where the tape has one: drift
    _ = x;
    try testing.expect(again.drifted);
    const y = r2.int(u32); // the tape's second fill is four bytes too, but is not replayed
    var fresh = Tape.init(testing.allocator, 99);
    defer fresh.deinit();
    const f = fresh.random();
    _ = f.int(u32);
    try testing.expectEqual(f.int(u32), y);
}
