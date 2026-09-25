//
// ─── Exercise 094: the KV cache ────────────────────────────────────────
//
// Generating text is one token at a time: run the model, sample a token
// (063), append it, run again. With causal attention (091), when token t
// arrives:
//
//   * its query attends to the keys and values of tokens 0..t
//   * the keys and values of tokens 0..t-1 are EXACTLY what they were in
//     the previous step (the mask means they never see token t)
//
// So keep them! A *KV cache* stores every past token's k and v. Each new
// token computes only its own q, k, v, appends k and v to the cache, and
// attends over the cache.
//
// Without a cache, step t recomputes the projections for all t + 1
// tokens: 1 + 2 + ... + T = T(T+1)/2 in total. With one: T. Every LLM
// inference engine, tinygrad's included, does this. The price is memory:
// the cache grows with the sequence, which is why long contexts are
// expensive.
//
// YOUR TASK: append to the cache, attend over it, and count the
// uncached work.
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

/// Plain causal attention (exercise 091), to check against.
/// q, k: [t, d]; v: [t, dv]; out: [t, dv].
fn causalAttention(q: []const f64, k: []const f64, v: []const f64, t: usize, d: usize, dv: usize, out: []f64) void {
    var scores: [64]f64 = undefined;
    for (0..t) |i| {
        for (0..t) |j| {
            scores[j] = if (j > i) -std.math.inf(f64) else dot(q[i * d ..][0..d], k[j * d ..][0..d]) / @sqrt(@as(f64, @floatFromInt(d)));
        }
        softmaxInPlace(scores[0..t]);
        for (0..dv) |c| {
            var acc: f64 = 0;
            for (0..t) |j| acc += scores[j] * v[j * dv + c];
            out[i * dv + c] = acc;
        }
    }
}

const dim = 2; // model width

var projections: usize = 0;

/// The token's q, k and v, through fixed "learned" matrices.
fn project(x: [dim]f64, q: *[dim]f64, k: *[dim]f64, v: *[dim]f64) void {
    projections += 1;
    q.* = .{ x[0] + 0.5 * x[1], -x[0] + x[1] };
    k.* = .{ 0.3 * x[0], x[0] - 0.7 * x[1] };
    v.* = .{ 2 * x[1], x[0] + x[1] };
}

const Cache = struct {
    keys: [64]f64 = undefined,
    values: [64]f64 = undefined,
    len: usize = 0,

    fn append(c: *Cache, k: [dim]f64, v: [dim]f64) void {
        @memcpy(c.keys[c.len * dim ..][0..dim], &k);
        @memcpy(c.values[c.len * dim ..][0..dim], ???);
        ???;
    }
};

/// Process one new token; returns its attention output.
fn step(cache: *Cache, x: [dim]f64) [dim]f64 {
    var q: [dim]f64 = undefined;
    var k: [dim]f64 = undefined;
    var v: [dim]f64 = undefined;
    project(x, &q, &k, &v);
    cache.append(k, v);

    var scores: [64]f64 = undefined;
    for (0..cache.len) |j| scores[j] = ???;
    softmaxInPlace(scores[0..cache.len]);
    var out: [dim]f64 = @splat(0);
    for (0..cache.len) |j| {
        for (0..dim) |c| out[c] += scores[j] * cache.values[j * dim + c];
    }
    return out;
}

fn projectionsWithoutCache(tokens: usize) usize {
    return ???;
}

test "the cache gives the same answers as full causal attention" {
    const xs = [_][dim]f64{ .{ 1, 0 }, .{ 0.5, -1 }, .{ 2, 1 }, .{ -0.3, 0.8 }, .{ 1, 1 } };
    const t = xs.len;

    // all at once, the way training does it
    var q: [t * dim]f64 = undefined;
    var k: [t * dim]f64 = undefined;
    var v: [t * dim]f64 = undefined;
    for (xs, 0..) |x, i| project(x, q[i * dim ..][0..dim], k[i * dim ..][0..dim], v[i * dim ..][0..dim]);
    var full: [t * dim]f64 = undefined;
    causalAttention(&q, &k, &v, t, dim, dim, &full);

    // one token at a time, the way generation does it
    projections = 0;
    var cache: Cache = .{};
    for (xs, 0..) |x, i| {
        const out = step(&cache, x);
        try std.testing.expectApproxEqAbs(full[i * dim], out[0], 1e-12);
        try std.testing.expectApproxEqAbs(full[i * dim + 1], out[1], 1e-12);
    }
    try std.testing.expectEqual(t, projections);
    try std.testing.expectEqual(15, projectionsWithoutCache(t));
}
