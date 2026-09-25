//
// ─── Exercise 115: residual connections ────────────────────────────────
//
// The same trick that fixed RNNs lets feed-forward networks go hundreds of
// layers deep. Instead of y = f(x), each layer computes
//
//     y = x + f(x)            a *residual* (or "skip") connection
//
// The layer only learns a correction to its input. And the gradient:
//
//     dy/dx = 1 + f'(x)
//
// The 1 is a highway: even if f' is tiny, the gradient passes straight
// through. Through L plain layers the gradient is a product of L small
// numbers (it vanishes, 113). Through L residual layers it's a product of
// (1 + small) numbers, and stays healthy.
//
// ResNets (2015) made 100+ layer CNNs trainable this way, and every
// transformer block is two residual connections. In the "pre-norm" form
// most modern models use: x + attention(norm(x)), then x + mlp(norm(x)).
//
// YOUR TASK: compute the gradient through a deep stack, both ways.
//
const std = @import("std");

/// One tiny layer: f(x) = 0.1 * tanh(x), with f'(x) = 0.1 * (1 - tanh^2).
fn f(x: f64) f64 {
    return 0.1 * std.math.tanh(x);
}
fn df(x: f64) f64 {
    const t = std.math.tanh(x);
    return 0.1 * (1 - t * t);
}

/// d(output)/d(input) through `layers` plain layers: y = f(x).
fn plainGrad(x0: f64, layers: usize) f64 {
    var x = x0;
    var g: f64 = 1;
    for (0..layers) |_| {
        g *= ???;
        x = f(x);
    }
    return g;
}

/// The same through residual layers: y = x + f(x).
fn residualGrad(x0: f64, layers: usize) f64 {
    var x = x0;
    var g: f64 = 1;
    for (0..layers) |_| {
        g *= ???;
        x = ???;
    }
    return g;
}

test "deep plain stacks lose the gradient" {
    try std.testing.expect(plainGrad(0.5, 50) < 1e-40);
}

test "deep residual stacks keep it" {
    const g = residualGrad(0.5, 50);
    try std.testing.expect(g >= 1 and g < 1e3);
}

test "residual gradient matches the measured slope" {
    const h = 1e-6;
    var up: f64 = 0.5 + h;
    var down: f64 = 0.5 - h;
    for (0..20) |_| {
        up += f(up);
        down += f(down);
    }
    try std.testing.expectApproxEqAbs((up - down) / (2 * h), residualGrad(0.5, 20), 1e-6);
}
