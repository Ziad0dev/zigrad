//
// ─── Exercise 085: 2D convolution, the im2col way ──────────────────────
//
// Exercise 020 did a 1D convolution with an overlapping view. Images need
// 2D: a C_in-channel image [C_in, H, W], and C_out filters, each
// [C_in, K, K]. Every output pixel of every output channel is a dot
// product of one filter with the K x K window under it (across all input
// channels).
//
// Output size, with stride s and padding p on each side:
//
//     out = (size + 2p - K) / s + 1
//
// The classic trick for making it fast is *im2col*: copy every window into
// a column of a big matrix, cols [C_in*K*K, OH*OW]. Then the whole
// convolution is ONE matmul:
//
//     out [C_out, OH*OW] = weight [C_out, C_in*K*K] · cols
//
// and matmul is the thing we know how to make fast (chapter 9). Padding
// means window taps can hang off the edge of the image: those read 0
// (like the pad mask of 014).
//
// tinygrad does the same thing without copying: the "cols" matrix is a
// view (pad + windows, 014/020), and the matmul fuses with it.
//
// YOUR TASK: finish outSize() and the edge check in im2col().
//
const std = @import("std");

const Conv2d = struct {
    cin: usize,
    cout: usize,
    k: usize, //      square kernel, k x k
    stride: usize = 1,
    pad: usize = 0,

    fn outSize(c: Conv2d, size: usize) usize {
        return ???;
    }

    /// x is [cin, h, w]. cols is [cin*k*k, oh*ow]: column p holds the
    /// window that output pixel p sees, zeros where it hangs off the edge.
    fn im2col(c: Conv2d, x: []const f64, h: usize, w: usize, cols: []f64) void {
        const oh = c.outSize(h);
        const ow = c.outSize(w);
        for (0..c.cin) |ch| {
            for (0..c.k) |i| {
                for (0..c.k) |j| {
                    const row = (ch * c.k + i) * c.k + j;
                    for (0..oh) |oy| {
                        for (0..ow) |ox| {
                            // where this tap lands in the (unpadded) input
                            const y = @as(isize, @intCast(oy * c.stride + i)) - @as(isize, @intCast(c.pad));
                            const xx = @as(isize, @intCast(ox * c.stride + j)) - @as(isize, @intCast(c.pad));
                            const inside = ???;
                            cols[row * (oh * ow) + oy * ow + ox] = if (inside)
                                x[(ch * h + @as(usize, @intCast(y))) * w + @as(usize, @intCast(xx))]
                            else
                                0;
                        }
                    }
                }
            }
        }
    }

    /// weight is [cout, cin*k*k]; out is [cout, oh*ow] = weight · cols.
    fn forward(c: Conv2d, weight: []const f64, x: []const f64, h: usize, w: usize, cols: []f64, out: []f64) void {
        c.im2col(x, h, w, cols);
        const p = c.outSize(h) * c.outSize(w);
        const r = c.cin * c.k * c.k;
        for (0..c.cout) |co| {
            for (0..p) |q| {
                var acc: f64 = 0;
                for (0..r) |t| acc += weight[co * r + t] * cols[t * p + q];
                out[co * p + q] = acc;
            }
        }
    }
};

/// The obvious nested loops, to check against.
fn naiveConv(c: Conv2d, weight: []const f64, x: []const f64, h: usize, w: usize, out: []f64) void {
    const oh = c.outSize(h);
    const ow = c.outSize(w);
    for (0..c.cout) |co| {
        for (0..oh) |oy| {
            for (0..ow) |ox| {
                var acc: f64 = 0;
                for (0..c.cin) |ch| {
                    for (0..c.k) |i| {
                        for (0..c.k) |j| {
                            const y = @as(isize, @intCast(oy * c.stride + i)) - @as(isize, @intCast(c.pad));
                            const xx = @as(isize, @intCast(ox * c.stride + j)) - @as(isize, @intCast(c.pad));
                            if (y < 0 or y >= h or xx < 0 or xx >= w) continue;
                            acc += weight[((co * c.cin + ch) * c.k + i) * c.k + j] *
                                x[(ch * h + @as(usize, @intCast(y))) * w + @as(usize, @intCast(xx))];
                        }
                    }
                }
                out[(co * oh + oy) * ow + ox] = acc;
            }
        }
    }
}

test "output sizes" {
    try std.testing.expectEqual(3, (Conv2d{ .cin = 1, .cout = 1, .k = 3 }).outSize(5));
    try std.testing.expectEqual(5, (Conv2d{ .cin = 1, .cout = 1, .k = 3, .pad = 1 }).outSize(5)); // "same" padding
    try std.testing.expectEqual(3, (Conv2d{ .cin = 1, .cout = 1, .k = 3, .pad = 1, .stride = 2 }).outSize(5));
}

test "a vertical-edge detector" {
    const c: Conv2d = .{ .cin = 1, .cout = 1, .k = 3 };
    // left half dark, right half bright
    const img = [_]f64{
        0, 0, 1, 1,
        0, 0, 1, 1,
        0, 0, 1, 1,
        0, 0, 1, 1,
    };
    const edge = [_]f64{ -1, 0, 1, -1, 0, 1, -1, 0, 1 };
    var cols: [9 * 4]f64 = undefined;
    var out: [4]f64 = undefined;
    c.forward(&edge, &img, 4, 4, &cols, &out);
    try std.testing.expectEqualSlices(f64, &.{ 3, 3, 3, 3 }, &out);
}

test "im2col matches the obvious loops" {
    const c: Conv2d = .{ .cin = 2, .cout = 3, .k = 3, .stride = 2, .pad = 1 };
    var x: [2 * 5 * 6]f64 = undefined;
    for (&x, 0..) |*v, i| v.* = @as(f64, @floatFromInt(i % 11)) - 5;
    var weight: [3 * 2 * 9]f64 = undefined;
    for (&weight, 0..) |*v, i| v.* = @as(f64, @floatFromInt(i % 7)) * 0.5 - 1;

    const oh = c.outSize(5);
    const ow = c.outSize(6);
    var cols: [2 * 9 * 3 * 3]f64 = undefined;
    var fast: [3 * 3 * 3]f64 = undefined;
    var slow: [3 * 3 * 3]f64 = undefined;
    try std.testing.expectEqual(9, oh * ow);
    c.forward(&weight, &x, 5, 6, &cols, &fast);
    naiveConv(c, &weight, &x, 5, 6, &slow);
    try std.testing.expectEqualSlices(f64, &slow, &fast);
}
