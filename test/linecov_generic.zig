//! **A GENERIC'S ROWS AT LINES ITS SOURCE NEVER HAD**: Zig 0.17.0 gives the
//! first and last rows of a generic function's instance wrong line numbers
//! (both backends; metal-vmm QUEUE 243). Here `pick`'s land on lines 34 and
//! 35 of this file, as it is laid out below them: line 34 is code too short
//! for its row's column (28), and 35 a comment, for its row at column 1.
//! linecov must refuse both rows, the one by its column, the other by its line.
const std = @import("std");

pub fn pick(r: std.Random, comptime weights: anytype) std.meta.FieldEnum(@TypeOf(weights)) {
    _ = r;
    return @fromBackingInt(@intCast(0));
}

var never = false;
test "pick" {
    var prng: std.Random.DefaultPrng = .init(1);
    if (never) _ = pick(prng.random(), .{ .a = 3, .b = 1 });
}
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
const m = 1;
//
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
// padding, so the misplaced rows land on lines that exist
