//
// ─── Exercise 180: a modern transformer block ─────────────────────────
//
// The Part IV capstone: one block of a LLaMA-style model, built from the
// pieces of the last chapters, in the pre-norm form (115):
//
//     h   = x + attention(rmsnorm(x))           RMSNorm 171, attention 090
//     out = h + swiglu(rmsnorm(h))              SwiGLU 172
//
// with, inside the attention:
//   * q, k, v projections for every head (092)
//   * RoPE on q and k, by the token's position (093)
//   * causal masking (091)
//   * a KV cache when generating (094)
//
// Stack 32 of these (with different weights), add an embedding (088) at
// the bottom and a final RMSNorm plus a linear layer to logits at the top,
// and you have LLaMA-7B's architecture.
//
// The test is the one that matters in practice: running the block over a
// whole sequence at once (how training works) must give EXACTLY the same
// outputs as feeding tokens one at a time through the KV cache (how
// generation works). Getting RoPE's positions or the cache wrong breaks it
// immediately.
//
// YOUR TASK: the two residual connections, RoPE on q and k, and the cache.
//
const std = @import("std");

const d = 8; // model width
const heads = 2;
const hd = d / heads; // head size: 4, so RoPE rotates 2 pairs per head
const ffn = 12; // SwiGLU hidden size
const max_t = 8;

// ─── the pieces, from earlier exercises ─────────────────────────────────

fn rmsnorm(x: [d]f64, g: [d]f64) [d]f64 {
    var s: f64 = 0;
    for (x) |v| s += v * v;
    const r = @sqrt(s / d + 1e-6);
    var out: [d]f64 = undefined;
    for (&out, x, g) |*o, v, gi| o.* = gi * v / r;
    return out;
}

/// y = W x, W is [rows, cols] row-major.
fn matvec(comptime rows: usize, comptime cols: usize, w: *const [rows * cols]f64, x: [cols]f64) [rows]f64 {
    var y: [rows]f64 = @splat(0);
    for (0..rows) |i| for (0..cols) |j| {
        y[i] += w[i * cols + j] * x[j];
    };
    return y;
}

/// Rotate each pair (v[2i], v[2i+1]) of every head by pos * f_i (093).
fn rope(v: [d]f64, pos: usize) [d]f64 {
    var out = v;
    for (0..heads) |h| for (0..hd / 2) |i| {
        const f = 1 / std.math.pow(f64, 10000, @as(f64, @floatFromInt(2 * i)) / hd);
        const angle = @as(f64, @floatFromInt(pos)) * f;
        const a = v[h * hd + 2 * i];
        const b = v[h * hd + 2 * i + 1];
        out[h * hd + 2 * i] = a * @cos(angle) - b * @sin(angle);
        out[h * hd + 2 * i + 1] = a * @sin(angle) + b * @cos(angle);
    };
    return out;
}

fn silu(z: f64) f64 {
    return z / (1 + @exp(-z));
}

const Weights = struct {
    g1: [d]f64,
    g2: [d]f64,
    wq: [d * d]f64,
    wk: [d * d]f64,
    wv: [d * d]f64,
    wo: [d * d]f64,
    w1: [ffn * d]f64,
    w3: [ffn * d]f64,
    w2: [d * ffn]f64,

    fn init() Weights {
        var w: Weights = undefined;
        inline for (std.meta.fields(Weights), 0..) |field, fi| {
            const arr = &@field(w, field.name);
            for (arr, 0..) |*x, i| {
                const t: f64 = @floatFromInt(i * 7 + fi * 13);
                x.* = 0.3 * @sin(t) + (if (field.name[0] == 'g') 1.0 else 0.0);
            }
        }
        return w;
    }
};

fn swiglu(w: *const Weights, x: [d]f64) [d]f64 {
    const a = matvec(ffn, d, &w.w1, x);
    const b = matvec(ffn, d, &w.w3, x);
    var hidden: [ffn]f64 = undefined;
    for (&hidden, a, b) |*o, ai, bi| o.* = silu(ai) * bi;
    return matvec(d, ffn, &w.w2, hidden);
}

// ─── the KV cache and attention ─────────────────────────────────────────

const Cache = struct {
    k: [max_t][d]f64 = undefined,
    v: [max_t][d]f64 = undefined,
    len: usize = 0,
};

