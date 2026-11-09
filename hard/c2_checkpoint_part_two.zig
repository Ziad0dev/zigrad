// HARD MODE (zig build -Dhard): no blanks to fill in. Every function
// marked ??? has lost its whole body: write it, from its doc comment,
// its signature and the tests. The gentler version of this file is in
// exercises/, and the answer in solutions/.
//
// ─── Checkpoint 2: Part II, from memory ───────────────────────────────
//
// Same game as checkpoint 1: no blanks, nothing new, five functions from
// five chapters of Part II, each one to write whole. Try each cold first.
// If you have to look one up, read YOUR finished exercise (its number is
// in the doc comment), close it, and write the function here from memory.
//
// YOUR TASK: write solve(), kl(), layerNorm(), causalAttention() and
// adamW().
//
const std = @import("std");

/// (057) Solve A x = b for x, by elimination. `a` is n by n, row-major;
/// both may be overwritten, and the answer is left in b. A is invertible,
/// but a[0] may well be 0: pick your pivots.
fn solve(a: []f64, b: []f64, n: usize) void {
    ???; // write this function's body
}

/// (062) The KL divergence from q to p, in nats: how many extra nats you
/// pay for coding samples of p with a code built for q. An outcome p
/// never produces costs nothing.
fn kl(p: []const f64, q: []const f64) f64 {
    ???; // write this function's body
}

const eps = 1e-5;

/// (083) LayerNorm of one row: x with mean 0 and variance 1 (eps goes
/// under the square root, with the variance), then scaled by gamma and
/// shifted by beta, element by element.
fn layerNorm(x: []const f64, gamma: []const f64, beta: []const f64, y: []f64) void {
    ???; // write this function's body
}

/// (090, 091) One head of causal self-attention. q, k and v hold `tokens`
/// rows of `d` numbers. Row i of `out` is the attention-weighted mix of
/// the rows of v that token i is allowed to see, with scores
/// q_i . k_j / sqrt(d). `scratch` has room for `tokens` numbers.
fn causalAttention(q: []const f64, k: []const f64, v: []const f64, tokens: usize, d: usize, out: []f64, scratch: []f64) void {
    ???; // write this function's body
}

const Adam = struct {
    lr: f64,
    wd: f64, //         weight decay, λ
    b1: f64 = 0.9,
    b2: f64 = 0.999,
    eps: f64 = 1e-8, // added to the square root, outside it
    m: f64 = 0,
    v: f64 = 0,
    t: f64 = 0, //      steps taken so far
};

/// (038, 098) One AdamW step on one weight: Adam with bias correction,
/// and the weight decay DECOUPLED: applied to the weight after the Adam
/// step, as w -= lr * wd * w, never mixed into the gradient.
fn adamW(o: *Adam, w: *f64, grad: f64) void {
    ???; // write this function's body
}

const t = std.testing;

test "solve" {
    // 2x + y = 5, x + 3y = 10
    var a = [_]f64{ 2, 1, 1, 3 };
    var b = [_]f64{ 5, 10 };
    solve(&a, &b, 2);
    try t.expectApproxEqAbs(1, b[0], 1e-12);
    try t.expectApproxEqAbs(3, b[1], 1e-12);
    // a zero in the corner: the first pivot has to come from another row
    var a3 = [_]f64{ 0, 2, 1, 1, 1, 1, 2, 1, -1 };
    var b3 = [_]f64{ 7, 6, 1 };
    solve(&a3, &b3, 3);
    for ([_]f64{ 1, 2, 3 }, b3) |want, got| try t.expectApproxEqAbs(want, got, 1e-12);
    // a tiny pivot that isn't zero: without picking the biggest, the answer drowns in rounding
    var a2 = [_]f64{ 1e-20, 1, 1, 1 };
    var b2 = [_]f64{ 1, 2 };
    solve(&a2, &b2, 2);
    try t.expectApproxEqAbs(1, b2[0], 1e-9);
    try t.expectApproxEqAbs(1, b2[1], 1e-9);
}

test "kl" {
    const p = [_]f64{ 0.5, 0.25, 0.25, 0 };
    const q = [_]f64{ 0.25, 0.25, 0.25, 0.25 };
    try t.expectEqual(0, kl(&p, &p));
    try t.expectApproxEqAbs(0.5 * @log(2.0), kl(&p, &q), 1e-12);
    // not symmetric
    const r = [_]f64{ 0.7, 0.1, 0.1, 0.1 };
    try t.expectApproxEqAbs(0.42981319, kl(&q, &r), 1e-7);
    try t.expectApproxEqAbs(0.44584637, kl(&r, &q), 1e-7);
}

