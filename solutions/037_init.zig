// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 037: initializing weights ────────────────────────────────
//
// Chapter 7: training real networks. First question: what numbers should
// the weights start with? Random, but how big?
//
// One neuron computes y = x1*w1 + x2*w2 + ... + xn*wn. If the x's and
// w's are independent random numbers with average 0, their *variances*
// (average squared size) multiply and add up:
//
//     Var(y) = n * Var(x) * Var(w)
//
// With n = 256 inputs and Var(w) = 1, each layer makes the numbers 256
// times bigger (in variance). Ten layers: 256^10. Everything overflows.
// Make the weights too small and everything shrinks to 0 instead. Either
// way, nothing trains.
//
// The fix: pick Var(w) = 1/n. Then Var(y) = Var(x), so the numbers stay
// the same size, layer after layer.
//
// Drawing weights evenly ("uniformly") from [-a, a] gives variance a^2/3:
//
//     a^2 / 3 = 1 / n     ->     a = sqrt(3 / n)
//
// Real libraries use variants of this. ReLU zeroes half its inputs, so
// "Kaiming" init doubles the variance to 2/n. tinygrad's nn.Linear, like
// PyTorch's, draws from [-1/sqrt(n), 1/sqrt(n)].
//
// YOUR TASK: finish variance() and bound().
//
const std = @import("std");

/// The average squared distance from the mean.
fn variance(xs: []const f64) f64 {
    const n: f64 = @floatFromInt(xs.len);
    var mean: f64 = 0;
    for (xs) |x| mean += x;
    mean /= n;
    var v: f64 = 0;
    for (xs) |x| v += (x - mean) * (x - mean);
    return v / n;
}

/// The a in [-a, a] that gives weights a variance of 1 / fan_in.
fn bound(fan_in: usize) f64 {
    return @sqrt(3.0 / @as(f64, @floatFromInt(fan_in)));
}

/// Push random inputs (variance 1) through `layers` layers of n x n random
/// weights drawn from [-a, a]. Returns the variance of the final output.
fn deepVariance(alloc: std.mem.Allocator, n: usize, layers: usize, a: f64) !f64 {
    var prng = std.Random.DefaultPrng.init(1234);
    const rand = prng.random();

    var x = try alloc.alloc(f64, n);
    defer alloc.free(x);
    var y = try alloc.alloc(f64, n);
    defer alloc.free(y);
    const w = try alloc.alloc(f64, n * n);
    defer alloc.free(w);

    for (x) |*v| v.* = rand.floatNorm(f64); // average 0, variance 1
    for (0..layers) |_| {
        for (w) |*v| v.* = (rand.float(f64) * 2 - 1) * a;
        for (0..n) |i| {
            var acc: f64 = 0;
            for (0..n) |j| acc += w[i * n + j] * x[j];
            y[i] = acc;
        }
        std.mem.swap([]f64, &x, &y);
    }
    return variance(x);
}

test "variance" {
    try std.testing.expectApproxEqAbs(1.0, variance(&.{ 1, -1, 1, -1 }), 1e-12);
    try std.testing.expectApproxEqAbs(1.25, variance(&.{ 1, 2, 3, 4 }), 1e-12);
    try std.testing.expectApproxEqAbs(0.0, variance(&.{ 5, 5, 5 }), 1e-12);
}

test "the bound" {
    try std.testing.expectApproxEqAbs(0.1082532, bound(256), 1e-6);
    // uniform on [-a, a] has variance a^2 / 3, which should be 1 / n
    const a = bound(100);
    try std.testing.expectApproxEqAbs(1.0 / 100.0, a * a / 3, 1e-12);
}

test "good init keeps the numbers the same size" {
    const v = try deepVariance(std.testing.allocator, 256, 10, bound(256));
    try std.testing.expect(v > 0.25 and v < 4);
}

test "bad init explodes or vanishes" {
    const huge = try deepVariance(std.testing.allocator, 256, 10, 1.0);
    try std.testing.expect(huge > 1e10);
    const tiny = try deepVariance(std.testing.allocator, 256, 10, 0.01);
    try std.testing.expect(tiny < 1e-10);
}
