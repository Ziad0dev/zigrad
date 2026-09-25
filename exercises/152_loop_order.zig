//
// ─── Exercise 152: loop order ──────────────────────────────────────────
//
// The same matmul, the same flops, the same answer, in a different loop
// order, can run several times faster. It's all cache lines (151).
//
//     ijk:  for i, for j, for k:  C[i][j] += A[i][k] * B[k][j]
//           the inner loop walks B DOWN a column: a new line every step
//
//     ikj:  for i, for k, for j:  C[i][j] += A[i][k] * B[k][j]
//           the inner loop walks B and C ALONG rows: streaming, 16 floats
//           per line
//
// Loop order is one of the choices tinygrad's optimizer makes. Tiling
// (046) goes further, so that a block of B is reused from cache many
// times before it's evicted.
//
// YOUR TASK: write the ikj loop.
//
const std = @import("std");

/// A direct-mapped cache: each memory line can live in exactly one slot.
const Cache = struct {
    const line_bytes = 64;
    slots: usize,
    tags: [256]?usize = @splat(null),
    misses: usize = 0,
    hits: usize = 0,

    fn access(c: *Cache, addr: usize) void {
        const line = addr / line_bytes;
        const slot = line % c.slots;
        const tag = line / c.slots;
        if (c.tags[slot] == tag) {
            c.hits += 1;
        } else {
            c.misses += 1;
            c.tags[slot] = tag; // evict whatever was there
        }
    }
};

const n = 32;
const a_base = 0;
const b_base = n * n * 4 + 64 * 7; // offsets so the matrices don't collide exactly
const c_base = 2 * (n * n * 4) + 64 * 13;

fn ijk(c: *Cache) void {
    for (0..n) |i| {
        for (0..n) |j| {
            for (0..n) |k| {
                c.access(a_base + (i * n + k) * 4);
                c.access(b_base + (k * n + j) * 4);
            }
            c.access(c_base + (i * n + j) * 4);
        }
    }
}

fn ikj(c: *Cache) void {
    for (0..n) |i| {
        for (0..n) |k| {
            c.access(a_base + (i * n + k) * 4);
            for (0..n) |j| {
                // read B[k][j] and C[i][j]
                ???;
            }
        }
    }
}

test "ikj streams, ijk strides" {
    // 2 KB of cache: smaller than even one 4 KB matrix, like a real L1
    // cache next to real-sized matrices
    var slow: Cache = .{ .slots = 32 };
    var fast: Cache = .{ .slots = 32 };
    ijk(&slow);
    ikj(&fast);
    try std.testing.expect(fast.misses * 4 < slow.misses);
}
