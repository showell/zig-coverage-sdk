//! **THE SCANNER, JUDGED**: every assertion in fixture.zig is in the catalog,
//! whether or not its code was compiled, each exactly once.
const std = @import("std");
const coverage = @import("coverage");
const fixture = @import("fixture.zig");
const testing = std.testing;

fn count(message: []const u8) usize {
    var n: usize = 0;
    var it = coverage.catalog();
    while (it.next()) |s| {
        if (std.mem.eql(u8, std.mem.span(s.message), message)) n += 1;
    }
    return n;
}

const W1 = struct {
    pub fn send(_: W1, _: u32) void {}
};
const W2 = struct {
    pub fn send(_: W2, _: u32) void {}
};

test "every assertion in the scanned file, called or not, once each" {
    fixture.reached(1);
    var t: fixture.Table = .{};
    t.transmit(W1{}, 1);
    t.transmit(W2{}, 0);
    for ([_][]const u8{
        "reached",
        "plain, never called",
        "method, never called",
        "anytype method, called with two types",
        "generic, never called",
        "nested, never called",
        "private, never called",
    }) |m| {
        testing.expectEqual(@as(usize, 1), count(m)) catch |e| {
            std.debug.print("not cataloged exactly once: {s}\n", .{m});
            return e;
        };
    }
    // The one that ran, ran; the anytype one both ways, as one site.
    var it = coverage.catalog();
    while (it.next()) |s| {
        const m = std.mem.span(s.message);
        if (std.mem.eql(u8, m, "reached")) try testing.expect(s.holds());
        if (std.mem.eql(u8, m, "anytype method, called with two types")) {
            try testing.expectEqual(@as(u32, 1), s.passes);
            try testing.expectEqual(@as(u32, 1), s.fails);
        }
        if (std.mem.eql(u8, m, "plain, never called")) try testing.expect(!s.holds());
    }
}
