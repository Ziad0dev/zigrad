//
// ─── Exercise 169: parallel prefix sums ───────────────────────────────
//
// A *prefix sum* (or *scan*) replaces every element by the sum of
// everything up to it:
//
//     x    = [3, 1, 4, 1, 5]
//     scan = [3, 4, 8, 9, 14]        inclusive: element i counts itself
//
// It shows up all over ML systems: cumsum, top-p sampling (174), turning
// counts into offsets (MoE routing, 175; sparse formats), stream
// compaction. Sequentially it's a trivial loop, but every step needs the
// previous one. How do thousands of threads do it?
//
// *Hillis-Steele*: in step d (d = 1, 2, 4, 8, ...), every element adds the
// value d places to its left, if there is one:
//
//     start      3  1  4  1  5
//     d = 1      3  4  5  5  6      each + left neighbour
//     d = 2      3  4  8  9 11      each + the one 2 to the left
//     d = 4      3  4  8  9 14      each + the one 4 to the left
//
// log2(n) steps, each fully parallel, reading the OLD values (like 168's
// shuffles, which is exactly how a warp does it). The catch: about
// n log2(n) additions in total, versus n - 1 for the loop. *Blelloch's* scan
// does only O(n) work with a tree up and back down, which matters for big
// arrays. GPU libraries like CUB use a scan per warp, then per block, then
// stitch the blocks together.
//
// YOUR TASK: one Hillis-Steele step, and the loop around it.
//
const std = @import("std");

/// out[i] = x[i] + x[i - d] (or just x[i] when i < d). Returns additions done.
fn step(x: []const f32, d: usize, out: []f32) usize {
    var adds: usize = 0;
    for (out, 0..) |*o, i| {
        if (i >= d) {
            o.* = ⟪x[i] + x[i - d]|||???⟫;
            adds += 1;
        } else {
            o.* = x[i];
        }
    }
    return adds;
}

/// Inclusive scan, in place, using `tmp` (same length) as scratch.
/// Returns the total additions.
fn hillisSteele(x: []f32, tmp: []f32) usize {
    var adds: usize = 0;
    var d: usize = 1;
    while (d < x.len) : (d *= 2) {
        adds += step(x, d, tmp);
        ⟪@memcpy(x, tmp);|||???;⟫
    }
    return adds;
}

fn sequential(x: []f32) usize {
    for (1..x.len) |i| x[i] += x[i - 1];
    return x.len -| 1;
}

test "the example from the comment" {
    var x = [_]f32{ 3, 1, 4, 1, 5 };
    var tmp: [5]f32 = undefined;
    _ = hillisSteele(&x, &tmp);
    try std.testing.expectEqualSlices(f32, &.{ 3, 4, 8, 9, 14 }, &x);
}

test "matches the loop, and costs more additions" {
    var a: [1000]f32 = undefined;
    var b: [1000]f32 = undefined;
    var tmp: [1000]f32 = undefined;
    for (&a, &b, 0..) |*p, *q, i| {
        p.* = @floatFromInt(i % 3);
        q.* = p.*;
    }
    const parallel_adds = hillisSteele(&a, &tmp);
    const seq_adds = sequential(&b);
    try std.testing.expectEqualSlices(f32, &b, &a);
    try std.testing.expectEqual(999, seq_adds);
    // 10 steps (2^10 = 1024 >= 1000); step d does 1000 - d additions
    try std.testing.expectEqual(10 * 1000 - 1023, parallel_adds);
}
