//! A site the scanner must refuse: its message is not a string literal, and
//! nothing above it says why it need not be scanned (build.zig expects the
//! scan to fail on this file, naming the site).
const std = @import("std");
const coverage = @import("coverage");

pub fn unexplained(comptime which: u8) void {
    coverage.reachable(@src(), std.fmt.comptimePrint("unexplained {d}", .{which}), null);
}
