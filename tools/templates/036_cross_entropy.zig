//
// ─── Exercise 036: cross-entropy loss ──────────────────────────────────
//
// How do you score a classifier? It outputs logits z, softmax (018) turns
// them into probabilities p, and the right answer is class t. The loss:
//
//     loss = -log(p[t])
//
//     p[t] = 1    (sure, and right)   ->  loss = 0
//     p[t] = 0.5                      ->  loss = 0.69
//     p[t] = 0.01 (sure, and wrong)   ->  loss = 4.6, and up to infinity
//
// Confident mistakes are punished hard. That's *cross-entropy*.
//
// Computing it safely, with logsumexp (exercise 018):
//     -log(p[t]) = -log(e^z[t] / sum of e^z) = logsumexp(z) - z[t]
//
// And the gradient with respect to the logits is beautiful:
//
//     dloss/dz[i] = p[i] - (1 if i == t, else 0)
//
// "What you predicted, minus what you should have predicted." It pushes
// the right class up and every other class down, each in proportion to
// its probability.
//
// Why? The derivative of logsumexp(z) with respect to z[i] is
// e^z[i] / sum of e^z, which is p[i] (chain rule: log(u)' = 1/u, and
// u = sum of e^z). The derivative of z[t] is 1 for i == t, else 0.
//
// YOUR TASK: write the loss and its gradient.
//
const std = @import("std");

fn logsumexp(z: []const f64) f64 {
    var m: f64 = -std.math.inf(f64);
    for (z) |v| m = @max(m, v);
    var total: f64 = 0;
    for (z) |v| total += @exp(v - m);
    return m + @log(total);
}

fn crossEntropy(z: []const f64, target: usize) f64 {
    return ⟪logsumexp(z) - z[target]|||???⟫;
}

fn crossEntropyGrad(z: []const f64, target: usize, grad: []f64) void {
    const lse = logsumexp(z);
    for (grad, z, 0..) |*g, zi, i| {
        const p = @exp(zi - lse); // softmax, via logsumexp
        const truth: f64 = if (i == target) 1 else 0;
        g.* = ⟪p - truth|||???⟫;
    }
}

test "the loss" {
    // p = softmax([2, 1, 0.1]) = [0.659, 0.242, 0.099]; -log(0.659) = 0.417
    try std.testing.expectApproxEqAbs(0.4170, crossEntropy(&.{ 2, 1, 0.1 }, 0), 1e-4);
    // sure and wrong
    try std.testing.expect(crossEntropy(&.{ 10, 0, 0 }, 1) > 10);
    // no overflow, even for huge logits
    try std.testing.expectApproxEqAbs(0.0, crossEntropy(&.{ 1000, 0 }, 0), 1e-9);
}

test "the gradient matches measured slopes" {
    var z = [_]f64{ 0.5, -1.2, 2.0, 0.1 };
    const target = 1;
    var grad: [4]f64 = undefined;
    crossEntropyGrad(&z, target, &grad);

    const h = 1e-6;
    var sum: f64 = 0;
    for (&z, 0..) |*zi, i| {
        const orig = zi.*;
        zi.* = orig + h;
        const up = crossEntropy(&z, target);
        zi.* = orig - h;
        const down = crossEntropy(&z, target);
        zi.* = orig;
        try std.testing.expectApproxEqAbs((up - down) / (2 * h), grad[i], 1e-6);
        sum += grad[i];
    }
    // probabilities sum to 1, minus the 1 of the truth: grads sum to 0
    try std.testing.expectApproxEqAbs(0.0, sum, 1e-12);
}
