//
// ─── Exercise 048: BEAM search ─────────────────────────────────────────
//
// Upcast by how much? Tiles how big? Which loop to unroll? The best
// choice depends on the chip, the shapes, even the memory layout, and
// it's very hard to predict. tinygrad's answer: just TRY them. With
// BEAM=2 (an environment variable) it compiles many versions of a kernel,
// times each one, and keeps the fastest.
//
// Trying every combination would take forever, so it searches:
//
//     beam = [the kernel with no optimizations]
//     repeat:
//         candidates = every beam kernel, plus one more optimization
//         time them all, keep the fastest `width` as the new beam
//         stop when the fastest candidate isn't faster than before
//
// With width 1 that's greedy: always take the best next step. It can get
// stuck: sometimes you must take a step that looks worse first. Keeping a
// few runners-up in the beam gets around that.
//
// Here a "kernel" is (upcast level, local level), each 0 to 3, and
// timing is a table lookup, made up so that greedy gets stuck.
//
// YOUR TASK: keep the best `width` candidates, and stop when there's no
// progress.
//
const std = @import("std");

const Kernel = struct { upcast: u2 = 0, local: u2 = 0 };

// timing[upcast][local], in microseconds
const timing = [4][4]f64{
    .{ 100, 90, 95, 99 },
    .{ 92, 97, 98, 96 },
    .{ 85, 70, 60, 55 },
    .{ 97, 80, 50, 40 },
};

const Timer = struct {
    timed: usize = 0, // how many kernels we compiled and ran

    fn time(t: *Timer, k: Kernel) f64 {
        t.timed += 1;
        return timing[k.upcast][k.local];
    }
};

const Scored = struct { kernel: Kernel, us: f64 };

fn fasterFirst(_: void, a: Scored, b: Scored) bool {
    return a.us < b.us;
}

/// Every kernel reachable by adding one optimization to k.
fn neighbours(k: Kernel, out: *[2]Kernel) []Kernel {
    var n: usize = 0;
    if (k.upcast < 3) {
        out[n] = .{ .upcast = k.upcast + 1, .local = k.local };
        n += 1;
    }
    if (k.local < 3) {
        out[n] = .{ .upcast = k.upcast, .local = k.local + 1 };
        n += 1;
    }
    return out[0..n];
}

fn beamSearch(alloc: std.mem.Allocator, timer: *Timer, width: usize) !Scored {
    const start: Kernel = .{};
    var beam: std.ArrayList(Scored) = .empty;
    defer beam.deinit(alloc);
    try beam.append(alloc, .{ .kernel = start, .us = timer.time(start) });
    var best = beam.items[0];

    while (true) {
        var candidates: std.ArrayList(Scored) = .empty;
        defer candidates.deinit(alloc);
        for (beam.items) |b| {
            var buf: [2]Kernel = undefined;
            for (neighbours(b.kernel, &buf)) |k| {
                // don't time the same kernel twice
                const seen = for (candidates.items) |c| {
                    if (std.meta.eql(c.kernel, k)) break true;
                } else false;
                if (!seen) try candidates.append(alloc, .{ .kernel = k, .us = timer.time(k) });
            }
        }
        if (candidates.items.len == 0) return best;

        std.mem.sort(Scored, candidates.items, {}, fasterFirst);
        // no progress: the fastest new kernel isn't faster than the best so far
        if (???) return best;
        best = candidates.items[0];

        // the new beam: the fastest `width` candidates
        beam.clearRetainingCapacity();
        const keep = ???;
        try beam.appendSlice(alloc, candidates.items[0..keep]);
    }
}

test "greedy gets stuck" {
    var timer: Timer = .{};
    const r = try beamSearch(std.testing.allocator, &timer, 1);
    try std.testing.expectEqual(90, r.us);
}

test "a wider beam finds the fastest kernel" {
    var timer: Timer = .{};
    const r = try beamSearch(std.testing.allocator, &timer, 2);
    try std.testing.expectEqual(40, r.us);
    try std.testing.expectEqual(Kernel{ .upcast = 3, .local = 3 }, r.kernel);
    // and without timing all 16 kernels
    try std.testing.expect(timer.timed < 16);
}
