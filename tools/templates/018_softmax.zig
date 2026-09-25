//
// ─── Exercise 018: softmax, and not exploding ──────────────────────────
//
// A classifier outputs one score per class, e.g. [cat, dog, bird] =
// [2.0, 1.0, 0.1]. These scores are called *logits*. softmax turns them
// into probabilities, all positive and adding up to 1:
//
//     softmax(x)[i] = e^x[i] / (e^x[0] + e^x[1] + ...)
//
//     [2.0, 1.0, 0.1]  ->  [0.66, 0.24, 0.10]
//
// The problem: e^1000 is infinity in f32 (exercise 002), and inf / inf is
// nan. Logits of 1000 are rare, but values big enough to overflow do show
// up in real training.
//
// The fix: subtract the biggest logit m from all of them first. It
// doesn't change the answer, since e^(x - m) = e^x * e^(-m), and the e^(-m)
// appears on the top AND the bottom, so it cancels. Now the biggest
// exponent is e^0 = 1 and nothing overflows.
//
// Same trick for logsumexp, which you'll need for the loss in exercise 036:
//     log(e^x[0] + e^x[1] + ...) = m + log(e^(x[0]-m) + e^(x[1]-m) + ...)
//
// In tinygrad, softmax is just these primitives: a MAX reduce, a sub, an
// exp, a SUM reduce and a div.
//
// YOUR TASK: softmax() works on small numbers, but its test with big ones
// fails. Fix it, then finish the normalize step and logsumexp().
//
const std = @import("std");

fn softmax(x: []const f32, out: []f32) void {
    // 1. the biggest logit
    var m: f32 = -std.math.inf(f32);
    for (x) |v| m = @max(m, v);

    // 2. exponentiate and add up
    var total: f32 = 0;
    for (x, out) |v, *o| {
        o.* = ⟪@exp(v - m)|||@exp(v)⟫;
        total += o.*;
    }

    // 3. divide by the total, so everything adds up to 1
    for (out) |*o| {
        o.* ⟪/= total|||???⟫;
    }
}

fn logsumexp(x: []const f32) f32 {
    var m: f32 = -std.math.inf(f32);
    for (x) |v| m = @max(m, v);
    var total: f32 = 0;
    for (x) |v| total += @exp(v - m);
    return ⟪m + @log(total)|||???⟫;
}

const tol = 1e-4;

test "softmax of small numbers" {
    var p: [3]f32 = undefined;
    softmax(&.{ 1, 2, 3 }, &p);
    try std.testing.expectApproxEqAbs(0.0900, p[0], tol);
    try std.testing.expectApproxEqAbs(0.2447, p[1], tol);
    try std.testing.expectApproxEqAbs(0.6652, p[2], tol);
    try std.testing.expectApproxEqAbs(1.0, p[0] + p[1] + p[2], tol);
}

test "softmax of big numbers" {
    var p: [3]f32 = undefined;
    softmax(&.{ 1000, 1001, 1002 }, &p); // same gaps as 1, 2, 3
    try std.testing.expectApproxEqAbs(0.0900, p[0], tol);
    try std.testing.expectApproxEqAbs(0.2447, p[1], tol);
    try std.testing.expectApproxEqAbs(0.6652, p[2], tol);
}

test "logsumexp" {
    try std.testing.expectApproxEqAbs(3.4076, logsumexp(&.{ 1, 2, 3 }), tol);
    // log(e^1000 + e^1000) = log(2 * e^1000) = 1000 + ln 2
    try std.testing.expectApproxEqAbs(1000.6931, logsumexp(&.{ 1000, 1000 }), 1e-3);
}
