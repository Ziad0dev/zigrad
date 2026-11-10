//
// zig test flags: -lc
//
// ─── Exercise 207: a convolution on the GPU ───────────────────────────
//
// After the matmul (204), the convolution is the kernel vision models
// spend their time in (020, 085). For one image, a 3x3 kernel, stride 1:
//
//     out[co][y][x] = sum over ci, ky, kx of
//                     in[ci][y + ky - pad][x + kx - pad] * w[co][ci][ky][kx]
//
// where a read outside the image counts as 0 (the padding, 014). Each
// side of the output is (size + 2 * pad - kernel) / stride + 1 long (020).
//
// Count the work for one output pixel, over all output channels:
// CIN * 9 inputs are needed, and each is multiplied by COUT different
// weights. So an input value is worth loading ONCE and using COUT times.
//
//   1. direct: one thread per (co, y, x). Every thread loads its CIN * 9
//      inputs and CIN * 9 weights from global memory, for one output.
//      Threads for different co, at the same pixel, load the very same
//      inputs again: 1 multiply-add per 2 loads.
//   2. channel-blocked: one thread per (y, x) computes 8 output channels
//      at once, in 8 accumulators (register blocking, 155, 197, 204). The
//      block's 8 * CIN * 9 weights sit in shared memory, loaded once per
//      block. Now each input load feeds 8 multiply-adds.
//
// The padding test is a branch inside the hot loop. tinygrad would write
// it as WHERE(valid, load, 0) (193), and a GPU prefers that too: every
// thread of a warp executes the same instructions (167), so a mask costs
// less than a branch that splits the warp.
//
// Real libraries (cuDNN) go further: Winograd and FFT variants, tensor
// cores (205), NHWC layouts. But "reuse each load across output channels,
// and stage the weights close" is the core of all of them.
//
// YOUR TASK: the output size, the padded read on the CPU and on the GPU,
// and the channel-blocked multiply-add.
//
const std = @import("std");

/// (020) How long one side of the output is.
fn outSize(size: usize, kernel: usize, pad: usize, stride: usize) usize {
    return ⟪(size + 2 * pad - kernel) / stride + 1|||???⟫;
}

const Conv = struct { cin: usize, cout: usize, h: usize, w: usize };

/// The reference, on the CPU: one output element. 3x3, stride 1, pad 1, so
/// the output is h by w. x is [cin][h][w], weights [cout][cin][3][3],
/// row-major.
fn convAt(c: Conv, x: []const f32, weights: []const f32, co: usize, y: usize, px: usize) f32 {
    var acc: f64 = 0;
    for (0..c.cin) |ci| for (0..3) |ky| for (0..3) |kx| {
        // the input pixel under this tap, PLUS ONE (usize can't go below 0):
        // 0 means "one outside, in the padding"
        const iy = y + ky;
        const ix = px + kx;
        if (⟪iy < 1 or iy > c.h or ix < 1 or ix > c.w|||???⟫) continue; // padding: adds 0
        const v = x[⟪(ci * c.h + iy - 1) * c.w + ix - 1|||???⟫];
        acc += @as(f64, v) * weights[((co * c.cin + ci) * 3 + ky) * 3 + kx];
    };
    return @floatCast(acc);
}

/// The whole output, [cout][h][w].
fn convRef(c: Conv, x: []const f32, weights: []const f32, out: []f32) void {
    for (0..c.cout) |co| for (0..c.h) |y| for (0..c.w) |px| {
        out[(co * c.h + y) * c.w + px] = convAt(c, x, weights, co, y, px);
    };
}

/// Is the input pixel (iy, ix) inside the H by W image? As C, on ints that can be -1.
const inside = ⟪"iy >= 0 && iy < H && ix >= 0 && ix < W"|||???⟫;
/// Channel-blocked: one input value v, into each of the 8 accumulators.
const block_fma = ⟪"acc[o] += v * Ws[(o * CIN + ci) * 9 + ky * 3 + kx];"|||???⟫;

