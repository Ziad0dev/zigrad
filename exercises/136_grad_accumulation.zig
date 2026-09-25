//
// ─── Exercise 136: gradient accumulation ───────────────────────────────
//
// Chapter 26: training models too big for one GPU's memory or batch.
//
// Want a batch of 1024 but only 64 examples fit in memory? Run 16
// *micro-batches* of 64, ADD their gradients (don't step in between), then
// take one optimizer step. Since the loss is a mean over the batch and
// gradients are linear, averaging the micro-batch gradients gives exactly
// the full-batch gradient:
//
//     grad(full batch) = (1/k) * sum over micro-batches of grad(micro-batch)
//
// (as long as every micro-batch has the same size). The cost: k forward
// and backward passes per step instead of one, so it's slower, but the
// maths is identical. (Watch out for BatchNorm, 084: its statistics are
// per micro-batch, so that part does change.)
//
// YOUR TASK: accumulate, and average.
//
const std = @import("std");

/// Gradient of mean((w*x - y)^2) over a batch, with respect to w.
fn batchGrad(w: f64, xs: []const f64, ys: []const f64) f64 {
    var g: f64 = 0;
    for (xs, ys) |x, y| g += 2 * (w * x - y) * x;
    return g / @as(f64, @floatFromInt(xs.len));
}

fn accumulatedGrad(w: f64, xs: []const f64, ys: []const f64, micro: usize) f64 {
    var total: f64 = 0;
    var k: usize = 0;
    var start: usize = 0;
    while (start < xs.len) : (start += micro) {
        ???
        k += 1;
    }
    return ???;
}

test "16 micro-batches of 4 = one batch of 64" {
    var xs: [64]f64 = undefined;
    var ys: [64]f64 = undefined;
    for (&xs, &ys, 0..) |*x, *y, i| {
        x.* = @sin(@as(f64, @floatFromInt(i)));
        y.* = 3 * x.* + @cos(@as(f64, @floatFromInt(i * 7)));
    }
    for ([_]f64{ 0, 1.5, 4 }) |w| {
        try std.testing.expectApproxEqAbs(batchGrad(w, &xs, &ys), accumulatedGrad(w, &xs, &ys, 4), 1e-12);
    }
}
