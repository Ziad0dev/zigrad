// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 154: shared memory bank conflicts ────────────────────────
//
// Shared memory (078) is split into 32 *banks*, 4 bytes wide: word w
// lives in bank w % 32. Each bank serves one word per cycle. If the 32
// threads of a warp hit 32 different banks, the access takes one cycle.
// If k threads hit the SAME bank (at different words), it takes k cycles:
// a k-way *bank conflict*.
//
// The classic trap: a 32x32 tile, threads reading down a COLUMN. Thread t
// reads word t*32 + col, and t*32 + col ≡ col (mod 32) for every t: all 32
// threads in one bank, a 32-way conflict.
//
// The classic fix: pad each row to 33 words. Now thread t's word is
// t*33 + col, and t*33 ≡ t (mod 32): every thread gets its own bank. One
// wasted column of memory for a 32x speedup.
//
// YOUR TASK: compute each thread's bank and the worst conflict.
//
const std = @import("std");

const warp = 32;
const banks = 32;

/// The worst number of threads hitting one bank (distinct words assumed).
fn conflictDegree(words: [warp]usize) usize {
    var per_bank: [banks]usize = @splat(0);
    for (words) |w| per_bank[w % banks] += 1;
    var worst: usize = 0;
    for (per_bank) |c| worst = @max(worst, c);
    return worst;
}

/// Threads reading down column `col` of a tile whose rows are `row_words` long.
fn column(row_words: usize, col: usize) [warp]usize {
    var out: [warp]usize = undefined;
    for (&out, 0..) |*w, t| w.* = t * row_words + col;
    return out;
}

test "reading along a row: no conflicts" {
    var row: [warp]usize = undefined;
    for (&row, 0..) |*w, t| w.* = t;
    try std.testing.expectEqual(1, conflictDegree(row));
}

test "reading down a column: 32-way conflict, fixed by padding" {
    try std.testing.expectEqual(32, conflictDegree(column(32, 5)));
    try std.testing.expectEqual(1, conflictDegree(column(33, 5)));
}
