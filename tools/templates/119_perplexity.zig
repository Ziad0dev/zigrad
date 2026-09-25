//
// ─── Exercise 119: perplexity and bits ─────────────────────────────────
//
// Language models are compared by *perplexity*:
//
//     perplexity = e^(average negative log-likelihood)
//
// Intuition: a perplexity of k means the model is as unsure as if it were
// picking uniformly among k tokens at every step.
//
//     uniform guessing over V tokens:  perplexity V
//     always certain and right:        perplexity 1
//
// The same number measured in bits (log base 2) is *bits per character*
// (or per token). By Shannon's source coding theorem, a model with 1.5
// bits per character could compress text to 1.5 bits per character:
// language modeling and compression are the same problem.
//
// YOUR TASK: write perplexity() and bitsPer().
//
const std = @import("std");

/// `p` holds the probability the model gave to each actual next token.
fn avgNll(p: []const f64) f64 {
    var total: f64 = 0;
    for (p) |x| total -= @log(x);
    return total / @as(f64, @floatFromInt(p.len));
}

fn perplexity(p: []const f64) f64 {
    return ⟪@exp(avgNll(p))|||???⟫;
}

fn bitsPer(p: []const f64) f64 {
    return ⟪avgNll(p) / std.math.ln2|||???⟫;
}

test "uniform guessing over V has perplexity V" {
    const p: [10]f64 = @splat(1.0 / 27.0);
    try std.testing.expectApproxEqAbs(27.0, perplexity(&p), 1e-9);
    try std.testing.expectApproxEqAbs(@log2(27.0), bitsPer(&p), 1e-9);
}

test "perfect prediction" {
    try std.testing.expectApproxEqAbs(1.0, perplexity(&.{ 1, 1, 1 }), 1e-12);
    try std.testing.expectApproxEqAbs(0.0, bitsPer(&.{ 1, 1, 1 }), 1e-12);
}

test "a fair coin is one bit" {
    try std.testing.expectApproxEqAbs(1.0, bitsPer(&.{ 0.5, 0.5, 0.5, 0.5 }), 1e-12);
    try std.testing.expectApproxEqAbs(2.0, perplexity(&.{ 0.5, 0.5 }), 1e-12);
}
