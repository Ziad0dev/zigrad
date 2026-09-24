//
// ─── Exercise 063: sampling, temperature, top-k ────────────────────────
//
// A language model outputs logits over its vocabulary at each step. How
// do we pick the next word?
//
//   * greedy: always the argmax. Repetitive and boring.
//   * sample: draw from softmax(logits), so likely words usually win, but
//     not always.
//
// *Temperature* T reshapes the distribution first: softmax(logits / T).
//     T < 1: sharper, closer to greedy (T -> 0 IS greedy)
//     T > 1: flatter, more random (T -> infinity is uniform)
//
// *Top-k*: keep only the k most likely tokens, renormalize, sample.
// Cuts off the long tail of nonsense.
//
// Drawing from a distribution with one uniform number u in [0, 1):
// walk through the classes adding up probabilities, and stop at the first
// class where the running total passes u. (This is "inverting the
// cumulative distribution".) With p = [0.2, 0.5, 0.3]:
//     u in [0, 0.2) -> 0,   [0.2, 0.7) -> 1,   [0.7, 1) -> 2
//
// YOUR TASK: write withTemperature(), sample() and topK().
//
const std = @import("std");

fn softmax(z: []const f64, out: []f64) void {
    var m: f64 = -std.math.inf(f64);
    for (z) |v| m = @max(m, v);
    var total: f64 = 0;
    for (z, out) |v, *o| {
        o.* = @exp(v - m);
        total += o.*;
    }
    for (out) |*o| o.* /= total;
}

fn withTemperature(logits: []const f64, t: f64, out: []f64) void {
    var scaled: [64]f64 = undefined;
    for (logits, scaled[0..logits.len]) |z, *s| s.* = ⟪z / t|||???⟫;
    softmax(scaled[0..logits.len], out);
}

/// The class chosen by the uniform number u in [0, 1).
fn sample(p: []const f64, u: f64) usize {
    var running: f64 = 0;
    for (p, 0..) |x, i| {
        running += x;
        if (⟪u < running|||???⟫) return i;
    }
    return p.len - 1; // rounding: u was just below 1
}

/// Zero out everything but the k largest, and renormalize.
fn topK(p: []f64, k: usize) void {
    var sorted: [64]f64 = undefined;
    @memcpy(sorted[0..p.len], p);
    std.mem.sort(f64, sorted[0..p.len], {}, std.sort.desc(f64));
    const cutoff = sorted[k - 1];
    var total: f64 = 0;
    for (p) |*x| {
        if (⟪x.* < cutoff|||???⟫) x.* = 0;
        total += x.*;
    }
    for (p) |*x| x.* ⟪/= total|||???⟫;
}

fn entropy(p: []const f64) f64 {
    var h: f64 = 0;
    for (p) |x| {
        if (x > 0) h -= x * @log(x);
    }
    return h;
}

const scores = [_]f64{ 2, 1, 0.5, -1 };

test "temperature" {
    var cold: [4]f64 = undefined;
    var warm: [4]f64 = undefined;
    var hot: [4]f64 = undefined;
    withTemperature(&scores, 0.1, &cold);
    withTemperature(&scores, 1, &warm);
    withTemperature(&scores, 10, &hot);
    try std.testing.expect(cold[0] > 0.99); // nearly greedy
    try std.testing.expect(entropy(&cold) < entropy(&warm));
    try std.testing.expect(entropy(&warm) < entropy(&hot));
    try std.testing.expect(entropy(&hot) > 0.95 * @log(4.0)); // nearly uniform
}

test "sampling follows the probabilities" {
    try std.testing.expectEqual(0, sample(&.{ 0.2, 0.5, 0.3 }, 0.1));
    try std.testing.expectEqual(1, sample(&.{ 0.2, 0.5, 0.3 }, 0.2));
    try std.testing.expectEqual(2, sample(&.{ 0.2, 0.5, 0.3 }, 0.95));

    var p: [4]f64 = undefined;
    withTemperature(&scores, 1, &p);
    var counts: [4]f64 = @splat(0);
    var prng = std.Random.DefaultPrng.init(63);
    for (0..20_000) |_| counts[sample(&p, prng.random().float(f64))] += 1;
    for (counts, p) |c, expected| try std.testing.expectApproxEqAbs(expected, c / 20_000, 0.015);
}

test "top-k" {
    var p = [_]f64{ 0.1, 0.4, 0.3, 0.2 };
    topK(&p, 2);
    try std.testing.expectApproxEqAbs(0.0, p[0], 1e-12);
    try std.testing.expectApproxEqAbs(4.0 / 7.0, p[1], 1e-12);
    try std.testing.expectApproxEqAbs(3.0 / 7.0, p[2], 1e-12);
    try std.testing.expectApproxEqAbs(0.0, p[3], 1e-12);
}