test "layer norm" {
    const x = [_]f64{ 1, 2, 3, 4 };
    var y: [4]f64 = undefined;
    layerNorm(&x, &.{ 1, 1, 1, 1 }, &.{ 0, 0, 0, 0 }, &y);
    var mean: f64 = 0;
    var sq: f64 = 0;
    for (y) |v| {
        mean += v / 4;
        sq += v * v / 4;
    }
    try t.expectApproxEqAbs(0, mean, 1e-12);
    try t.expectApproxEqAbs(1, sq, 1e-5); // a hair under 1, because of eps
    try t.expectApproxEqAbs(-1.3416354, y[0], 1e-6); // -1.5 / sqrt(1.25 + 1e-5)
    // gamma and beta, per element
    layerNorm(&x, &.{ 2, 2, 0, 1 }, &.{ 0, 1, 5, -1 }, &y);
    try t.expectApproxEqAbs(-2.6832708, y[0], 1e-6);
    try t.expectApproxEqAbs(1 - 0.8944236, y[1], 1e-6);
    try t.expectEqual(5, y[2]);
    try t.expectApproxEqAbs(1.3416354 - 1, y[3], 1e-6);
    // a constant row: eps keeps it from dividing by zero
    layerNorm(&.{ 7, 7, 7, 7 }, &.{ 1, 1, 1, 1 }, &.{ 0, 0, 0, 0 }, &y);
    for (y) |v| try t.expectEqual(0, v);
}

test "causal attention" {
    const tokens = 4;
    const d = 2;
    var prng = std.Random.DefaultPrng.init(4);
    var q: [tokens * d]f64 = undefined;
    var k: [tokens * d]f64 = undefined;
    var v: [tokens * d]f64 = undefined;
    for (&q, &k, &v) |*a, *b, *c| {
        a.* = prng.random().floatNorm(f64);
        b.* = prng.random().floatNorm(f64);
        c.* = prng.random().floatNorm(f64);
    }
    var out: [tokens * d]f64 = undefined;
    var scratch: [tokens]f64 = undefined;
    causalAttention(&q, &k, &v, tokens, d, &out, &scratch);
    // token 0 sees only itself
    try t.expectApproxEqAbs(v[0], out[0], 1e-12);
    try t.expectApproxEqAbs(v[1], out[1], 1e-12);
    // token 1, by hand
    const s0 = (q[2] * k[0] + q[3] * k[1]) / @sqrt(2.0);
    const s1 = (q[2] * k[2] + q[3] * k[3]) / @sqrt(2.0);
    const w0 = @exp(s0) / (@exp(s0) + @exp(s1));
    try t.expectApproxEqAbs(w0 * v[0] + (1 - w0) * v[2], out[2], 1e-12);
    try t.expectApproxEqAbs(w0 * v[1] + (1 - w0) * v[3], out[3], 1e-12);
    // causal: changing the LAST token changes nobody else's output
    var out2: [tokens * d]f64 = undefined;
    k[6] += 3;
    v[7] -= 2;
    q[6] *= -1;
    causalAttention(&q, &k, &v, tokens, d, &out2, &scratch);
    for (out[0..6], out2[0..6]) |a, b| try t.expectEqual(a, b);
    try t.expect(out[7] != out2[7]);
    // identical keys: every visible token gets the same weight, so it's a running mean of v
    const same_k = [_]f64{ 1, -1 } ** tokens;
    causalAttention(&q, &same_k, &v, tokens, d, &out, &scratch);
    try t.expectApproxEqAbs((v[0] + v[2] + v[4]) / 3.0, out[4], 1e-12);
    // scores far beyond exp's range still work
    const huge_q = [_]f64{ 1000, 1000 } ** tokens;
    causalAttention(&huge_q, &same_k, &v, tokens, d, &out, &scratch);
    for (out) |o| try t.expect(!std.math.isNan(o));
    const big_k = [_]f64{ 1, 1, 2, 2, 3, 3, 4, 4 };
    causalAttention(&huge_q, &big_k, &v, tokens, d, &out, &scratch);
    try t.expectApproxEqAbs(v[6], out[6], 1e-9); // the last key wins outright
}

test "AdamW" {
    // step 1, by hand: bias correction makes the first step exactly lr (almost), whatever the gradient's size
    var o: Adam = .{ .lr = 0.1, .wd = 0 };
    var w: f64 = 1;
    adamW(&o, &w, 250);
    try t.expectApproxEqAbs(0.9, w, 1e-9);
    try t.expectEqual(1, o.t);
    try t.expectApproxEqAbs(25, o.m, 1e-12);
    try t.expectApproxEqAbs(62.5, o.v, 1e-9);
    // step 2, with a different gradient
    adamW(&o, &w, -50);
    try t.expectApproxEqAbs(0.84889739, w, 1e-7);
    // eps is ADDED to the root: a tiny gradient still gives a step of about lr / 2, not a blow-up
    var tiny: Adam = .{ .lr = 0.1, .wd = 0 };
    var w1: f64 = 1;
    adamW(&tiny, &w1, 1e-8);
    try t.expectApproxEqAbs(0.95, w1, 1e-6);
    // decoupled decay: with no gradient at all, the weight shrinks by exactly (1 - lr * wd) a step
    var d: Adam = .{ .lr = 0.1, .wd = 0.5 };
    var w2: f64 = 2;
    adamW(&d, &w2, 0);
    try t.expectApproxEqAbs(2 * 0.95, w2, 1e-12);
    adamW(&d, &w2, 0);
    try t.expectApproxEqAbs(2 * 0.95 * 0.95, w2, 1e-12);
    // and it decays the weight as it is AFTER the Adam step
    var e: Adam = .{ .lr = 0.1, .wd = 0.5 };
    var w3: f64 = 1;
    adamW(&e, &w3, 4);
    try t.expectApproxEqAbs(0.9 * 0.95, w3, 1e-8);
}
