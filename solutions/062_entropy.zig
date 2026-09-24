// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 062: entropy, cross-entropy, KL ──────────────────────────
//
// *Entropy* measures uncertainty, in "nats" when using natural log:
//
//     H(p) = -sum of p[i] * log p[i]          (with 0 * log 0 = 0)
//
//   a sure thing, [1, 0, 0]: H = 0          nothing to learn
//   a fair coin, [0.5, 0.5]: H = log 2      the most uncertain 2 outcomes can be
//   uniform over n:          H = log n      the maximum for n outcomes
//
// *Cross-entropy* H(p, q) = -sum of p[i] * log q[i] is the average
// surprise if reality follows p but you BELIEVE q. With p = the one-hot
// truth, it's -log q[target]: the loss from exercise 036. That's where
// the name comes from.
//
// *KL divergence* is the extra surprise from believing q instead of p:
//
//     KL(p || q) = sum of p[i] * log(p[i] / q[i])
//     H(p, q) = H(p) + KL(p || q)
//
// KL is never negative, and is 0 only when q = p. It's NOT symmetric:
// KL(p || q) != KL(q || p), so it's not a true distance. It shows up in
// knowledge distillation, VAEs, and RL fine-tuning of language models.
//
// Since H(p) doesn't depend on the model, minimizing cross-entropy is the
// same as minimizing KL from the truth.
//
// YOUR TASK: write entropy(), crossEntropy() and kl().
//
const std = @import("std");

fn entropy(p: []const f64) f64 {
    var h: f64 = 0;
    for (p) |x| {
        if (x > 0) h -= x * @log(x);
    }
    return h;
}

fn crossEntropy(p: []const f64, q: []const f64) f64 {
    var h: f64 = 0;
    for (p, q) |x, y| {
        if (x > 0) h -= x * @log(y);
    }
    return h;
}

fn kl(p: []const f64, q: []const f64) f64 {
    var d: f64 = 0;
    for (p, q) |x, y| {
        if (x > 0) d += x * @log(x / y);
    }
    return d;
}

const tol = 1e-12;

test "entropy" {
    try std.testing.expectApproxEqAbs(0.0, entropy(&.{ 1, 0, 0 }), tol);
    try std.testing.expectApproxEqAbs(@log(2.0), entropy(&.{ 0.5, 0.5 }), tol);
    try std.testing.expectApproxEqAbs(@log(4.0), entropy(&.{ 0.25, 0.25, 0.25, 0.25 }), tol);
    try std.testing.expect(entropy(&.{ 0.7, 0.2, 0.1 }) < @log(3.0));
}

test "cross-entropy with a one-hot truth is the classification loss" {
    try std.testing.expectApproxEqAbs(-@log(0.6), crossEntropy(&.{ 0, 1, 0 }, &.{ 0.3, 0.6, 0.1 }), tol);
}

test "KL" {
    const p = [_]f64{ 0.7, 0.2, 0.1 };
    const q = [_]f64{ 0.1, 0.3, 0.6 };
    try std.testing.expectApproxEqAbs(0.0, kl(&p, &p), tol);
    try std.testing.expect(kl(&p, &q) > 0);
    try std.testing.expect(@abs(kl(&p, &q) - kl(&q, &p)) > 0.01); // not symmetric
    try std.testing.expectApproxEqAbs(crossEntropy(&p, &q), entropy(&p) + kl(&p, &q), tol);
}
