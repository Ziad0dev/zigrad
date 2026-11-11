//
// zig test flags: -lc
//
// ─── Exercise 203: summing a billion... well, 16 million floats ───────
//
// Chapter 40: ML kernels. A reduction is the second kernel shape in deep
// learning (after elementwise): sums, means, norms, softmax's max and
// sum. On a GPU, thousands of threads each hold a piece; combining them is
// the whole problem. Three ways, from slow to fast:
//
//   1. atomics: every thread does atomic_add(out, x[i]). Correct, and all
//      16 million additions to ONE address are serialized by the memory
//      system.
//   2. a tree per block, in shared memory (078): each block of 256 threads
//      halves its partial sums 8 times, with a barrier between steps; then
//      ONE atomic per block. And before that, each thread first adds up
//      many elements on its own (a "grid-stride loop"), so there are far
//      fewer blocks than elements.
//   3. warp shuffles (168): the last 5 steps happen inside one warp of 32
//      threads, which run in lockstep: shfl_xor reads a neighbour's
//      register directly. No shared memory, no barriers. (Expect it to
//      be about as fast as the tree, not much faster: once there is one
//      atomic per block, both are limited by reading the 64 MB from
//      memory, not by the adding. The test only insists that the tree
//      beats the atomics.)
//
// Look at the sums, not just the times. Adding 16 million numbers into
// ONE f32, one at a time, loses hundreds: once the total is large, each
// small addend is rounded away (002). The tree adds numbers of similar
// size (047) and lands far closer. And atomics land in whatever order the
// hardware likes, so the last bits change from run to run. tinygrad avoids
// atomics in general for that reason: its kernels are deterministic.
//
// YOUR TASK: the tree step and the shuffle step, as C.
//
const std = @import("std");

/// One step of the shared-memory tree: s threads add in the other half.
const tree_step = ⟪"if (tid < s) sh[tid] += sh[tid + s];"|||???⟫;
/// One step of the butterfly: add the value from lane (lane XOR o).
const shuffle_step = ⟪"v += shfl_xor(v, o);"|||???⟫;

const kernels =
    \\KERNEL void sum_atomic(float *out, const float *x, int n) {
    \\  int i = blockIdx_x * blockDim_x + threadIdx_x;
    \\  if (i < n) atomic_add(out, x[i]);
    \\}
    \\
    \\KERNEL void sum_tree(float *out, const float *x, int n) {
    \\  static SHARED float sh[256];
    \\  int tid = threadIdx_x;
    \\  float v = 0.0f;
    \\  for (int i = blockIdx_x * 256 + tid; i < n; i += 256 * 1024) v += x[i];   // grid-stride
    \\  sh[tid] = v;
    \\  __syncthreads();
    \\  for (int s = 128; s > 0; s >>= 1) {
    \\
++ tree_step ++
    \\
    \\    __syncthreads();
    \\  }
    \\  if (tid == 0) atomic_add(out, sh[0]);
    \\}
    \\
    \\KERNEL void sum_shuffle(float *out, const float *x, int n) {
    \\  static SHARED float sh[256];
    \\  int tid = threadIdx_x;
    \\  float v = 0.0f;
    \\  for (int i = blockIdx_x * 256 + tid; i < n; i += 256 * 1024) v += x[i];
    \\  sh[tid] = v;
    \\  __syncthreads();
    \\  for (int s = 128; s >= 32; s >>= 1) {   // the same tree, down to one warp
    \\
++ tree_step ++
    \\
    \\    __syncthreads();
    \\  }
    \\  if (tid < 32) {
    \\    v = sh[tid];
    \\    for (int o = 16; o > 0; o >>= 1) {
    \\
++ shuffle_step ++
    \\
    \\    }
    \\    if (tid == 0) atomic_add(out, v);
    \\  }
    \\}
;

const t = std.testing;

test "three ways to sum" {
    const ptx = try compilePtx(t.allocator, kernels, "sm_70");
    defer t.allocator.free(ptx);
    var gpu = Gpu.open() catch return error.SkipZigTest;

    const n: u32 = 1 << 24;
    const host = try t.allocator.alloc(f32, n);
    defer t.allocator.free(host);
    var prng = std.Random.DefaultPrng.init(7);
    var want: f64 = 0;
    for (host) |*h| {
        h.* = prng.random().float(f32);
        want += h.*;
    }
    var dx = try gpu.alloc(n * 4);
    defer gpu.free(dx);
    var dout = try gpu.alloc(4);
    defer gpu.free(dout);
    try gpu.upload(dx, host);
    var count: i32 = n;
    const args = [_]?*anyopaque{ @ptrCast(&dout), @ptrCast(&dx), @ptrCast(&count) };

    const Way = struct { name: [:0]const u8, grid: u32 };
    const ways = [_]Way{ .{ .name = "sum_atomic", .grid = n / 256 }, .{ .name = "sum_tree", .grid = 1024 }, .{ .name = "sum_shuffle", .grid = 1024 } };
    var times: [3]f64 = undefined;
    std.debug.print("\nsumming {d} floats on {s}:\n", .{ n, gpu.name() });
    for (ways, &times) |w, *secs| {
        const f = try gpu.function(ptx, w.name);
        secs.* = try gpu.time(3, f, .{ w.grid, 1, 1 }, .{ 256, 1, 1 }, 0, &args);
        // one more launch, from zero, to check the answer
        _ = gpu.cu.cuMemsetD8_v2(dout, 0, 4);
        try gpu.launch(f, .{ w.grid, 1, 1 }, .{ 256, 1, 1 }, 0, &args);
        try gpu.sync();
        var got: [1]f32 = undefined;
        try gpu.download(&got, dout);
        try t.expectApproxEqRel(want, @as(f64, got[0]), 1e-3);
        std.debug.print("  {s:<12} {d:>8.3} ms  {d:>7.1} GB/s  (sum {d:.1}, exact {d:.1})\n", .{ w.name, secs.* * 1e3, 4.0 * @as(f64, n) / secs.* / 1e9, got[0], want });
    }
    try t.expect(times[1] < times[0]); // the tree beats 16 million atomics
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include cuda
