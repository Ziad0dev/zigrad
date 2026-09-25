// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 092: multi-head attention ────────────────────────────────
//
// One attention pattern per layer is limiting: a token might need to look
// at the previous word for grammar AND at a name three sentences back.
// So transformers run H attentions ("heads") side by side, each on its
// own slice of the vectors, then glue the results back together.
//
// With model width D = H * dh, the split is pure movement ops (chapter 2):
//
//     x [T, D]  --reshape-->  [T, H, dh]  --permute(1, 0, 2)-->  [H, T, dh]
//
// Each head is an independent [T, dh] attention. Merging is the reverse:
// permute back to [T, H, dh] and reshape to [T, D].
//
// No data needs to move: element (head h, token t, dim j) lives at
//
//     x[t * D + h * dh + j]
//
// in the original [T, D] layout. That's the whole trick. tinygrad writes
// exactly these reshapes and permutes, and the views make them free.
//
// YOUR TASK: gather each head's slice, and scatter the output back.
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

/// q, k, v, out: [t, heads * dh], causal.
fn multiHead(q: []const f64, k: []const f64, v: []const f64, t: usize, heads: usize, dh: usize, out: []f64) void {
    const width = heads * dh;
    var qh: [64]f64 = undefined;
    var kh: [64]f64 = undefined;
    var vh: [64]f64 = undefined;
    var oh: [64]f64 = undefined;
    for (0..heads) |h| {
        // gather head h: [t, dh]
        for (0..t) |tok| {
            for (0..dh) |j| {
                const at = tok * width + h * dh + j;
                qh[tok * dh + j] = q[at];
                kh[tok * dh + j] = k[at];
                vh[tok * dh + j] = v[at];
            }
        }
        causalAttention(qh[0 .. t * dh], kh[0 .. t * dh], vh[0 .. t * dh], t, dh, dh, oh[0 .. t * dh]);
        // put it back into its slice of the output
        for (0..t) |tok| {
            for (0..dh) |j| out[tok * width + h * dh + j] = oh[tok * dh + j];
        }
    }
}

test "two heads = two separate attentions on the two halves" {
    const t = 3;
    const heads = 2;
    const dh = 2;
    var q: [t * 4]f64 = undefined;
    var k: [t * 4]f64 = undefined;
    var v: [t * 4]f64 = undefined;
    for (&q, &k, &v, 0..) |*a, *b, *c, i| {
        const f: f64 = @floatFromInt(i);
        a.* = @sin(f);
        b.* = @cos(f * 0.7);
        c.* = f;
    }
    var out: [t * 4]f64 = undefined;
    multiHead(&q, &k, &v, t, heads, dh, &out);

    for (0..heads) |h| {
        var qs: [t * dh]f64 = undefined;
        var ks: [t * dh]f64 = undefined;
        var vs: [t * dh]f64 = undefined;
        for (0..t) |tok| {
            for (0..dh) |j| {
                qs[tok * dh + j] = q[tok * 4 + h * dh + j];
                ks[tok * dh + j] = k[tok * 4 + h * dh + j];
                vs[tok * dh + j] = v[tok * 4 + h * dh + j];
            }
        }
        var expected: [t * dh]f64 = undefined;
        causalAttention(&qs, &ks, &vs, t, dh, dh, &expected);
        for (0..t) |tok| {
            for (0..dh) |j| try std.testing.expectApproxEqAbs(expected[tok * dh + j], out[tok * 4 + h * dh + j], 1e-12);
        }
    }
}
