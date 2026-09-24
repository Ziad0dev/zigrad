//
// ─── Exercise 095: online softmax and flash attention ──────────────────
//
// Attention's weights matrix is T x T. At T = 100,000 tokens that's 10^10
// numbers per head: it doesn't fit, and even writing it to memory and
// reading it back (044) would dominate everything.
//
// *Flash attention* never builds it. It walks over the keys in BLOCKS and
// keeps a running softmax. The trick is that softmax can be computed
// *online*, one block at a time, with three running values per query:
//
//     m    the biggest score seen so far      (for stability, 018)
//     l    the sum of e^(score - m) so far
//     acc  the sum of e^(score - m) * value so far
//
// When a new block raises the max from m to m_new, everything computed so
// far was scaled by e^(-m), and now needs e^(-m_new). Multiply the old l
// and acc by
//
//     correction = e^(m - m_new)
//
// then add the new block's terms. At the end, out = acc / l. Exact, not
// an approximation: same answer as the normal way, in far less memory.
// Combined with tiling (046) it's why modern transformers are fast.
// In tinygrad, getting kernels like this is a job for the scheduler and
// its fusion rules.
//
// YOUR TASK: write the correction, the rescale, the accumulate and the
// final divide.
//
const std = @import("std");

fn dot(a: []const f64, b: []const f64) f64 {
    var acc: f64 = 0;
    for (a, b) |x, y| acc += x * y;
    return acc;
}

/// Attention for one query over all t keys, `block` keys at a time.
fn flashRow(q: []const f64, k: []const f64, v: []const f64, t: usize, d: usize, dv: usize, block: usize, out: []f64) void {
    const scale = 1 / @sqrt(@as(f64, @floatFromInt(d)));
    var m: f64 = -std.math.inf(f64);
    var l: f64 = 0;
    var acc: [16]f64 = @splat(0);

    var start: usize = 0;
    while (start < t) : (start += block) {
        const end = @min(start + block, t);
        var s: [16]f64 = undefined; // scores for this block only
        var m_new = m;
        for (start..end) |j| {
            s[j - start] = dot(q, k[j * d ..][0..d]) * scale;
            m_new = @max(m_new, s[j - start]);
        }
        const correction = ⟪@exp(m - m_new)|||???⟫;
        l *= correction;
        for (acc[0..dv]) |*a| ⟪a.* *= correction|||???⟫;
        for (start..end) |j| {
            const p = @exp(s[j - start] - m_new);
            ⟪l += p;|||???⟫
            for (0..dv) |c| acc[c] += ⟪p * v[j * dv + c]|||???⟫;
        }
        m = m_new;
    }
    for (0..dv) |c| out[c] = ⟪acc[c] / l|||???⟫;
}

/// The normal way: all t scores, softmax, weighted sum.
fn plainRow(q: []const f64, k: []const f64, v: []const f64, t: usize, d: usize, dv: usize, out: []f64) void {
    const scale = 1 / @sqrt(@as(f64, @floatFromInt(d)));
    var s: [64]f64 = undefined;
    var m: f64 = -std.math.inf(f64);
    for (0..t) |j| {
        s[j] = dot(q, k[j * d ..][0..d]) * scale;
        m = @max(m, s[j]);
    }
    var total: f64 = 0;
    for (s[0..t]) |*x| {
        x.* = @exp(x.* - m);
        total += x.*;
    }
    for (0..dv) |c| {
        var acc: f64 = 0;
        for (0..t) |j| acc += s[j] * v[j * dv + c];
        out[c] = acc / total;
    }
}

test "same answer, whatever the block size" {
    const t = 10;
    const d = 4;
    const dv = 3;
    var k: [t * d]f64 = undefined;
    var v: [t * dv]f64 = undefined;
    for (&k, 0..) |*x, i| x.* = @sin(@as(f64, @floatFromInt(i)) * 1.3) * 3;
    for (&v, 0..) |*x, i| x.* = @cos(@as(f64, @floatFromInt(i)) * 0.7);
    const q = [_]f64{ 1, -2, 0.5, 3 };

    var expected: [dv]f64 = undefined;
    plainRow(&q, &k, &v, t, d, dv, &expected);
    for ([_]usize{ 1, 2, 3, 7, 10 }) |block| {
        var got: [dv]f64 = undefined;
        flashRow(&q, &k, &v, t, d, dv, block, &got);
        for (expected, got) |e, g| try std.testing.expectApproxEqAbs(e, g, 1e-12);
    }
}
