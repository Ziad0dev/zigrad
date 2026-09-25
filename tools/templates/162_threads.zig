//
// ─── Exercise 162: using every core ───────────────────────────────────
//
// SIMD (161) makes one core fast. A CPU has many cores, and a kernel only
// uses them if it's split into pieces that run on separate *threads*. For
// an elementwise or row-wise kernel that's easy: every output row is
// independent, so give each thread its own range of rows.
//
// Splitting n rows over t threads: chunks of ceil(n / t), computed as
// (n + t - 1) / t, just like 053's shards and 077's blocks. The last thread may
// get fewer rows, or none at all.
//
// The golden rule: two threads must never write the same memory at the
// same time (a *data race*: the result depends on timing, 078, 159).
// Disjoint row ranges guarantee it. Reading shared inputs is fine.
//
// Zig notes:
//   * std.Thread.spawn(.{}, function, .{ args... }) starts a thread that
//     runs function(args...). It can fail (the OS may refuse), so `try`.
//   * thread.join() waits until it's finished.
//
// YOUR TASK: compute each thread's row range, and spawn and join them.
//
const std = @import("std");

/// The [start, end) rows that thread `i` of `t` handles, out of `n`.
fn rowRange(n: usize, t: usize, i: usize) [2]usize {
    const chunk = ⟪(n + t - 1) / t|||???⟫;
    const start = @min(i * chunk, n);
    const end = ⟪@min(start + chunk, n)|||???⟫;
    return .{ start, end };
}

const Job = struct {
    x: []const f32, // [rows, cols]
    out: []f32, //     [rows]: each row's sum of squares
    cols: usize,
    start: usize,
    end: usize,

    fn run(job: Job) void {
        for (job.start..job.end) |r| {
            var s: f32 = 0;
            for (job.x[r * job.cols ..][0..job.cols]) |v| s += v * v;
            job.out[r] = s;
        }
    }
};

/// out[r] = sum of x[r][c]^2, with the rows split over `t` threads.
fn rowSumsOfSquares(x: []const f32, rows: usize, cols: usize, out: []f32, t: usize) !void {
    var threads: [64]std.Thread = undefined;
    for (0..t) |i| {
        const range = rowRange(rows, t, i);
        const job: Job = .{ .x = x, .out = out, .cols = cols, .start = range[0], .end = range[1] };
        threads[i] = ⟪try std.Thread.spawn(.{}, Job.run, .{job})|||???⟫;
    }
    for (threads[0..t]) |th| ⟪th.join();|||???;⟫
}

test "row ranges cover every row exactly once" {
    try std.testing.expectEqual([2]usize{ 0, 3 }, rowRange(10, 4, 0));
    try std.testing.expectEqual([2]usize{ 9, 10 }, rowRange(10, 4, 3));
    // more threads than rows: the extra threads get nothing
    try std.testing.expectEqual([2]usize{ 2, 2 }, rowRange(2, 4, 3));
    for (1..9) |t| {
        var next: usize = 0;
        for (0..t) |i| {
            const r = rowRange(37, t, i);
            try std.testing.expectEqual(next, r[0]);
            next = r[1];
        }
        try std.testing.expectEqual(37, next);
    }
}

test "threads give the same answer as one thread" {
    const rows = 101;
    const cols = 7;
    var x: [rows * cols]f32 = undefined;
    for (&x, 0..) |*v, i| v.* = @floatFromInt(i % 11);
    var one: [rows]f32 = undefined;
    var many: [rows]f32 = undefined;
    try rowSumsOfSquares(&x, rows, cols, &one, 1);
    try rowSumsOfSquares(&x, rows, cols, &many, 8);
    try std.testing.expectEqualSlices(f32, &one, &many);
    // row 0 is 0, 1, ..., 6: 0 + 1 + 4 + 9 + 16 + 25 + 36
    try std.testing.expectEqual(91, many[0]);
}
