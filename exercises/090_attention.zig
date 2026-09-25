//
// ─── Exercise 090: attention ───────────────────────────────────────────
//
// Chapter 17: the transformer, the architecture behind every large
// language model. Its core is *attention*: each token looks at the other
// tokens and pulls in information from the relevant ones.
//
// Every token t has three vectors (made by linear layers, 082):
//     query q[t]   "what am I looking for?"
//     key   k[s]   "what do I contain?"
//     value v[s]   "what do I pass along?"
//
//     score[t][s]  = dot(q[t], k[s]) / sqrt(d)     how well s matches t (054)
//     weight[t][:] = softmax(score[t][:])          (018)
//     out[t]       = sum over s of weight[t][s] * v[s]
//
// In matrices: out = softmax(Q Kᵀ / sqrt(d)) V. Two matmuls and a softmax.
//
// Why divide by sqrt(d)? If q and k have d random entries of variance 1,
// their dot product has variance d (d terms, each variance 1, 037).
// Big scores make softmax nearly one-hot, and its gradient nearly zero
// (066's softmax VJP: p(1 - p) ≈ 0). Dividing by sqrt(d) brings the
// variance back to 1.
//
// YOUR TASK: compute the scores, and the weighted sum of values.
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

/// q, k: [t, d]; v: [t, dv]; out: [t, dv].
fn attention(q: []const f64, k: []const f64, v: []const f64, t: usize, d: usize, dv: usize, out: []f64) void {
    const scale = 1 / @sqrt(@as(f64, @floatFromInt(d)));
    var weights: [64]f64 = undefined;
    for (0..t) |i| {
        for (0..t) |j| weights[j] = ???;
        softmaxInPlace(weights[0..t]);
        for (0..dv) |c| {
            var acc: f64 = 0;
            for (0..t) |j| acc += ???;
            out[i * dv + c] = acc;
        }
    }
}

test "a query picks out the value whose key matches" {
    // keys point in 3 different directions; values are labels
    const k = [_]f64{ 10, 0, 0, 0, 10, 0, 0, 0, 10 };
    const v = [_]f64{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    const q = [_]f64{ 0, 10, 0, 10, 0, 0, 0, 0, 10 }; // token 0 looks for key 1, ...
    var out: [9]f64 = undefined;
    attention(&q, &k, &v, 3, 3, 3, &out);
    try std.testing.expect(out[1] > 0.99); // token 0 got value 1
    try std.testing.expect(out[3] > 0.99); // token 1 got value 0
    try std.testing.expect(out[8] > 0.99); // token 2 got value 2
}

test "equal scores average the values" {
    const q = [_]f64{ 0, 0 };
    const k = [_]f64{ 1, 2, 3, 4 };
    const v = [_]f64{ 2, 6 };
    var out: [2]f64 = undefined;
    attention(&q, &k, &v, 2, 1, 1, &out);
    try std.testing.expectApproxEqAbs(4.0, out[0], 1e-12);
}

test "why sqrt(d): dot products of random vectors have variance d" {
    var prng = std.Random.DefaultPrng.init(90);
    const d = 256;
    var raw: f64 = 0;
    for (0..2000) |_| {
        var q: [d]f64 = undefined;
        var k: [d]f64 = undefined;
        for (&q, &k) |*a, *b| {
            a.* = prng.random().floatNorm(f64);
            b.* = prng.random().floatNorm(f64);
        }
        const s = dot(&q, &k);
        raw += s * s / 2000;
    }
    try std.testing.expectApproxEqRel(@as(f64, d), raw, 0.1);
    try std.testing.expectApproxEqRel(1.0, raw / d, 0.1); // after dividing by sqrt(d), squared
}
