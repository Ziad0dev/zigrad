//
// ─── Exercise 173: grouped-query attention ────────────────────────────
//
// The KV cache (094, 145) is the memory bottleneck of serving LLMs, and it
// holds one key and one value per KV head, per layer, per token.
// Multi-head attention (092) gives every query head its own K and V heads.
// Do they all need their own?
//
//   * multi-query attention (MQA, Shazeer 2019): all query heads share ONE
//     K head and ONE V head. The cache shrinks by the number of heads,
//     but quality suffers a little.
//   * grouped-query attention (GQA, Ainslie et al. 2023): the middle
//     ground. Query heads come in groups, and each group shares one KV
//     head. 32 query heads with 8 KV heads: groups of 4, a 4x smaller
//     cache. Llama 2 70B and most later open models use it.
//
// Query head h reads KV head h / group, where group = q_heads / kv_heads.
// Mathematically, GQA is just MHA where the K and V heads are repeated
// `group` times, and that's the test: the grouped version must match MHA
// run on repeated K and V exactly, while the cache stores 4x less.
//
// YOUR TASK: map query heads to KV heads, and size the cache.
//
const std = @import("std");

//@include attention_helpers

fn kvHeadFor(h: usize, q_heads: usize, kv_heads: usize) usize {
    const group = q_heads / kv_heads;
    return ⟪h / group|||???⟫;
}

/// Bytes of KV cache per token, for every layer.
fn cacheBytesPerToken(layers: usize, kv_heads: usize, head_dim: usize, bytes_each: usize) usize {
    return ⟪2 * layers * kv_heads * head_dim * bytes_each|||???⟫;
}

const seq = 3; // tokens
const hd = 2; // head size
const nq = 4; // query heads
const nkv = 2; // KV heads

/// q: [nq][seq * hd], k and v: [nkv][seq * hd]. Causal attention per head.
fn gqa(q: *const [nq][seq * hd]f64, k: *const [nkv][seq * hd]f64, v: *const [nkv][seq * hd]f64, out: *[nq][seq * hd]f64) void {
    for (0..nq) |h| {
        const kv = kvHeadFor(h, nq, nkv);
        causalAttention(&q[h], ⟪&k[kv]|||???⟫, &v[kv], seq, hd, hd, &out[h]);
    }
}

test "query heads share KV heads in groups" {
    try std.testing.expectEqual(0, kvHeadFor(3, 32, 8));
    try std.testing.expectEqual(1, kvHeadFor(4, 32, 8));
    try std.testing.expectEqual(7, kvHeadFor(31, 32, 8));
    // MHA: every head its own; MQA: everyone shares head 0
    try std.testing.expectEqual(5, kvHeadFor(5, 32, 32));
    try std.testing.expectEqual(0, kvHeadFor(31, 32, 1));
}

test "GQA equals MHA with repeated K and V" {
    var q: [nq][seq * hd]f64 = undefined;
    var k: [nkv][seq * hd]f64 = undefined;
    var v: [nkv][seq * hd]f64 = undefined;
    for (0..nq) |h| for (0..seq * hd) |i| {
        q[h][i] = @sin(@as(f64, @floatFromInt(h * 7 + i)));
    };
    for (0..nkv) |h| for (0..seq * hd) |i| {
        k[h][i] = @cos(@as(f64, @floatFromInt(h * 5 + i)));
        v[h][i] = @as(f64, @floatFromInt(h * 10 + i));
    };
    var grouped: [nq][seq * hd]f64 = undefined;
    gqa(&q, &k, &v, &grouped);

    // MHA on K and V repeated: heads 0, 1 use KV 0; heads 2, 3 use KV 1
    for (0..nq) |h| {
        var full: [seq * hd]f64 = undefined;
        causalAttention(&q[h], &k[h / 2], &v[h / 2], seq, hd, hd, &full);
        try std.testing.expectEqualSlices(f64, &full, &grouped[h]);
    }
}

test "the cache shrinks by the group size" {
    // Llama-2-70B-like: 80 layers, 64 query heads of 128, f16
    const mha = cacheBytesPerToken(80, 64, 128, 2);
    const grouped = cacheBytesPerToken(80, 8, 128, 2);
    try std.testing.expectEqual(2_621_440, mha); // 2.5 MB per token!
    try std.testing.expectEqual(8, mha / grouped);
}
