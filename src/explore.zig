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
    /// A replayed fill whose length differed from the recorded one: the run
    /// went another way than the tape it replays, so its past is not that
    /// tape's. Fresh bytes answer it, and this says it happened.
    drifted: bool = false,
    force: ?Force = null,

    /// A tape that draws from `seed`: a run under it is the run `seed`'s
    /// PRNG gives, recorded.
    pub fn init(gpa: Allocator, seed: u64) Tape {
        return .{ .gpa = gpa, .prng = .init(seed) };
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

    pub fn deinit(t: *Tape) void {
        t.bytes.deinit(t.gpa);
        t.ends.deinit(t.gpa);
        t.choices.deinit(t.gpa);
    }

    pub fn position(t: *const Tape) u32 {
        return @intCast(t.ends.items.len);
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
            if (t.replay) |old| if (at < t.replay_upto) {
                const was = old.fillAt(at);
                if (was.len == buf.len) {
                    @memcpy(buf, was);
                    break :answer;
                }
                t.drifted = true;
            };
            t.prng.random().bytes(buf);
        }
        // Out of memory ends the run's record, not the run: the draw is
        // answered either way, and a short tape only replays less.
        t.bytes.appendSlice(t.gpa, buf) catch return;
        t.ends.append(t.gpa, @intCast(t.bytes.items.len)) catch return;
    }
};

/// **A NAMED CHOICE** among the fields of `weights`, an anonymous struct of
/// comptime integer weights: `pick(r, "fat: the volume is FAT32", .{ .no = 3,
/// .yes = 1 })` answers `.no` or `.yes`. One draw, as `uintLessThan` over the
/// total weight, whatever the source; under a `Tape` the choice is logged,
/// and a forced one takes the forced alternative after drawing all the same.
pub fn pick(r: std.Random, comptime name: []const u8, comptime weights: anytype) std.meta.FieldEnum(@TypeOf(weights)) {
    const fields = @typeInfo(@TypeOf(weights)).@"struct".fields;
    comptime var total: u32 = 0;
    inline for (fields) |f| total += @field(weights, f.name);
    const tape = Tape.of(r);
    const at: u32 = if (tape) |t| t.position() else 0;
    const draw = r.uintLessThan(u32, total);
    var chosen: u32 = 0;
    var below: u32 = 0;
    inline for (fields, 0..) |f, i| {
        below += @field(weights, f.name);
        if (draw >= below) chosen = i + 1;
    }
    if (tape) |t| {
        const index: u32 = @intCast(t.choices.items.len);
        if (t.force) |force| if (force.index == index and force.alternative < fields.len) {
            chosen = force.alternative;
        };
        t.choices.append(t.gpa, .{ .name = name, .position = at, .chosen = chosen, .alternatives = fields.len }) catch {};
    }
    return @enumFromInt(chosen);
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

test "pick without a tape is a plain weighted choice" {
    var prng = std.Random.DefaultPrng.init(3);
    var yes: u32 = 0;
    for (0..4000) |_| {
        if (pick(prng.random(), "plain", .{ .no = 3, .yes = 1 }) == .yes) yes += 1;
    }
    try testing.expect(yes > 800 and yes < 1200);
}
