// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 060: random numbers and the bell curve ───────────────────
//
// Chapter 12: probability. Neural nets start from random weights (037),
// train on random batches, drop random neurons (089), and sample random
// words (063). Time to understand randomness properly.
//
// A *distribution* says how likely each value is. Two you need:
//
//   * uniform on [0, 1): every value equally likely. Mean 1/2.
//   * normal ("Gaussian", the bell curve) with mean μ and standard
//     deviation σ. Most values land within σ of μ. Sums of many small
//     random effects end up normal (the central limit theorem), which is
//     why it's everywhere.
//
// Computers make uniform numbers. The *Box-Muller transform* turns two
// uniforms r1, r2 into a standard normal (μ = 0, σ = 1):
//
//     z = sqrt(-2 ln(r1)) * cos(2π r2)
//
// And any normal is a stretched and shifted standard one: x = μ + σ z.
//
// The *standard error*: the average of n samples wobbles around the true
// mean by about σ / sqrt(n). Four times the data halves the wobble. This
// is also why bigger batches give smoother gradients.
//
// YOUR TASK: write boxMuller(), normal() and standardError().
//
const std = @import("std");

fn boxMuller(r1: f64, r2: f64) f64 {
    return @sqrt(-2 * @log(r1)) * @cos(2 * std.math.pi * r2);
}

fn normal(rand: std.Random, mu: f64, sigma: f64) f64 {
    const r1 = 1 - rand.float(f64); // in (0, 1]: log(0) would be -inf
    const z = boxMuller(r1, rand.float(f64));
    return mu + sigma * z;
}

fn standardError(sigma: f64, n: usize) f64 {
    return sigma / @sqrt(@as(f64, @floatFromInt(n)));
}

fn meanVar(xs: []const f64) [2]f64 {
    const n: f64 = @floatFromInt(xs.len);
    var m: f64 = 0;
    for (xs) |x| m += x;
    m /= n;
    var v: f64 = 0;
    for (xs) |x| v += (x - m) * (x - m);
    return .{ m, v / n };
}

test "Box-Muller gives a standard normal" {
    var prng = std.Random.DefaultPrng.init(60);
    const xs = try std.testing.allocator.alloc(f64, 100_000);
    defer std.testing.allocator.free(xs);
    for (xs) |*x| x.* = normal(prng.random(), 0, 1);

    const mv = meanVar(xs);
    try std.testing.expectApproxEqAbs(0.0, mv[0], 0.02);
    try std.testing.expectApproxEqAbs(1.0, mv[1], 0.03);

    // about 68% within one σ
    var inside: usize = 0;
    for (xs) |x| {
        if (@abs(x) < 1) inside += 1;
    }
    try std.testing.expectApproxEqAbs(0.6827, @as(f64, @floatFromInt(inside)) / 100_000, 0.01);
}

test "stretch and shift" {
    var prng = std.Random.DefaultPrng.init(61);
    var xs: [50_000]f64 = undefined;
    for (&xs) |*x| x.* = normal(prng.random(), 10, 3);
    const mv = meanVar(&xs);
    try std.testing.expectApproxEqAbs(10.0, mv[0], 0.1);
    try std.testing.expectApproxEqAbs(9.0, mv[1], 0.3);
}

test "standard error" {
    try std.testing.expectApproxEqAbs(0.1, standardError(1, 100), 1e-12);
    try std.testing.expectApproxEqAbs(standardError(2, 100) / 2, standardError(2, 400), 1e-12);
}