/// Attention for the token at position cache.len, whose normalized input
/// is n. Appends its k and v to the cache.
fn attention(w: *const Weights, cache: *Cache, n: [d]f64) [d]f64 {
    const pos = cache.len;
    const q = ???;
    const k = ???;
    cache.k[pos] = k;
    cache.v[pos] = matvec(d, d, &w.wv, n);
    ???;

    var out: [d]f64 = @splat(0);
    for (0..heads) |h| {
        // scores over every cached token: causal by construction
        var scores: [max_t]f64 = undefined;
        var m: f64 = -std.math.inf(f64);
        for (0..cache.len) |j| {
            var s: f64 = 0;
            for (0..hd) |c| s += q[h * hd + c] * cache.k[j][h * hd + c];
            scores[j] = s / @sqrt(@as(f64, hd));
            m = @max(m, scores[j]);
        }
        var total: f64 = 0;
        for (scores[0..cache.len]) |*s| {
            s.* = @exp(s.* - m);
            total += s.*;
        }
        for (0..cache.len) |j| for (0..hd) |c| {
            out[h * hd + c] += scores[j] / total * cache.v[j][h * hd + c];
        };
    }
    return matvec(d, d, &w.wo, out);
}

// ─── the block ──────────────────────────────────────────────────────────

/// One token through the block, using and extending the cache.
fn block(w: *const Weights, cache: *Cache, x: [d]f64) [d]f64 {
    const a = attention(w, cache, rmsnorm(x, w.g1));
    var h: [d]f64 = undefined;
    for (&h, x, a) |*o, xi, ai| o.* = ???;
    const f = swiglu(w, rmsnorm(h, w.g2));
    var out: [d]f64 = undefined;
    for (&out, h, f) |*o, hi, fi| o.* = ???;
    return out;
}

/// The whole sequence at once, the way training runs it: every position
/// attends over positions 0..t with an explicit causal mask.
fn blockFullSequence(w: *const Weights, xs: []const [d]f64, outs: [][d]f64) void {
    const t = xs.len;
    var q: [max_t][d]f64 = undefined;
    var k: [max_t][d]f64 = undefined;
    var v: [max_t][d]f64 = undefined;
    for (xs, 0..) |x, i| {
        const n = rmsnorm(x, w.g1);
        q[i] = rope(matvec(d, d, &w.wq, n), i);
        k[i] = rope(matvec(d, d, &w.wk, n), i);
        v[i] = matvec(d, d, &w.wv, n);
    }
    for (0..t) |i| {
        var att: [d]f64 = @splat(0);
        for (0..heads) |h| {
            var scores: [max_t]f64 = undefined;
            var m: f64 = -std.math.inf(f64);
            for (0..t) |j| {
                var s: f64 = 0;
                for (0..hd) |c| s += q[i][h * hd + c] * k[j][h * hd + c];
                scores[j] = if (j <= i) s / @sqrt(@as(f64, hd)) else -std.math.inf(f64); // the mask
                m = @max(m, scores[j]);
            }
            var total: f64 = 0;
            for (scores[0..t]) |*s| {
                s.* = @exp(s.* - m);
                total += s.*;
            }
            for (0..t) |j| for (0..hd) |c| {
                att[h * hd + c] += scores[j] / total * v[j][h * hd + c];
            };
        }
        const a = matvec(d, d, &w.wo, att);
        var h: [d]f64 = undefined;
        for (&h, xs[i], a) |*o, xi, ai| o.* = xi + ai;
        const f = swiglu(w, rmsnorm(h, w.g2));
        for (&outs[i], h, f) |*o, hi, fi| o.* = hi + fi;
    }
}

test "generation with a KV cache equals the full-sequence forward pass" {
    const w = Weights.init();
    var xs: [6][d]f64 = undefined;
    for (&xs, 0..) |*x, i| for (x, 0..) |*v, j| {
        v.* = @cos(@as(f64, @floatFromInt(i * d + j)) * 0.7);
    };

    var full: [6][d]f64 = undefined;
    blockFullSequence(&w, &xs, &full);

    var cache: Cache = .{};
    for (xs, 0..) |x, i| {
        const out = block(&w, &cache, x);
        for (out, full[i]) |a, b| try std.testing.expectApproxEqAbs(b, a, 1e-12);
    }
    try std.testing.expectEqual(6, cache.len);
}

test "the first token only sees itself" {
    // at position 0, RoPE's angle is 0 and attention has one key: the
    // attention output is just Wo · v
    const w = Weights.init();
    var x: [d]f64 = undefined;
    for (&x, 0..) |*v, j| v.* = @as(f64, @floatFromInt(j)) - 3.5;
    var cache: Cache = .{};
    const n = rmsnorm(x, w.g1);
    const got = attention(&w, &cache, n);
    const want = matvec(d, d, &w.wo, matvec(d, d, &w.wv, n));
    for (got, want) |a, b| try std.testing.expectApproxEqAbs(b, a, 1e-12);
}

test "a residual stream: with zero weights the block is the identity" {
    var w = Weights.init();
    @memset(&w.wo, 0);
    @memset(&w.w2, 0);
    var x: [d]f64 = undefined;
    for (&x, 0..) |*v, j| v.* = @floatFromInt(j);
    var cache: Cache = .{};
    const out = block(&w, &cache, x);
    try std.testing.expectEqualSlices(f64, &x, &out);
}
