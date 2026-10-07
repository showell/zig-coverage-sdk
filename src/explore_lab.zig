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
//! A second story, **the doors**, is breadth over eight scenarios with a
//! chain of four rare steps inside one of them.
//!
//! Each strategy explores once per seed at the largest budget; the smaller
//! budgets are read off the run at which each property was first reached
//! (`Report.first`), since no strategy looks at its budget. For each it
//! prints the properties left unreached (mean and standard error over the
//! seeds), how many explorations reached each property, and how the runs
//! were made.

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

/// **THE DOORS** (the cold brainstorm's test): eight scenarios, each a
/// shallow property, and in one of them a chain of four doors, each opened
/// only by the right operation right after the last door opened. Blind runs
/// rarely open all four; a run that opened one is the place to look for the
/// next.
fn doors(tape: *explore.Tape) anyerror!void {
    const r = tape.random();
    const arm = explore.pick(r, "doors: the arm", .{ .a = 1, .b = 1, .c = 1, .d = 1, .e = 1, .f = 1, .g = 1, .h = 1 });
    switch (arm) {
        .a => coverage.reachable(@src(), "doors arm a", null),
        .b => coverage.reachable(@src(), "doors arm b", null),
        .c => coverage.reachable(@src(), "doors arm c", null),
        .d => coverage.reachable(@src(), "doors arm d", null),
        .e => coverage.reachable(@src(), "doors arm e", null),
        .f => coverage.reachable(@src(), "doors arm f", null),
        .g => coverage.reachable(@src(), "doors arm g", null),
        .h => coverage.reachable(@src(), "doors arm h", null),
    }
    const keys = [_]u8{ 3, 7, 1, 9 };
    var opened: usize = 0;
    for (0..100) |_| {
        const op: u8 = @intFromEnum(explore.pick(r, "doors: the operation", .{ .o0 = 1, .o1 = 1, .o2 = 1, .o3 = 1, .o4 = 1, .o5 = 1, .o6 = 1, .o7 = 1, .o8 = 1, .o9 = 1 }));
        _ = r.int(u32); // an unnamed draw beside it
        if (arm != .f) continue;
        opened = if (opened < keys.len and op == keys[opened]) opened + 1 else 0;
        if (opened >= 1) coverage.reachable(@src(), "doors: the first door", null);
        if (opened >= 2) coverage.reachable(@src(), "doors: the second door", null);
        if (opened >= 3) coverage.reachable(@src(), "doors: the third door", null);
        if (opened >= 4) coverage.reachable(@src(), "doors: the fourth door", null);
    }
}

const Story = struct { name: []const u8, run: explore.RunFn, prefix: []const u8 };
const stories = [_]Story{
    .{ .name = "fat-shaped", .run = story, .prefix = "lab " },
    .{ .name = "doors", .run = doors, .prefix = "doors" },
};

fn mine(site: *const coverage.Site, s: Story) bool {
    return std.mem.startsWith(u8, std.mem.span(site.message), s.prefix) and site.kind.basic() == .reachable;
}

const Column = struct { name: []const u8, options: explore.Options };

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const seeds: u64 = 60;
    const budgets = [_]u32{ 10, 30, 100, 300 };
    const last = budgets[budgets.len - 1];
    const columns = [_]Column{
        .{ .name = "blind", .options = .{ .budget = 0, .seed = 0, .blind = 1.0 } },
        .{ .name = "explorer", .options = .{ .budget = 0, .seed = 0 } },
        .{ .name = "+moment .3", .options = .{ .budget = 0, .seed = 0, .moment = 0.3 } },
        .{ .name = "+bandit", .options = .{ .budget = 0, .seed = 0, .bandit = true, .warmup = 8 } },
        .{ .name = "+moment warm", .options = .{ .budget = 0, .seed = 0, .moment = 0.3, .warmup = 8 } },
        .{ .name = "+all", .options = .{ .budget = 0, .seed = 0, .moment = 0.3, .fast = true, .bandit = true, .warmup = 8, .per_name = true, .early = 0.5 } },
    };
    for (stories) |st| {
        var names: [16][]const u8 = undefined;
        var n_names: usize = 0;
        var it = coverage.catalog();
        while (it.next()) |site| if (mine(site, st)) {
            names[n_names] = std.mem.span(site.message);
            n_names += 1;
        };
        std.debug.print("\n== {s}: {d} properties, {d} explorer seeds; unreached at each budget (mean ± standard error), then how many explorations reached each property by {d} runs\n", .{ st.name, n_names, seeds, last });
        std.debug.print("  {s:<12}", .{""});
        for (budgets) |b| std.debug.print("  {d:>10}", .{b});
        std.debug.print("  | moves (blind branch flip moment), and the share that found something never seen\n", .{});
        for (columns) |col| {
            var missed: [budgets.len][seeds]f64 = undefined;
            var reached_in = [_]u32{0} ** 16;
            var by_move: [4]u64 = @splat(0);
            var novel: [4]u64 = @splat(0);
            for (0..seeds) |seed| {
                coverage.reset();
                var o = col.options;
                o.budget = last;
                o.seed = seed + 1;
                var report = try explore.explore(gpa, st.run, o);
                defer report.deinit(gpa);
                for (report.by_move, report.novel_by_move, 0..) |m, nv, k| {
                    by_move[k] += m;
                    novel[k] += nv;
                }
                for (budgets, 0..) |b, bi| {
                    var c = coverage.catalog();
                    var i: usize = 0;
                    var miss: f64 = 0;
                    while (c.next()) |site| : (i += 1) if (mine(site, st)) {
                        if (report.first[i] == null or report.first[i].?.run >= b) miss += 1;
                    };
                    missed[bi][seed] = miss;
                }
                var c = coverage.catalog();
                var j: usize = 0;
                while (c.next()) |site| if (mine(site, st)) {
                    if (site.passes > 0) reached_in[j] += 1;
                    j += 1;
                };
            }
            std.debug.print("  {s:<12}", .{col.name});
            for (missed) |row| {
                const ms = meanSe(&row);
                std.debug.print("  {d:>4.1}±{d:<4.1}", .{ ms[0], ms[1] });
            }
            std.debug.print("  |", .{});
            for (reached_in[0..n_names]) |n| std.debug.print(" {d:>2}", .{n});
            std.debug.print("  |", .{});
            for (by_move, novel) |m, nv| {
                if (m == 0) std.debug.print("     -", .{}) else std.debug.print(" {d:>3}%{d:<2}", .{ m * 100 / (seeds * last), nv * 100 / m });
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("  properties, in column order:\n", .{});
        for (names[0..n_names], 0..) |n, i| std.debug.print("    {d:>2}. {s}\n", .{ i + 1, n });
    }
}

fn meanSe(xs: []const f64) [2]f64 {
    var sum: f64 = 0;
    for (xs) |x| sum += x;
    const n: f64 = @floatFromInt(xs.len);
    const mean = sum / n;
    var ss: f64 = 0;
    for (xs) |x| ss += (x - mean) * (x - mean);
    return .{ mean, @sqrt(ss / (n - 1)) / @sqrt(n) };
}
