//! **THE EXPLORER'S LAB** (`zig build lab`): a synthetic story shaped like
//! gopher-metal's fat_sim, so a change to the explorer is measured in
//! seconds, not the quarter hour a real simulator's benchmark takes.
//!
//! A run makes three scenario choices first (a shape of four, a mode of three,
//! probes or not), then about a hundred operations drawn as fat_sim draws
//! them. Its properties are of three kinds:
//!   - **breadth**: a particular scenario, met only by a run that is in it;
//!   - **depth**: a rare sequence inside a common scenario (three `t`s in a
//!     row; fifteen `m`s in a run, with a numeric slope beside it);
//!   - **both**: a rare sequence inside a rare scenario.
//! For each strategy and budget it prints how many of the lab's properties
//! were left unreached, on average over the explorer seeds, and how many
//! explorations reached each depth property.

const std = @import("std");
const coverage = @import("coverage");
const explore = @import("explore");

const Shape = enum { a, b, c, d };

fn story(tape: *explore.Tape) anyerror!void {
    const r = tape.random();
    const shape = explore.pick(r, "lab: the shape", .{ .a = 1, .b = 1, .c = 1, .d = 1 });
    const mode = explore.pick(r, "lab: the mode", .{ .plain = 2, .filling = 1, .crowded = 1 });
    const probes = explore.flag(r, "lab: probes");

    // Breadth: scenarios a run is in or not.
    if (shape == .d and mode == .crowded) coverage.reachable(@src(), "lab breadth: d, crowded", null);
    if (shape == .c and mode == .filling and probes) coverage.reachable(@src(), "lab breadth: c, filling, probes", null);
    if (shape == .b and mode == .plain and !probes) coverage.reachable(@src(), "lab breadth: b, plain, no probes", null);
    if (shape == .a and mode == .crowded and probes) coverage.reachable(@src(), "lab breadth: a, crowded, probes", null);

    var t_run: u32 = 0;
    var m_count: u32 = 0;
    var last_x = false;
    const ops: usize = if (mode == .crowded) 160 else 100;
    for (0..ops) |_| {
        // fat_sim's operation weights.
        const op = explore.pick(r, "lab: the operation", .{ .w = 30, .a = 25, .r = 10, .n = 10, .m = 8, .t = 5, .x = 12 });
        _ = r.int(u32); // an unnamed draw, as a name or a size would be
        t_run = if (op == .t) t_run + 1 else 0;
        if (op == .m) m_count += 1;
        // Depth: rare sequences in common scenarios.
        if (t_run >= 3) coverage.reachable(@src(), "lab depth: three t in a row", null);
        if (t_run >= 4) coverage.reachable(@src(), "lab depth: four t in a row", null);
        if (shape == .d and probes and last_x and op == .t) coverage.reachable(@src(), "lab both: x then t, in d with probes", null);
        last_x = op == .x;
    }
    coverage.alwaysLessThan(@src(), m_count, @as(u32, 1000), "lab slope: the m count", null);
    if (m_count >= 15) coverage.reachable(@src(), "lab depth: fifteen m", null);
    if (m_count >= 18) coverage.reachable(@src(), "lab depth: eighteen m", null);
}

fn lab(site: *const coverage.Site) bool {
    return std.mem.startsWith(u8, std.mem.span(site.message), "lab ") and site.kind.basic() == .reachable;
}

const Column = struct { name: []const u8, options: explore.Options };

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const seeds: u64 = 20;
    const budgets = [_]u32{ 10, 30, 100, 300 };
    const columns = [_]Column{
        .{ .name = "blind", .options = .{ .budget = 0, .seed = 0, .blind = 1.0 } },
        .{ .name = "explorer", .options = .{ .budget = 0, .seed = 0 } },
        .{ .name = "random flips", .options = .{ .budget = 0, .seed = 0, .aim = false } },
        .{ .name = "+warmup 8", .options = .{ .budget = 0, .seed = 0, .warmup = 8 } },
        .{ .name = "+per name", .options = .{ .budget = 0, .seed = 0, .per_name = true } },
        .{ .name = "+early 0.5", .options = .{ .budget = 0, .seed = 0, .early = 0.5 } },
        .{ .name = "+all three", .options = .{ .budget = 0, .seed = 0, .warmup = 8, .per_name = true, .early = 0.5 } },
    };
    var names: [16][]const u8 = undefined;
    var n_names: usize = 0;
    var it = coverage.catalog();
    while (it.next()) |site| if (lab(site)) {
        names[n_names] = std.mem.span(site.message);
        n_names += 1;
    };
    std.debug.print("the lab: {d} properties; {d} explorer seeds each\n", .{ n_names, seeds });
    for (budgets) |budget| {
        std.debug.print("\nbudget {d}: unreached on average, and in how many explorations each property was reached\n", .{budget});
        for (columns) |col| {
            var missed: u64 = 0;
            var reached_in = [_]u32{0} ** 16;
            for (0..seeds) |seed| {
                coverage.reset();
                var o = col.options;
                o.budget = budget;
                o.seed = seed + 1;
                var report = try explore.explore(gpa, story, o);
                report.deinit(gpa);
                var c = coverage.catalog();
                var i: usize = 0;
                while (c.next()) |site| if (lab(site)) {
                    if (site.passes > 0) reached_in[i] += 1 else missed += 1;
                    i += 1;
                };
            }
            std.debug.print("  {s:<14} {d:>5.1}  |", .{ col.name, @as(f64, @floatFromInt(missed)) / @as(f64, @floatFromInt(seeds)) });
            for (reached_in[0..n_names]) |n| std.debug.print(" {d:>2}", .{n});
            std.debug.print("\n", .{});
        }
    }
    std.debug.print("\ncolumns of numbers, in order:\n", .{});
    for (names[0..n_names], 0..) |n, i| std.debug.print("  {d:>2}. {s}\n", .{ i + 1, n });
}
