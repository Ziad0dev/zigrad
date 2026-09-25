//
// ─── Exercise 151: caches ──────────────────────────────────────────────
//
// Chapter 29: the memory hierarchy, and why the ORDER you touch memory
// matters as much as how much you touch.
//
// Memory is fetched in *cache lines*, typically 64 bytes (16 f32s) at a
// time. Touch one byte and its whole line comes into the cache. Reading
// the next 15 floats is then almost free (a *hit*). A *miss* costs a trip
// to main memory: ~100x slower.
//
// The simplest cache is *direct-mapped*. For an address:
//
//     line = addr / 64              which 64-byte line it's in
//     slot = line % number_of_slots which cache slot that line must use
//     tag  = line / number_of_slots which of the many lines sharing that
//                                   slot is actually stored there
//
// Walking a row-major matrix row by row: one miss per 16 floats. Walking
// it column by column: each step jumps a whole row ahead, a new line
// every time. And lines whose addresses are a power of two apart fight
// over the same few slots and keep evicting each other (*conflict
// misses*). Everything in chapter 9 (tiling!) is about fetching each line
// once and using all of it.
//
// YOUR TASK: finish access().
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
        const line = ⟪addr / line_bytes|||???⟫;
        const slot = ⟪line % c.slots|||???⟫;
        const tag = ⟪line / c.slots|||???⟫;
        if (⟪c.tags[slot] == tag|||???⟫) {
            c.hits += 1;
        } else {
            c.misses += 1;
            c.tags[slot] = tag; // evict whatever was there
        }
    }
};

test "streaming: one miss per line" {
    var c: Cache = .{ .slots = 64 }; // 4 KB
    for (0..4096) |i| c.access(i * 4); // 4096 floats in a row
    try std.testing.expectEqual(256, c.misses); // 16 KB / 64 B
    try std.testing.expectEqual(4096 - 256, c.hits);
}

test "row by row vs column by column" {
    const n = 64; // a 64x64 f32 matrix: rows are 256 bytes apart
    var rows: Cache = .{ .slots = 64 };
    var cols: Cache = .{ .slots = 64 };
    for (0..n) |r| {
        for (0..n) |col| rows.access((r * n + col) * 4);
    }
    for (0..n) |col| {
        for (0..n) |r| cols.access((r * n + col) * 4);
    }
    try std.testing.expectEqual(256, rows.misses);
    try std.testing.expectEqual(4096, cols.misses); // every single access
}
