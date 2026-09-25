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
// windows, then mul + sum. Its movement ops can't make overlapping strides
// directly, so its `_pool` helper uses a neat trick: repeat the input K
// times, then reshape that long row into rows one element longer than
// the input, so each row starts one place further along. A 2D window
// view just has more dimensions: [out_h, out_w, kh, kw].
//
// YOUR TASK: finish outLen() and conv1d().
//
const std = @import("std");

const View = struct {
    ndim: usize,
    shape: [max_dims]usize = @splat(0),
    strides: [max_dims]isize = @splat(0),
    offset: isize = 0,

    /// A contiguous (row-major) view of `shape`. (Exercise 006.)
    fn init(shape: []const usize) View {
        var v: View = .{ .ndim = shape.len };
        var step: isize = 1;
        var i = shape.len;
        while (i > 0) {
            i -= 1;
            v.shape[i] = shape[i];
            v.strides[i] = step;
            step *= int(shape[i]);
        }
        return v;
    }

    /// A view with hand-picked strides and offset.
    fn make(shape: []const usize, strides: []const isize, offset: isize) View {
        var v: View = .{ .ndim = shape.len, .offset = offset };
        @memcpy(v.shape[0..shape.len], shape);
        @memcpy(v.strides[0..strides.len], strides);
        return v;
    }

    fn numel(v: View) usize {
        var n: usize = 1;
        for (v.shape[0..v.ndim]) |d| n *= d;
        return n;
    }

    /// Where in memory the element at `idx` lives. (Exercise 009.)
    fn position(v: View, idx: []const usize) usize {
        var pos = v.offset;
        for (idx, v.strides[0..v.ndim]) |i, s| pos += int(i) * s;
        return @intCast(pos);
    }

    /// Does this view read memory in plain row-major order?
    fn isContiguous(v: View) bool {
        const fresh = View.init(v.shape[0..v.ndim]);
        return std.mem.eql(isize, v.strides[0..v.ndim], fresh.strides[0..v.ndim]);
    }
};

fn outLen(n: usize, k: usize, stride: usize) usize {
    return ???;
}

fn conv1d(x: []const f32, w: []const f32, stride: usize, out: []f32, scratch: []f32) void {
    const k = w.len;
    const n_out = out.len;
    // Row i reads x[i*stride], x[i*stride + 1], ..., x[i*stride + k - 1].
    const windows = View.make(&.{ n_out, k }, &.{ ??? }, 0);
    // Every row reads all of w.
    const weights = View.make(&.{ n_out, k }, &.{ ??? }, 0);
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

const max_dims = 4;

/// usize -> isize, for index maths with strides.
fn int(x: usize) isize {
    return @intCast(x);
}

fn product(shape: []const usize) usize {
    var n: usize = 1;
    for (shape) |d| n *= d;
    return n;
}

/// Flat position in a contiguous `shape` -> multi-index. (Exercise 008.)
fn unravel(flat: usize, shape: []const usize, idx: []usize) void {
    var rest = flat;
    var k = shape.len;
    while (k > 0) {
        k -= 1;
        idx[k] = rest % shape[k];
        rest /= shape[k];
    }
}

/// Read a view in logical order into a fresh buffer. (Exercise 009.)
fn contiguous(v: View, data: []const f32, out: []f32) void {
    var idx: [max_dims]usize = undefined;
    for (out, 0..) |*o, flat| {
        unravel(flat, v.shape[0..v.ndim], idx[0..v.ndim]);
        o.* = data[v.position(idx[0..v.ndim])];
    }
}

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
