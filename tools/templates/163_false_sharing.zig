//
// ─── Exercise 163: false sharing ──────────────────────────────────────
//
// 162's threads write DIFFERENT rows, so there's no data race. But the
// hardware doesn't track bytes: caches track whole 64-byte lines (151).
// When one core writes to a line, every other core's copy of that line is
// thrown away, and must be fetched again before they can write it.
//
// So give 8 threads one u64 counter each, packed side by side:
//
//     counters: [c0 c1 c2 c3 c4 c5 c6 c7]    8 x 8 bytes = ONE cache line
//
// No two threads touch the same counter, yet every write by one thread
// evicts the line from the other seven. The line bounces between cores,
// and the "parallel" loop can run slower than a single thread. This is
// *false sharing*: sharing a cache line without sharing any data.
//
// The fix is padding: space the counters a whole line apart, so each lives
// alone in its line. Zig has a constant for this, std.atomic.cache_line,
// and it's deliberately cautious: 128 on x86-64 (Intel's prefetcher pulls
// lines in pairs, so neighbours still interfere) and on 64-bit ARM (some
// big cores really have 128-byte lines).
//
// Timing this would be flaky in a test, so we count instead: how many
// cache lines are written by more than one thread?
//
// YOUR TASK: find each counter's cache line, and count the shared lines.
//
const std = @import("std");

const line = 64;

/// The cache line that byte address `addr` belongs to.
fn lineOf(addr: usize) usize {
    return ⟪addr / line|||???⟫;
}

/// Thread i writes one 8-byte counter at byte offset i * stride.
/// How many cache lines are written by two or more threads?
fn sharedLines(threads: usize, stride: usize) usize {
    var writers: [256]usize = @splat(0); // writers per line
    for (0..threads) |i| {
        const first = lineOf(i * stride);
        const last = lineOf(i * stride + 8 - 1); // a counter could straddle two lines
        for (first..last + 1) |l| writers[l] += 1;
    }
    var shared: usize = 0;
    for (writers) |w| {
        if (⟪w >= 2|||???⟫) shared += 1;
    }
    return shared;
}

/// The smallest stride, at least 8 bytes, that is a whole number of lines.
fn paddedStride() usize {
    return ⟪line|||???⟫;
}

test "packed counters share lines" {
    // 8 counters in one line: one shared line
    try std.testing.expectEqual(1, sharedLines(8, 8));
    // 16 counters: two lines, each shared by 8 threads
    try std.testing.expectEqual(2, sharedLines(16, 8));
}

test "padding removes all sharing" {
    try std.testing.expectEqual(0, sharedLines(16, paddedStride()));
    // a stride of 60 bytes isn't enough: counters straddle line boundaries
    try std.testing.expect(sharedLines(16, 60) > 0);
}

test "the real thing, with padding" {
    // Zig's way to lay counters out a line apart.
    const Padded = struct { value: u64 align(std.atomic.cache_line) };
    try std.testing.expect(@sizeOf(Padded) >= 64);
    try std.testing.expectEqual(0, @sizeOf(Padded) % 64);
}