const kernels =
    \\#define blockIdx_z __nvvm_read_ptx_sreg_ctaid_z()
    \\#define CIN 64
    \\#define H 128
    \\#define W 128
    \\
    \\// 1. one thread per (co, y, x)
    \\KERNEL void direct(float *out, const float *x, const float *w) {
    \\  int px = blockIdx_x * 16 + threadIdx_x, y = blockIdx_y * 16 + threadIdx_y, co = blockIdx_z;
    \\  float acc = 0.0f;
    \\  for (int ci = 0; ci < CIN; ci++)
    \\    for (int ky = 0; ky < 3; ky++)
    \\      for (int kx = 0; kx < 3; kx++) {
    \\        int iy = y + ky - 1, ix = px + kx - 1;
    \\        float v = (
++ inside ++
    \\) ? x[(ci * H + iy) * W + ix] : 0.0f;
    \\        acc += v * w[((co * CIN + ci) * 3 + ky) * 3 + kx];
    \\      }
    \\  out[(co * H + y) * W + px] = acc;
    \\}
    \\
    \\// 2. one thread per (y, x), 8 output channels each; the weights in shared memory
    \\KERNEL void blocked(float *out, const float *x, const float *w) {
    \\  static SHARED float Ws[8 * CIN * 9];
    \\  int px = blockIdx_x * 16 + threadIdx_x, y = blockIdx_y * 16 + threadIdx_y, co0 = blockIdx_z * 8;
    \\  for (int e = threadIdx_y * 16 + threadIdx_x; e < 8 * CIN * 9; e += 256) Ws[e] = w[co0 * CIN * 9 + e];
    \\  __syncthreads();
    \\  float acc[8] = {0};
    \\  for (int ci = 0; ci < CIN; ci++)
    \\    for (int ky = 0; ky < 3; ky++)
    \\      for (int kx = 0; kx < 3; kx++) {
    \\        int iy = y + ky - 1, ix = px + kx - 1;
    \\        float v = (
++ inside ++
    \\) ? x[(ci * H + iy) * W + ix] : 0.0f;   // loaded once...
    \\        for (int o = 0; o < 8; o++)
    \\
++ block_fma ++
    \\   // ...used 8 times
    \\      }
    \\  for (int o = 0; o < 8; o++) out[((co0 + o) * H + y) * W + px] = acc[o];
    \\}
;

const t = std.testing;

test "output sizes" {
    try t.expectEqual(128, outSize(128, 3, 1, 1)); // "same" padding
    try t.expectEqual(126, outSize(128, 3, 0, 1));
    try t.expectEqual(64, outSize(128, 3, 1, 2));
    try t.expectEqual(112, outSize(224, 7, 3, 2)); // ResNet's first layer
    try t.expectEqual(1, outSize(5, 5, 0, 1));
    try t.expectEqual(3, outSize(5, 1, 0, 2));
}

test "the reference, by hand" {
    // a 3x3 image of ones, a kernel of ones: each output counts the pixels its window covers
    const c: Conv = .{ .cin = 1, .cout = 1, .h = 3, .w = 3 };
    var out: [9]f32 = undefined;
    convRef(c, &(.{1} ** 9), &(.{1} ** 9), &out);
    try t.expectEqualSlices(f32, &.{ 4, 6, 4, 6, 9, 6, 4, 6, 4 }, &out);
    // a kernel that picks the pixel up and to the left: the image, shifted, zeros shifted in
    const img = [_]f32{ 1, 2, 3, 4, 5, 6 }; // 2 rows of 3
    var shifted: [6]f32 = undefined;
    convRef(.{ .cin = 1, .cout = 1, .h = 2, .w = 3 }, &img, &.{ 1, 0, 0, 0, 0, 0, 0, 0, 0 }, &shifted);
    try t.expectEqualSlices(f32, &.{ 0, 0, 0, 0, 1, 2 }, &shifted);
    // and down and to the right
    convRef(.{ .cin = 1, .cout = 1, .h = 2, .w = 3 }, &img, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 1 }, &shifted);
    try t.expectEqualSlices(f32, &.{ 5, 6, 0, 0, 0, 0 }, &shifted);
    // two input channels, two output channels: out 0 copies channel 1, out 1 adds both
    const two = [_]f32{ 1, 2, 3, 4 }; // 2 channels of 1x2
    var w2 = [_]f32{0} ** 36;
    w2[(0 * 2 + 1) * 9 + 4] = 1; // out 0, in 1, the centre tap
    w2[(1 * 2 + 0) * 9 + 4] = 1;
    w2[(1 * 2 + 1) * 9 + 4] = 1;
    var out2: [4]f32 = undefined;
    convRef(.{ .cin = 2, .cout = 2, .h = 1, .w = 2 }, &two, &w2, &out2);
    try t.expectEqualSlices(f32, &.{ 3, 4, 4, 6 }, &out2);
}

