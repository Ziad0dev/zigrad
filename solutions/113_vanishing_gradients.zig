// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 113: vanishing and exploding gradients ───────────────────
//
// Look at BPTT's `dh = dpre * w` again. Going back k steps multiplies the
// gradient by w * tanh'(...) k times:
//
//     d h_T / d h_0 = product over t of  w * (1 - h_t^2)
//
// Since tanh' <= 1: if |w| < 1, that product shrinks EXPONENTIALLY. After
// 50 steps with w = 0.5 it's below 10^-15: the network can't learn that
// something 50 steps ago mattered. If |w| > 1 (and tanh isn't squashing),
// it grows exponentially instead and training blows up.
//
// For matrices, the eigenvalues of W play the role of w (058). This is
// the *vanishing/exploding gradient problem*, and it shaped deep learning:
//   * LSTMs (114) add a memory path that isn't repeatedly multiplied
//   * residual connections (115) add an identity path through every layer
//   * gradient clipping (099) stops the explosions
//   * careful initialization (037) starts everything near "size 1"
//
// YOUR TASK: compute the gradient through a chain of steps.
//
const std = @import("std");

/// d h_T / d h_0 for a scalar tanh RNN with inputs `xs`, starting at h0.
fn gradThroughTime(w: f64, u: f64, xs: []const f64, h0: f64) f64 {
    var h = h0;
    var grad: f64 = 1;
    for (xs) |x| {
        h = std.math.tanh(w * h + u * x);
        grad *= w * (1 - h * h);
    }
    return grad;
}

/// The same for a LINEAR RNN (no tanh): just w^T.
fn linearGrad(w: f64, steps: usize) f64 {
    return std.math.pow(f64, w, @floatFromInt(steps));
}

test "vanishing" {
    const xs: [50]f64 = @splat(0.1);
    try std.testing.expect(@abs(gradThroughTime(0.5, 1, &xs, 0)) < 1e-15);
}

test "exploding" {
    try std.testing.expect(linearGrad(1.5, 50) > 1e8);
    try std.testing.expectApproxEqAbs(1.0, linearGrad(1.0, 50), 1e-12); // the knife edge
}

test "matches measured slopes" {
    const xs = [_]f64{ 0.3, -0.5, 0.2, 0.9 };
    const w = 0.8;
    const u = 1.1;
    const h: f64 = 1e-6;
    var up = h;
    var down = -h;
    for (xs) |x| {
        up = std.math.tanh(w * up + u * x);
        down = std.math.tanh(w * down + u * x);
    }
    try std.testing.expectApproxEqAbs((up - down) / (2 * h), gradThroughTime(w, u, &xs, 0), 1e-8);
}
