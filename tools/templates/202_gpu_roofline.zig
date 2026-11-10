//
// zig test flags: -lc
//
// ─── Exercise 202: your GPU's roofline, measured ──────────────────────
//
// 044 drew a roofline from spec-sheet numbers. Measure the real ones:
//
//   * bandwidth: a copy kernel, out[i] = in[i], moves 2 * 4 bytes per
//     element (one read, one write). Bytes / seconds.
//   * compute: a kernel that never touches memory, just chains of fused
//     multiply-adds in registers. 2 FLOPs per FMA.
//   * the ridge point: peak FLOPs / bandwidth, in FLOPs per byte. A kernel
//     doing fewer FLOPs per byte than that is memory-bound: most of ML.
//
// And the rule that decides whether you get that bandwidth at all:
// COALESCING (153). A warp's 32 threads load together, and the hardware
// serves their 32 addresses with as few 32-byte "sectors" from memory as
// it can. Thread t reading element t: 128 consecutive bytes, 4 sectors,
// every byte used. Thread t reading element 8 * t: every thread lands in
// its own sector, so memory sends 32 bytes to deliver 4. The kernel
// below does exactly that, with a stride you choose.
//
// (A transposed read pattern, out[i] = in[(i % 32) * (n / 32) + i / 32],
// is much less bad than it looks on a GPU like this one: its 32 MB L2
// cache keeps each sector around until the neighbouring warps read the
// rest of it. A stride that never comes back has nowhere to hide.)
//
// That's why tinygrad maps the axis that walks memory to threadIdx.x (198).
//
// YOUR TASK: the strided index, and the formulas for bandwidth, FLOPs
// and the ridge point.
//
const std = @import("std");

/// Which element thread i reads, as C: every `stride`-th one.
const strided_index = ⟪"(long)i * stride"|||???⟫;

const kernels =
    \\KERNEL void copy(float *out, const float *in, int n, int stride) {
    \\  int i = blockIdx_x * blockDim_x + threadIdx_x;
    \\  if (i < n) out[i] = in[
++ strided_index ++
    \\];
    \\}
;

const fma_kernel =
    \\KERNEL void fmas(float *out, float b, float c, int iters) {
    \\  // 8 independent chains, so the FMA units never wait on each other
    \\  float a0 = threadIdx_x, a1 = a0 + 1, a2 = a0 + 2, a3 = a0 + 3, a4 = a0 + 4, a5 = a0 + 5, a6 = a0 + 6, a7 = a0 + 7;
    \\  for (int k = 0; k < iters; k++) {
    \\    a0 = a0 * b + c; a1 = a1 * b + c; a2 = a2 * b + c; a3 = a3 * b + c;
    \\    a4 = a4 * b + c; a5 = a5 * b + c; a6 = a6 * b + c; a7 = a7 * b + c;
    \\  }
    \\  out[blockIdx_x * blockDim_x + threadIdx_x] = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;
    \\}
;

/// GB/s for a copy of n f32s that took `secs`: one read and one write each.
fn copyBandwidth(n: usize, secs: f64) f64 {
    return ⟪2.0 * 4.0 * @as(f64, @floatFromInt(n)) / secs / 1e9|||???⟫;
}

/// TFLOPS for `threads` threads doing `iters` rounds of 8 FMAs each.
fn fmaTflops(threads: usize, iters: usize, secs: f64) f64 {
    const fmas = @as(f64, @floatFromInt(threads)) * @as(f64, @floatFromInt(iters)) * 8.0;
    return ⟪2.0 * fmas / secs / 1e12|||???⟫;
}

/// FLOPs per byte where memory-bound turns compute-bound (044).
fn ridgePoint(tflops: f64, gbps: f64) f64 {
    return ⟪tflops * 1e12 / (gbps * 1e9)|||???⟫;
}

const t = std.testing;

test "the formulas" {
    try t.expectApproxEqRel(800, copyBandwidth(1 << 27, 1.073741824e-3 * 1.25), 1e-9);
    try t.expectApproxEqRel(16.777216, fmaTflops(1 << 20, 1000, 1e-3), 1e-9);
    try t.expectApproxEqRel(50, ridgePoint(20, 400), 1e-9);
}

test "measure it" {
    const ptx = try compilePtx(t.allocator, kernels, "sm_70");
    defer t.allocator.free(ptx);
    const fptx = try compilePtx(t.allocator, fma_kernel, "sm_70");
    defer t.allocator.free(fptx);
    var gpu = Gpu.open() catch return error.SkipZigTest;

    const n: u32 = 1 << 23; // 8M floats out: 32 MB, as big as the L2 cache
    const stride: u32 = 8; //   so the strided input is 256 MB
    const host = try t.allocator.alloc(f32, n * stride);
    defer t.allocator.free(host);
    for (host, 0..) |*h, i| h.* = @floatFromInt(i);
    var din = try gpu.alloc(n * stride * 4);
    defer gpu.free(din);
    var dout = try gpu.alloc(n * 4);
    defer gpu.free(dout);
    try gpu.upload(din, host);
    var count: i32 = n;
    var step: i32 = 1;
    const args = [_]?*anyopaque{ @ptrCast(&dout), @ptrCast(&din), @ptrCast(&count), @ptrCast(&step) };
    const grid = [3]u32{ n / 256, 1, 1 };
    const block = [3]u32{ 256, 1, 1 };

    const copy = try gpu.function(ptx, "copy");
    const t_copy = try gpu.time(5, copy, grid, block, 0, &args);
    step = stride;
    const t_strided = try gpu.time(5, copy, grid, block, 0, &args);
    // the strided copy read every 8th element
    try gpu.download(host[0..n], dout);
    try t.expectEqual(@as(f32, 8), host[1]);
    try t.expectEqual(@as(f32, 8 * 1000), host[1000]);

    const fmas = try gpu.function(fptx, "fmas");
    const iters = 4096;
    var b: f32 = 0.999;
    var c: f32 = 0.001;
    var it_count: i32 = iters;
    const fargs = [_]?*anyopaque{ @ptrCast(&dout), @ptrCast(&b), @ptrCast(&c), @ptrCast(&it_count) };
    const fma_threads = 1 << 20;
    const t_fma = try gpu.time(5, fmas, .{ fma_threads / 256, 1, 1 }, block, 0, &fargs);

    const bw = copyBandwidth(n, t_copy);
    const tf = fmaTflops(fma_threads, iters, t_fma);
    std.debug.print(
        \\
        \\{s}:
        \\  copy, coalesced          {d:>8.1} GB/s
        \\  copy, reading every 8th  {d:>8.1} GB/s of useful data ({d:.1}x slower)
        \\  FMA chains               {d:>8.2} TFLOPS
        \\  ridge point              {d:>8.1} FLOPs per byte
        \\
    , .{ gpu.name(), bw, copyBandwidth(n, t_strided), t_strided / t_copy, tf, ridgePoint(tf, bw) });
    try t.expect(t_strided > 2 * t_copy); // coalescing matters, a lot
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include cuda
