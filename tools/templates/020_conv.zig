//
// ─── Exercise 020: convolution from windows ────────────────────────────
//
// A 1D convolution slides a small kernel w along x, taking a dot product
// at each step. With a kernel of size 3:
//
//     out[i] = x[i]*w[0] + x[i+1]*w[1] + x[i+2]*w[2]
//
//     x = [1 2 3 4 5], w = [1 0 -1]  ->  out = [-2 -2 -2]
//
// (Deep learning's "convolution" doesn't flip the kernel. Mathematicians
// would call it cross-correlation. Everyone uses the name anyway.)
//
// The trick: a view can overlap itself! Look at x through shape
// [n_out, K] with strides [1, 1]:
//
//     row 0:  x[0] x[1] x[2]
//     row 1:  x[1] x[2] x[3]        every row is one window
//     row 2:  x[2] x[3] x[4]
//
// Read w through shape [n_out, K] with strides [0, 1] (every row is the
// same w, like expand). Then it's the matmul recipe again: mul
// elementwise and sum each row.
//
// With a stride of 2 (skip every other window), rows start 2 apart:
// strides [2, 1]. The number of windows is (n - K) / stride + 1.
//
// tinygrad builds conv2d the same way: pad (014), cut the input into
// windows with movement ops (its `_pool` helper), then mul + sum. A 2D
// window view just has more dimensions: [out_h, out_w, kh, kw].
//
// YOUR TASK: finish outLen() and conv1d().
//
const std = @import("std");

const View = struct {
//@include view_core
};

fn outLen(n: usize, k: usize, stride: usize) usize {
    return ⟪(n - k) / stride + 1|||???⟫;
}

fn conv1d(x: []const f32, w: []const f32, stride: usize, out: []f32, scratch: []f32) void {
    const k = w.len;
    const n_out = out.len;
    // Row i reads x[i*stride], x[i*stride + 1], ..., x[i*stride + k - 1].
    const windows = View.make(&.{ n_out, k }, &.{ ⟪int(stride), 1|||???⟫ }, 0);
    // Every row reads all of w.
    const weights = View.make(&.{ n_out, k }, &.{ ⟪0, 1|||???⟫ }, 0);
    mulViews(windows, x, weights, w, scratch);
    sumLastAxis(scratch, k, out);
}

/// out[i] = a[i] * b[i], reading a and b through views of the same shape.
fn mulViews(va: View, a: []const f32, vb: View, b: []const f32, out: []f32) void {
    var idx: [max_dims]usize = undefined;
    for (out, 0..) |*o, flat| {
        unravel(flat, va.shape[0..va.ndim], idx[0..va.ndim]);
        o.* = a[va.position(idx[0..va.ndim])] * b[vb.position(idx[0..vb.ndim])];
    }
}

fn sumLastAxis(data: []const f32, n: usize, out: []f32) void {
    for (out, 0..) |*o, r| {
        var acc: f32 = 0;
        for (data[r * n ..][0..n]) |x| acc += x;
        o.* = acc;
    }
}

//@include view_helpers

const signal = [_]f32{ 1, 2, 3, 4, 5 };

test "output length" {
    try std.testing.expectEqual(3, outLen(5, 3, 1));
    try std.testing.expectEqual(2, outLen(5, 3, 2));
    try std.testing.expectEqual(4, outLen(8, 2, 2));
}

test "edge detector" {
    var out: [3]f32 = undefined;
    var scratch: [9]f32 = undefined;
    conv1d(&signal, &.{ 1, 0, -1 }, 1, &out, &scratch);
    try std.testing.expectEqualSlices(f32, &.{ -2, -2, -2 }, &out);
}

test "moving sum" {
    var out: [3]f32 = undefined;
    var scratch: [9]f32 = undefined;
    conv1d(&signal, &.{ 1, 1, 1 }, 1, &out, &scratch);
    try std.testing.expectEqualSlices(f32, &.{ 6, 9, 12 }, &out);
}

test "stride 2" {
    var out: [2]f32 = undefined;
    var scratch: [6]f32 = undefined;
    conv1d(&signal, &.{ 1, 1, 1 }, 2, &out, &scratch);
    try std.testing.expectEqualSlices(f32, &.{ 6, 12 }, &out);
}