test "two convolutions on the GPU" {
    const ptx = try compilePtx(t.allocator, kernels, "sm_70");
    defer t.allocator.free(ptx);
    var gpu = Gpu.open() catch return error.SkipZigTest;

    const c: Conv = .{ .cin = 64, .cout = 64, .h = 128, .w = 128 };
    const x = try t.allocator.alloc(f32, c.cin * c.h * c.w);
    defer t.allocator.free(x);
    const w = try t.allocator.alloc(f32, c.cout * c.cin * 9);
    defer t.allocator.free(w);
    const out = try t.allocator.alloc(f32, c.cout * c.h * c.w);
    defer t.allocator.free(out);
    var prng = std.Random.DefaultPrng.init(12);
    for (x) |*v| v.* = prng.random().float(f32) - 0.5;
    for (w) |*v| v.* = prng.random().float(f32) - 0.5;

    var dx = try gpu.alloc(x.len * 4);
    defer gpu.free(dx);
    var dw = try gpu.alloc(w.len * 4);
    defer gpu.free(dw);
    var dout = try gpu.alloc(out.len * 4);
    defer gpu.free(dout);
    try gpu.upload(dx, x);
    try gpu.upload(dw, w);
    const args = [_]?*anyopaque{ @ptrCast(&dout), @ptrCast(&dx), @ptrCast(&dw) };

    const Way = struct { name: [:0]const u8, grid: [3]u32 };
    const ways = [_]Way{
        .{ .name = "direct", .grid = .{ 128 / 16, 128 / 16, 64 } },
        .{ .name = "blocked", .grid = .{ 128 / 16, 128 / 16, 64 / 8 } },
    };
    const flops = 2.0 * @as(f64, @floatFromInt(c.cout * c.h * c.w * c.cin * 9));
    var tflops: [2]f64 = undefined;
    std.debug.print("\n3x3 conv, {d} -> {d} channels, {d}x{d}, on {s}:\n", .{ c.cin, c.cout, c.h, c.w, gpu.name() });
    for (ways, &tflops) |way, *tf| {
        const f = try gpu.function(ptx, way.name);
        const secs = try gpu.time(3, f, way.grid, .{ 16, 16, 1 }, 0, &args);
        try gpu.download(out, dout);
        // spot checks against the CPU, corners and edges included
        var r = std.Random.DefaultPrng.init(13);
        for (0..64) |k| {
            const co = r.random().uintLessThan(usize, c.cout);
            const y = if (k < 8) (k & 1) * (c.h - 1) else r.random().uintLessThan(usize, c.h);
            const px = if (k < 8) ((k >> 1) & 1) * (c.w - 1) else r.random().uintLessThan(usize, c.w);
            try t.expectApproxEqAbs(convAt(c, x, w, co, y, px), out[(co * c.h + y) * c.w + px], 1e-3);
        }
        tf.* = flops / secs * 1e-12;
        std.debug.print("  {s:<8} {d:>8.3} ms  {d:>6.2} TFLOPS\n", .{ way.name, secs * 1e3, tf.* });
    }
    try t.expect(tflops[1] > tflops[0]); // reusing each load across channels wins
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include cuda
