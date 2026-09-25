//
// ─── Exercise 129: policy gradients ────────────────────────────────────
//
// Instead of learning values, learn the POLICY directly: a network that
// outputs probabilities over actions, π(a) = softmax(θ)[a]. Make actions
// that led to high reward more likely. The *REINFORCE* rule:
//
//     θ += lr * (reward - baseline) * ∇ log π(a)
//
// For a softmax, ∇ log π(a) = onehot(a) - π, the same shape as the
// cross-entropy gradient (036) with the sign flipped. In words: do
// "supervised learning" on the action you took, scaled by how good it
// turned out to be.
//
// The *baseline* (here, a running average of rewards) doesn't change the
// expected gradient, but it hugely reduces its noise: only better-than-
// usual outcomes get reinforced, and worse ones get discouraged.
//
// Policy gradients (PPO, GRPO...) are how LLMs are fine-tuned with
// rewards: the "actions" are tokens.
//
// YOUR TASK: write ∇ log π and the update.
//
const std = @import("std");

const arms = 4;
const true_means = [arms]f64{ 0.2, 0.9, 0.5, 0.4 };

fn softmax(theta: [arms]f64) [arms]f64 {
    var m: f64 = -std.math.inf(f64);
    for (theta) |t| m = @max(m, t);
    var p: [arms]f64 = undefined;
    var total: f64 = 0;
    for (&p, theta) |*x, t| {
        x.* = @exp(t - m);
        total += x.*;
    }
    for (&p) |*x| x.* /= total;
    return p;
}

fn gradLogPi(p: [arms]f64, a: usize) [arms]f64 {
    var g: [arms]f64 = undefined;
    for (&g, p, 0..) |*x, pi, i| x.* = ???;
    return g;
}

test "REINFORCE learns to prefer the best arm" {
    var prng = std.Random.DefaultPrng.init(129);
    const rand = prng.random();
    var theta: [arms]f64 = @splat(0);
    var baseline: f64 = 0;
    const lr = 0.1;
    for (0..3000) |_| {
        const p = softmax(theta);
        // sample an action (063)
        const u = rand.float(f64);
        var a: usize = arms - 1;
        var running: f64 = 0;
        for (p, 0..) |x, i| {
            running += x;
            if (u < running) {
                a = i;
                break;
            }
        }
        const r: f64 = if (rand.float(f64) < true_means[a]) 1 else 0;
        const g = gradLogPi(p, a);
        for (&theta, g) |*t, gi| ???;
        baseline += 0.01 * (r - baseline);
    }
    try std.testing.expect(softmax(theta)[1] > 0.9);
}

test "the gradient of log π matches the slope" {
    const theta = [arms]f64{ 0.3, -0.5, 1.2, 0 };
    const g = gradLogPi(softmax(theta), 2);
    const h = 1e-6;
    for (0..arms) |i| {
        var up = theta;
        var down = theta;
        up[i] += h;
        down[i] -= h;
        const measured = (@log(softmax(up)[2]) - @log(softmax(down)[2])) / (2 * h);
        try std.testing.expectApproxEqAbs(measured, g[i], 1e-8);
    }
}
