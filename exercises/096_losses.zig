//
// ─── Exercise 096: a field guide to losses ─────────────────────────────
//
// Chapter 18: the practical side of training. First, picking a loss.
//
//   MSE    mean of (pred - y)^2. Gaussian noise (061). Big errors count
//          a LOT (squared), so outliers dominate.
//   MAE    mean of |pred - y|. Every error counts in proportion, and the
//          gradient is just ±1: robust to outliers, but it never slows
//          down near the answer.
//   Huber  the best of both: squared for small errors, linear for big
//          ones (beyond δ). Its slope never exceeds δ:
//              |e| <= δ:  0.5 e^2
//              |e| >  δ:  δ (|e| - 0.5 δ)
//
//   BCE with logits: binary classification (061), fed the raw score z
//          instead of the probability σ(z). Computing log(σ(z)) directly
//          breaks for big |z| (log(0) = -inf). The stable form:
//              loss = max(z, 0) - z y + log(1 + e^(-|z|))
//          and its gradient is simply σ(z) - y, the binary twin of 036.
//
// YOUR TASK: write huber(), bceWithLogits() and its gradient.
//
const std = @import("std");

fn huber(e: f64, delta: f64) f64 {
    if (@abs(e) <= delta) return ???;
    return ???;
}

fn bceWithLogits(z: f64, y: f64) f64 {
    return ???;
}

fn bceWithLogitsGrad(z: f64, y: f64) f64 {
    const sigmoid = 1 / (1 + @exp(-z));
    return ???;
}

test "Huber: squared inside, linear outside" {
    try std.testing.expectApproxEqAbs(0.125, huber(0.5, 1), 1e-12);
    try std.testing.expectApproxEqAbs(2.5, huber(3, 1), 1e-12);
    try std.testing.expectApproxEqAbs(2.5, huber(-3, 1), 1e-12);
    // continuous at the joint
    try std.testing.expectApproxEqAbs(huber(1 - 1e-9, 1), huber(1 + 1e-9, 1), 1e-8);
}

test "BCE with logits matches the naive formula where that works" {
    for ([_]f64{ -3, -0.5, 0, 0.7, 4 }) |z| {
        const p = 1 / (1 + @exp(-z));
        for ([_]f64{ 0, 1 }) |y| {
            const naive = -(y * @log(p) + (1 - y) * @log(1 - p));
            try std.testing.expectApproxEqAbs(naive, bceWithLogits(z, y), 1e-12);
        }
    }
}

test "and stays finite where the naive one doesn't" {
    try std.testing.expectApproxEqAbs(1000.0, bceWithLogits(1000, 0), 1e-9);
    try std.testing.expectApproxEqAbs(0.0, bceWithLogits(1000, 1), 1e-9);
    try std.testing.expectApproxEqAbs(1000.0, bceWithLogits(-1000, 1), 1e-9);
}

test "the gradient is sigmoid(z) - y" {
    const h = 1e-6;
    for ([_]f64{ -3, 0.2, 5 }) |z| {
        for ([_]f64{ 0, 1 }) |y| {
            const measured = (bceWithLogits(z + h, y) - bceWithLogits(z - h, y)) / (2 * h);
            try std.testing.expectApproxEqAbs(measured, bceWithLogitsGrad(z, y), 1e-6);
        }
    }
}
