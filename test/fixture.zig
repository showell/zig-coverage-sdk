//! Assertions in places nothing calls, for tools/scan.zig to find (see
//! catalog_test.zig). Only `reached` runs.
const std = @import("std");
const coverage = @import("coverage");

comptime {
    coverage.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

pub fn reached(x: u32) void {
    coverage.sometimes(@src(), x == 1, "reached", null);
}

pub fn neverCalledPlain(x: u32) void {
    coverage.sometimes(@src(), x == 1, "plain, never called", null);
}

pub const Table = struct {
    n: u32 = 0,

    pub fn neverCalledMethod(self: *Table) void {
        coverage.always(@src(), self.n < 10, "method, never called", null);
    }

    pub fn transmit(self: *Table, wire: anytype, now: i96) void {
        wire.send(self.n);
        coverage.sometimes(@src(), now > 0, "anytype method, called with two types", null);
    }
};

pub fn neverCalledGeneric(comptime T: type, x: T) T {
    coverage.reachable(@src(), "generic, never called", null);
    return x;
}

pub const Nested = struct {
    pub const Deeper = struct {
        pub fn neverCalledNested() void {
            coverage.@"unreachable"(@src(), "nested, never called", null);
        }
    };
};

fn privateNeverCalled() void {
    coverage.alwaysOrUnreachable(@src(), true, "private, never called", null);
}

test "a test block's assertion is not cataloged by the scanner" {
    coverage.reachable(@src(), "inside a test", null);
}
