// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 053: many devices ────────────────────────────────────────
//
// One GPU not enough? Use several. tinygrad can *shard* a tensor across
// devices with Tensor.shard(devices, axis): each device holds one slice.
//
// Elementwise ops are easy: every device works on its own slice, and
// nobody needs to talk to anybody. Reduces are where devices must
// communicate: each device sums its slice, and then the partial sums are
// combined and shared so every device holds the total. That's called an
// *all-reduce*.
//
// Data-parallel training is built on exactly this. Every device keeps a
// full copy of the weights, and gets a different slice of the batch:
//
//     1. each device computes the gradient on its own examples
//     2. all-reduce: average the gradients across devices
//     3. every device applies the SAME averaged update, so the copies of
//        the weights stay identical
//
// Why is the average right? With equal-size slices, the mean over the
// whole batch is the mean of the slices' means, so the averaged gradient
// is exactly the full-batch gradient.
//
// Splitting n elements over d devices: slices of ceil(n / d), computed as
// (n + d - 1) / d, with the last slice possibly shorter.
//
// YOUR TASK: finish shardRange() and allReduceMean().
//
const std = @import("std");

/// The [start, end) that device i of d holds, out of n elements.
fn shardRange(n: usize, d: usize, i: usize) [2]usize {
    const chunk = (n + d - 1) / d;
    const start = @min(i * chunk, n);
    const end = @min(start + chunk, n);
    return .{ start, end };
}

/// Every device ends up holding the average of all the values.
fn allReduceMean(values: []f32) void {
    var total: f32 = 0;
    for (values) |v| total += v;
    const mean = total / @as(f32, @floatFromInt(values.len));
    for (values) |*v| v.* = mean;
}

/// Gradient of mean((w*x - y)^2) with respect to w, on one device's slice.
fn localGrad(w: f32, xs: []const f32, ys: []const f32) f32 {
    var g: f32 = 0;
    for (xs, ys) |x, y| g += 2 * (w * x - y) * x;
    return g / @as(f32, @floatFromInt(xs.len));
}

const devices = 4;

fn dataParallelGrad(w: f32, xs: []const f32, ys: []const f32) f32 {
    var grads: [devices]f32 = undefined;
    for (&grads, 0..) |*g, d| {
        const r = shardRange(xs.len, devices, d);
        g.* = localGrad(w, xs[r[0]..r[1]], ys[r[0]..r[1]]);
    }
    allReduceMean(&grads);
    // Every device now holds the same number.
    for (grads[1..]) |g| std.debug.assert(g == grads[0]);
    return grads[0];
}

test "sharding" {
    try std.testing.expectEqual([2]usize{ 0, 2 }, shardRange(8, 4, 0));
    try std.testing.expectEqual([2]usize{ 6, 8 }, shardRange(8, 4, 3));
    // 10 over 4: slices of 3, 3, 3, 1
    try std.testing.expectEqual([2]usize{ 3, 6 }, shardRange(10, 4, 1));
    try std.testing.expectEqual([2]usize{ 9, 10 }, shardRange(10, 4, 3));
}

test "all-reduce" {
    var v = [_]f32{ 1, 2, 3, 6 };
    allReduceMean(&v);
    try std.testing.expectEqualSlices(f32, &.{ 3, 3, 3, 3 }, &v);
}

test "data parallel = full batch" {
    const xs = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const ys = [_]f32{ 3, 5, 7, 9, 11, 13, 15, 17 };
    for ([_]f32{ 0, 1.5, 2, 3 }) |w| {
        try std.testing.expectApproxEqAbs(localGrad(w, &xs, &ys), dataParallelGrad(w, &xs, &ys), 1e-4);
    }
}
