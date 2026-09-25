//
// ─── Exercise 091: no peeking at the future ────────────────────────────
//
// A language model is trained to predict the NEXT token. If token 3 could
// attend to token 4, it would just copy the answer. So each token may
// only look at itself and the tokens BEFORE it: a *causal mask*.
//
// Implement it by setting the forbidden scores to -infinity before the
// softmax. e^(-inf) = 0, so they get zero weight:
//
//     scores:   | s00  -inf -inf |       weights:  | 1    0    0   |
//               | s10  s11  -inf |                 | w10  w11  0   |
//               | s20  s21  s22  |                 | w20  w21  w22 |
//
// The mask is a lower triangle. In tinygrad it's built with... a
// comparison of two broadcast aranges (like 088's one-hot), fed into a
// where(). No special op needed.
//
// A beautiful consequence: all positions of a sequence train in ONE
// forward pass (every row predicts its own next token), while each row
// still only sees the past.
//
// YOUR TASK: apply the mask.
//
const std = @import("std");

fn softmaxInPlace(row: []f64) void {
    var m: f64 = -std.math.inf(f64);
    for (row) |v| m = @max(m, v);
    var total: f64 = 0;
    for (row) |*v| {
        v.* = @exp(v.* - m);
        total += v.*;
    }
    for (row) |*v| v.* /= total;
}

fn dot(a: []const f64, b: []const f64) f64 {
    var acc: f64 = 0;
    for (a, b) |x, y| acc += x * y;
    return acc;
}

fn causalAttention(q: []const f64, k: []const f64, v: []const f64, t: usize, d: usize, dv: usize, out: []f64) void {
    var scores: [64]f64 = undefined;
    for (0..t) |i| {
        for (0..t) |j| {
            scores[j] = if (???)
                ???
            else
                dot(q[i * d ..][0..d], k[j * d ..][0..d]) / @sqrt(@as(f64, @floatFromInt(d)));
        }
        softmaxInPlace(scores[0..t]);
        for (0..dv) |c| {
            var acc: f64 = 0;
            for (0..t) |j| acc += scores[j] * v[j * dv + c];
            out[i * dv + c] = acc;
        }
    }
}

const queries = [_]f64{ 1, 0, 0.5, 0.5, -1, 2, 0.3, 0.3 };
const keys = [_]f64{ 0.2, 1, 1, 0, 0.5, -0.5, 2, 1 };

test "the first token only sees itself" {
    const v = [_]f64{ 7, 1, 2, 3 };
    var out: [4]f64 = undefined;
    causalAttention(&queries, &keys, &v, 4, 2, 1, &out);
    try std.testing.expectApproxEqAbs(7.0, out[0], 1e-12);
}

test "changing the future doesn't change the past" {
    var v = [_]f64{ 1, 2, 3, 4 };
    var before: [4]f64 = undefined;
    causalAttention(&queries, &keys, &v, 4, 2, 1, &before);
    v[3] = 1000; // rewrite the last token's value
    var after: [4]f64 = undefined;
    causalAttention(&queries, &keys, &v, 4, 2, 1, &after);
    try std.testing.expectEqualSlices(f64, before[0..3], after[0..3]);
    try std.testing.expect(after[3] != before[3]);
}
