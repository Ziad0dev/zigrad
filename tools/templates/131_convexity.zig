//
// ─── Exercise 131: convex and not ──────────────────────────────────────
//
// Chapter 25: optimization theory. When is gradient descent guaranteed to
// find THE best answer? When the loss is *convex*: bowl-shaped, with no
// separate valleys. Formally, the straight line between any two points on
// the graph lies on or above it:
//
//     f((a + b) / 2) <= (f(a) + f(b)) / 2        (the midpoint test)
//
// For smooth 1D functions it's equivalent to f'' >= 0 everywhere.
//
// Convex: x², |x|, e^x, and the squared error of a LINEAR model as a
// function of its weights. So linear regression (032) always reaches the
// global best.
//
// Not convex: almost every neural network loss. Even y = w1 * w2 * x has
// two separate best answers (w1, w2) and (-w1, -w2), and the path between
// them goes UP. That's why deep learning results depend on initialization
// (037) and randomness, and why it's remarkable they work so well anyway.
//
// YOUR TASK: write the midpoint test, and check f'' numerically.
//
const std = @import("std");

const F = *const fn (f64) f64;

/// Checks the midpoint inequality on a grid of pairs in [lo, hi].
fn looksConvex(f: F, lo: f64, hi: f64) bool {
    const n = 40;
    for (0..n + 1) |i| {
        for (0..n + 1) |j| {
            const a = lo + (hi - lo) * @as(f64, @floatFromInt(i)) / n;
            const b = lo + (hi - lo) * @as(f64, @floatFromInt(j)) / n;
            if (⟪f((a + b) / 2) > (f(a) + f(b)) / 2 + 1e-12|||???⟫) return false;
        }
    }
    return true;
}

fn secondDerivative(f: F, x: f64) f64 {
    const h = 1e-4;
    return ⟪(f(x + h) - 2 * f(x) + f(x - h)) / (h * h)|||???⟫;
}

fn square(x: f64) f64 {
    return x * x;
}
fn absolute(x: f64) f64 {
    return @abs(x);
}
fn expo(x: f64) f64 {
    return @exp(x);
}
fn sine(x: f64) f64 {
    return @sin(x);
}
/// Squared error of the model y = w * 2 against target 3: linear in w.
fn linearLoss(w: f64) f64 {
    return (2 * w - 3) * (2 * w - 3);
}
/// y = w1 * w2 with target 1, along the path w1 = w2 = t: loss (t^2 - 1)^2.
fn twoLayerLoss(t: f64) f64 {
    return (t * t - 1) * (t * t - 1);
}

test "convex" {
    try std.testing.expect(looksConvex(&square, -3, 3));
    try std.testing.expect(looksConvex(&absolute, -3, 3));
    try std.testing.expect(looksConvex(&expo, -3, 3));
    try std.testing.expect(looksConvex(&linearLoss, -5, 5));
}

test "not convex" {
    try std.testing.expect(!looksConvex(&sine, -3, 3));
    try std.testing.expect(!looksConvex(&twoLayerLoss, -2, 2)); // two valleys, at t = ±1
    try std.testing.expect(secondDerivative(&twoLayerLoss, 0) < 0); // a hill between them
}

test "second derivatives" {
    try std.testing.expectApproxEqAbs(2.0, secondDerivative(&square, 1.7), 1e-4);
    try std.testing.expectApproxEqAbs(@exp(1.0), secondDerivative(&expo, 1), 1e-4);
}
