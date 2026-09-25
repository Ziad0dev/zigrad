// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 145: KV cache memory and paging ──────────────────────────
//
// The KV cache (094) is often the biggest thing in an inference server's
// memory. Per token it stores a key and a value for every layer and head:
//
//     bytes = 2 (K and V) * layers * kv_heads * head_dim * bytes_each * tokens
//
// For a LLaMA-7B-like model (32 layers, 32 heads of 128, f16) that's
// 512 KB per token: a 4096-token conversation is 2 GB.
//
// Serving many users at once, reserving a full-length contiguous cache
// per request wastes most of it, since most conversations are short.
// *Paged attention* (vLLM) borrows virtual memory's idea: split the cache
// into fixed-size BLOCKS (say 16 tokens), hand them out on demand, and
// keep a *block table* per request mapping its logical block i to
// whatever physical block it got:
//
//     token t lives in physical block table[t / 16], slot t % 16
//
// No waste beyond one partly-filled block per request.
//
// YOUR TASK: write the memory formula and the block-table lookup.
//
const std = @import("std");

const Model = struct { layers: u64, kv_heads: u64, head_dim: u64, bytes_each: u64 };

fn kvBytes(m: Model, tokens: u64) u64 {
    return 2 * m.layers * m.kv_heads * m.head_dim * m.bytes_each * tokens;
}

const block_size = 16;

/// Where token t's K/V lives: (physical block, slot inside it).
fn locate(table: []const usize, t: usize) [2]usize {
    return .{ table[t / block_size], t % block_size };
}

test "KV cache sizes" {
    const llama7b: Model = .{ .layers = 32, .kv_heads = 32, .head_dim = 128, .bytes_each = 2 };
    try std.testing.expectEqual(512 * 1024, kvBytes(llama7b, 1));
    try std.testing.expectEqual(2 * 1024 * 1024 * 1024, kvBytes(llama7b, 4096));
    // grouped-query attention: 8 KV heads instead of 32 cuts it 4x
    const gqa: Model = .{ .layers = 32, .kv_heads = 8, .head_dim = 128, .bytes_each = 2 };
    try std.testing.expectEqual(kvBytes(llama7b, 100) / 4, kvBytes(gqa, 100));
}

test "the block table" {
    // this request got physical blocks 7, 2 and 9, in that order
    const table = [_]usize{ 7, 2, 9 };
    try std.testing.expectEqual([2]usize{ 7, 0 }, locate(&table, 0));
    try std.testing.expectEqual([2]usize{ 7, 15 }, locate(&table, 15));
    try std.testing.expectEqual([2]usize{ 2, 0 }, locate(&table, 16));
    try std.testing.expectEqual([2]usize{ 9, 4 }, locate(&table, 36));
}
