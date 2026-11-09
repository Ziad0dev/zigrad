//
// ─── Checkpoint 3: Part III, from memory ──────────────────────────────
//
// No blanks, nothing new: five functions from five chapters of Part III.
// Try each cold. If you have to look one up, read YOUR finished exercise
// (its number is in the doc comment), close it, and write it from memory.
//
// YOUR TASK: write mergePair(), perplexity(), qUpdate(), kahanSum() and
// quantize().
//
const std = @import("std");

/// (117) One byte-pair-encoding merge: copy `tokens` into `out`, with
/// every occurrence of the pair (first, second) replaced by `new_id`,
/// scanning left to right. Returns the new length.
fn mergePair(tokens: []const u32, first: u32, second: u32, new_id: u32, out: []u32) usize {
    ???;
}

/// (119) Perplexity. p[i] is the probability the model gave to the token
/// that actually came next at position i.
fn perplexity(p: []const f64) f64 {
    ???;
}

const actions = 2;

/// (127, 128) One Q-learning update, after taking action a in state s,
/// getting reward r and landing in state s2. q[state][action]. If s2 is
/// terminal, there is no future to count.
fn qUpdate(q: [][actions]f64, s: usize, a: usize, r: f64, s2: usize, terminal: bool, gamma: f64, lr: f64) void {
    ???;
}

/// (146) The sum of xs in f32, with Kahan's compensation: carry the
/// rounding error of each addition into the next one.
fn kahanSum(xs: []const f32) f32 {
    ???;
}

/// (141) Quantize x to int8 with one scale: the largest |x| maps to 127,
/// and x[i] is about q[i] * scale. Returns the scale (1 if x is all zeros).
fn quantize(x: []const f32, q: []i8) f32 {
    ???;
}

const t = std.testing;

test "a BPE merge" {
    var out: [8]u32 = undefined;
    // a a a b d a a a b a c, merging (a, a) -> Z
    const text = [_]u32{ 'a', 'a', 'a', 'b', 'd', 'a', 'a', 'a', 'b', 'a', 'c' };
    var long: [11]u32 = undefined;
    const n = mergePair(&text, 'a', 'a', 256, &long);
    try t.expectEqualSlices(u32, &.{ 256, 'a', 'b', 'd', 256, 'a', 'b', 'a', 'c' }, long[0..n]);
    // the pair at the very end, and a first token alone at the end
    try t.expectEqual(2, mergePair(&.{ 1, 2, 1, 2 }, 1, 2, 9, &out));
    try t.expectEqualSlices(u32, &.{ 9, 9 }, out[0..2]);
    try t.expectEqual(2, mergePair(&.{ 1, 2, 1 }, 1, 2, 9, &out));
    try t.expectEqualSlices(u32, &.{ 9, 1 }, out[0..2]);
    // order matters: (2, 1) is not (1, 2)
    try t.expectEqual(3, mergePair(&.{ 2, 1, 1, 2 }, 1, 2, 9, &out));
    try t.expectEqualSlices(u32, &.{ 2, 1, 9 }, out[0..3]);
    try t.expectEqual(0, mergePair(&.{}, 1, 2, 9, &out));
}

test "perplexity" {
    // always 1/4 sure: as confused as a uniform choice among 4
    try t.expectApproxEqAbs(4, perplexity(&.{ 0.25, 0.25, 0.25 }), 1e-12);
    try t.expectApproxEqAbs(1, perplexity(&.{ 1, 1 }), 1e-12);
    // the geometric mean of 1/p, not the arithmetic one: sqrt(2 * 8) = 4, not 5
    try t.expectApproxEqAbs(4, perplexity(&.{ 0.5, 0.125 }), 1e-12);
}

test "Q-learning" {
    var q = [_][actions]f64{ .{ 0, 0 }, .{ 0, 0 }, .{ 0.5, 2 } };
    // target = 1 + 0.9 * max(0.5, 2) = 2.8; move a tenth of the way there
    qUpdate(&q, 0, 1, 1, 2, false, 0.9, 0.1);
    try t.expectApproxEqAbs(0.28, q[0][1], 1e-12);
    try t.expectEqual(0, q[0][0]);
    qUpdate(&q, 0, 1, 1, 2, false, 0.9, 0.1);
    try t.expectApproxEqAbs(0.28 + 0.1 * (2.8 - 0.28), q[0][1], 1e-12);
    // the best action can be the first one
    var q2 = [_][actions]f64{ .{ 0, 0 }, .{ 3, -1 } };
    qUpdate(&q2, 0, 0, 0, 1, false, 0.5, 1);
    try t.expectApproxEqAbs(1.5, q2[0][0], 1e-12);
    // a terminal state has no future, whatever its row says
    qUpdate(&q, 1, 0, 5, 2, true, 0.9, 0.5);
    try t.expectApproxEqAbs(2.5, q[1][0], 1e-12);
}

test "Kahan" {
    // one big number, then ten thousand small ones: plain f32 addition loses them all
    var xs: [10001]f32 = undefined;
    xs[0] = 100_000_000;
    for (xs[1..]) |*x| x.* = 1;
    var naive: f32 = 0;
    for (xs) |x| naive += x;
    try t.expectEqual(100_000_000, naive);
    try t.expectEqual(100_010_000, kahanSum(&xs));
    try t.expectEqual(6, kahanSum(&.{ 1, 2, 3 }));
    try t.expectEqual(0, kahanSum(&.{}));
}

test "int8 quantization" {
    var q: [4]i8 = undefined;
    const scale = quantize(&.{ 0.5, -2.54, 1.27, 0.014 }, &q);
    try t.expectApproxEqAbs(0.02, scale, 1e-7);
    try t.expectEqualSlices(i8, &.{ 25, -127, 64, 1 }, &q); // rounded to nearest, not cut off
    // all zeros: nothing to scale by
    try t.expectEqual(1, quantize(&.{ 0, 0 }, q[0..2]));
    try t.expectEqualSlices(i8, &.{ 0, 0 }, q[0..2]);
    // the largest magnitude can be positive
    _ = quantize(&.{ 3, -1.5 }, q[0..2]);
    try t.expectEqualSlices(i8, &.{ 127, -64 }, q[0..2]);
}
