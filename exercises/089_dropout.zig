//
// ─── Exercise 089: dropout ─────────────────────────────────────────────
//
// A network with many weights can *memorize* its training data instead of
// learning general patterns (101 shows this). Dropout is a surprisingly
// effective fix: during training, zero out each activation with
// probability p, at random, every step. The network can't rely on any
// single neuron, so it learns redundant, sturdier features.
//
// Scaling: dropping a fraction p of the values shrinks their average by
// (1 - p). So survivors are multiplied by 1 / (1 - p), keeping the
// EXPECTED value unchanged ("inverted dropout"):
//
//     train:  y = x * mask / (1 - p)      mask[i] = 1 with probability 1-p
//     eval:   y = x                       (no randomness at test time)
//
// Backward uses the same mask: dx = dy * mask / (1 - p).
//
// The mask needs random numbers inside a kernel: exactly what the
// counter-based generator of 064 is for. Element i keeps its value if
// uniform(seed, i) >= p.
//
// YOUR TASK: finish forward (both modes) and backward.
//
const std = @import("std");

fn hash(seed: u64, counter: u64) u64 {
    var z = seed +% (counter +% 1) *% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn uniform(seed: u64, i: u64) f64 {
    return @as(f64, @floatFromInt(hash(seed, i) >> 11)) / (1 << 53);
}

fn keep(seed: u64, i: usize, p: f64) bool {
    return ???;
}

fn dropout(x: []const f64, y: []f64, p: f64, seed: u64, training: bool) void {
    for (x, y, 0..) |v, *o, i| {
        if (!training) {
            ???
        } else {
            o.* = if (keep(seed, i, p)) ??? else 0;
        }
    }
}

fn dropoutBackward(dy: []const f64, dx: []f64, p: f64, seed: u64) void {
    for (dy, dx, 0..) |g, *o, i| o.* = if (keep(seed, i, p)) ??? else 0;
}

test "about a fraction p is dropped" {
    var x: [10_000]f64 = undefined;
    @memset(&x, 1);
    var y: [10_000]f64 = undefined;
    dropout(&x, &y, 0.3, 89, true);
    var dropped: f64 = 0;
    for (y) |v| {
        if (v == 0) dropped += 1;
    }
    try std.testing.expectApproxEqAbs(0.3, dropped / 10_000, 0.02);
}

test "the expected value is preserved" {
    const x = [_]f64{ 2, -1, 0.5 };
    var sum: [3]f64 = @splat(0);
    for (0..20_000) |step| {
        var y: [3]f64 = undefined;
        dropout(&x, &y, 0.5, step, true); // a fresh mask every step
        for (&sum, y) |*s, v| s.* += v / 20_000;
    }
    for (x, sum) |v, avg| try std.testing.expectApproxEqAbs(v, avg, 0.05);
}

test "eval mode does nothing" {
    const x = [_]f64{ 2, -1, 0.5 };
    var y: [3]f64 = undefined;
    dropout(&x, &y, 0.5, 1, false);
    try std.testing.expectEqualSlices(f64, &x, &y);
}

test "backward uses the same mask" {
    const x = [_]f64{ 1, 1, 1, 1, 1, 1, 1, 1 };
    var y: [8]f64 = undefined;
    var dx: [8]f64 = undefined;
    dropout(&x, &y, 0.5, 42, true);
    dropoutBackward(&x, &dx, 0.5, 42); // dy = 1 everywhere
    try std.testing.expectEqualSlices(f64, &y, &dx);
}
