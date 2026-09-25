//
// ─── Exercise 086: the backward pass of a convolution ──────────────────
//
// With im2col, a convolution is out = W · cols. So backward is matmul's
// backward (035) plus im2col's backward:
//
//     dW    = dOut · colsᵀ             [C_out, OH*OW] · [OH*OW, C_in*K*K]
//     dCols = Wᵀ · dOut                [C_in*K*K, C_out] · [C_out, OH*OW]
//     dX    = col2im(dCols)
//
// im2col COPIED each input pixel into several columns (every window that
// covers it). By the += rule, the pixel's gradient is the SUM of the
// gradients of all its copies. So col2im is a *scatter-add*: walk cols
// exactly like im2col did, but instead of reading x into cols, ADD cols
// back into dx. Taps that hung off the edge (padding) are simply dropped
// (padding's gradient is a shrink, 034).
//
// That same operation, run forwards, is the "transposed convolution"
// used for upsampling in image generators. It's literally a convolution's
// gradient.
//
// YOUR TASK: write dW and the scatter-add in col2im().
//
const std = @import("std");

//@include conv2d

fn col2im(c: Conv2d, d_cols: []const f64, h: usize, w: usize, dx: []f64) void {
    @memset(dx, 0);
    const oh = c.outSize(h);
    const ow = c.outSize(w);
    for (0..c.cin) |ch| {
        for (0..c.k) |i| {
            for (0..c.k) |j| {
                const row = (ch * c.k + i) * c.k + j;
                for (0..oh) |oy| {
                    for (0..ow) |ox| {
                        const y = @as(isize, @intCast(oy * c.stride + i)) - @as(isize, @intCast(c.pad));
                        const xx = @as(isize, @intCast(ox * c.stride + j)) - @as(isize, @intCast(c.pad));
                        if (y < 0 or y >= h or xx < 0 or xx >= w) continue; // padding: no gradient
                        ⟪dx[(ch * h + @as(usize, @intCast(y))) * w + @as(usize, @intCast(xx))] += d_cols[row * (oh * ow) + oy * ow + ox];|||???;⟫
                    }
                }
            }
        }
    }
}

fn backward(c: Conv2d, weight: []const f64, cols: []const f64, d_out: []const f64, h: usize, w: usize, dw: []f64, d_cols: []f64, dx: []f64) void {
    const p = c.outSize(h) * c.outSize(w);
    const r = c.cin * c.k * c.k;
    // dW = dOut · colsᵀ
    for (0..c.cout) |co| {
        for (0..r) |t| {
            var acc: f64 = 0;
            for (0..p) |q| acc += ⟪d_out[co * p + q] * cols[t * p + q]|||???⟫;
            dw[co * r + t] = acc;
        }
    }
    // dCols = Wᵀ · dOut
    for (0..r) |t| {
        for (0..p) |q| {
            var acc: f64 = 0;
            for (0..c.cout) |co| acc += weight[co * r + t] * d_out[co * p + q];
            d_cols[t * p + q] = acc;
        }
    }
    col2im(c, d_cols, h, w, dx);
}

//@include gradcheck

const conv: Conv2d = .{ .cin = 2, .cout = 2, .k = 3, .stride = 2, .pad = 1 };
const img_h = 5;
const img_w = 4;
const out_h = 3; // (5 + 2 - 3) / 2 + 1
const out_w = 2; // (4 + 2 - 3) / 2 + 1

const Check = struct {
    weight: []f64,
    x: []f64,
    r: []const f64,

    fn loss(ck: Check) f64 {
        var cols: [2 * 9 * out_h * out_w]f64 = undefined;
        var out: [2 * out_h * out_w]f64 = undefined;
        conv.forward(ck.weight, ck.x, img_h, img_w, &cols, &out);
        var total: f64 = 0;
        for (out, ck.r) |a, b| total += a * b;
        return total;
    }
};

test "convolution gradients" {
    var x: [2 * img_h * img_w]f64 = undefined;
    for (&x, 0..) |*v, i| v.* = @as(f64, @floatFromInt(i % 9)) * 0.3 - 1;
    var weight: [2 * 2 * 9]f64 = undefined;
    for (&weight, 0..) |*v, i| v.* = @as(f64, @floatFromInt(i % 5)) * 0.4 - 0.8;
    var r: [2 * out_h * out_w]f64 = undefined;
    for (&r, 0..) |*v, i| v.* = @as(f64, @floatFromInt(i)) * 0.25 - 1;

    var cols: [2 * 9 * out_h * out_w]f64 = undefined;
    var out: [2 * out_h * out_w]f64 = undefined;
    conv.forward(&weight, &x, img_h, img_w, &cols, &out);

    var dw: [2 * 2 * 9]f64 = undefined;
    var d_cols: [2 * 9 * out_h * out_w]f64 = undefined;
    var dx: [2 * img_h * img_w]f64 = undefined;
    backward(conv, &weight, &cols, &r, img_h, img_w, &dw, &d_cols, &dx);

    const ck: Check = .{ .weight = &weight, .x = &x, .r = &r };
    try gradCheck(ck, &weight, &dw);
    try gradCheck(ck, &x, &dx);
}
