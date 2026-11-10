//
// zig test flags: -lc
//
// ─── Exercise 204: a GPU matmul, three ways ───────────────────────────
//
// The matmul is THE kernel: most of the FLOPs of every network. 202
// measured your GPU's peak; see how close three versions get.
//
//   1. naive: one thread per output, reading a row of A and a column of B
//      from global memory. Each number is read N times, by N threads.
//      Arithmetic intensity: about 1 FLOP per 4 bytes. Memory-bound.
//   2. tiled (078, 046): a block of 16x16 threads loads a 16x16 tile of A
//      and of B into SHARED memory, waits (barrier), and every thread runs
//      16 multiply-adds out of shared memory. Then the next tile. Each
//      global number is now read N/16 times.
//   3. register-blocked (155, 197): a block computes a 64x64 tile of C, and
//      each of its 256 threads computes a 4x4 block of that, holding 16
//      accumulators in registers. Per k, a thread loads 4 numbers of A
//      and 4 of B from shared memory and does 16 multiply-adds: 2 per
//      load instead of 1/2. That's the UPCAST of 197, on a GPU.
//
// Each thread of version 3 owns rows ty + 16r and columns tx + 16c
// (r, c = 0..3), not a 4x4 square, so that threads next to each other
// touch columns next to each other: coalesced stores (202), and no shared
// memory bank conflicts (154).
//
// The barriers matter twice per tile: after loading (nobody may read a tile
// that isn't fully written yet) and after computing (nobody may overwrite
// a tile someone is still reading).
//
// Version 3 still reaches only a fraction of 202's peak. The rest of the
// way: bigger tiles (128x128, 8x8 per thread), loading with float4 (four
// numbers per instruction), double buffering (load the next tile while
// computing this one), and above all tensor cores (205), which is where
// cuBLAS and tinygrad's TC opt get their speed.
//
// YOUR TASK: the tile loads, the barrier, and the register-blocked
// multiply-add, as C.
//
const std = @import("std");

/// Version 2: each thread loads one element of the A tile and one of the B tile.
const load_tiles = ⟪"As[ty][tx] = A[row * N + kt * 16 + tx]; Bs[ty][tx] = B[(kt * 16 + ty) * N + col];"|||???⟫;
/// Wait for the whole block.
const barrier = ⟪"__syncthreads();"|||???⟫;
/// Version 3: one step of the 4x4 block of multiply-adds.
const block_fma = ⟪"acc[r][c] += a[r] * b[c];"|||???⟫;

const kernels =
    \\KERNEL void naive(float *C, const float *A, const float *B, int N) {
    \\  int row = blockIdx_y * 16 + threadIdx_y, col = blockIdx_x * 16 + threadIdx_x;
    \\  float acc = 0.0f;
    \\  for (int k = 0; k < N; k++) acc += A[row * N + k] * B[k * N + col];
    \\  C[row * N + col] = acc;
    \\}
    \\
    \\KERNEL void tiled(float *C, const float *A, const float *B, int N) {
    \\  static SHARED float As[16][16];
    \\  static SHARED float Bs[16][16];
    \\  int tx = threadIdx_x, ty = threadIdx_y;
    \\  int row = blockIdx_y * 16 + ty, col = blockIdx_x * 16 + tx;
    \\  float acc = 0.0f;
    \\  for (int kt = 0; kt < N / 16; kt++) {
    \\
++ load_tiles ++ "\n    " ++ barrier ++
    \\
    \\    for (int k = 0; k < 16; k++) acc += As[ty][k] * Bs[k][tx];
    \\
++ barrier ++
    \\
    \\  }
    \\  C[row * N + col] = acc;
    \\}
    \\
    \\KERNEL void blocked(float *C, const float *A, const float *B, int N) {
    \\  static SHARED float As[16][64];   // [k][m]: A's tile, transposed
    \\  static SHARED float Bs[16][64];   // [k][n]
    \\  int tx = threadIdx_x, ty = threadIdx_y, t = ty * 16 + tx;
    \\  int m0 = blockIdx_y * 64, n0 = blockIdx_x * 64;
    \\  float acc[4][4] = {{0}};
    \\  for (int kt = 0; kt < N / 16; kt++) {
    \\    for (int e = t; e < 1024; e += 256) {
    \\      As[e % 16][e / 16] = A[(m0 + e / 16) * N + kt * 16 + e % 16];
    \\      Bs[e / 64][e % 64] = B[(kt * 16 + e / 64) * N + n0 + e % 64];
    \\    }
    \\    __syncthreads();
    \\    for (int k = 0; k < 16; k++) {
    \\      float a[4], b[4];
    \\      for (int r = 0; r < 4; r++) a[r] = As[k][ty + 16 * r];
    \\      for (int c = 0; c < 4; c++) b[c] = Bs[k][tx + 16 * c];
    \\      for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++)
++ block_fma ++
    \\
    \\    }
    \\    __syncthreads();
    \\  }
    \\  for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++)
    \\    C[(m0 + ty + 16 * r) * N + n0 + tx + 16 * c] = acc[r][c];
    \\}
;

const t = std.testing;

test "three matmuls on the GPU" {
    const ptx = try compilePtx(t.allocator, kernels, "sm_70");
    defer t.allocator.free(ptx);
    var gpu = Gpu.open() catch return error.SkipZigTest;

    const n: u32 = 2048;
    const a = try t.allocator.alloc(f32, n * n);
    defer t.allocator.free(a);
    const b = try t.allocator.alloc(f32, n * n);
    defer t.allocator.free(b);
    const c = try t.allocator.alloc(f32, n * n);
    defer t.allocator.free(c);
    var prng = std.Random.DefaultPrng.init(3);
    for (a, b) |*x, *y| {
        x.* = prng.random().float(f32) - 0.5;
        y.* = prng.random().float(f32) - 0.5;
    }
    var da = try gpu.alloc(n * n * 4);
    defer gpu.free(da);
    var db = try gpu.alloc(n * n * 4);
    defer gpu.free(db);
    var dc = try gpu.alloc(n * n * 4);
    defer gpu.free(dc);
    try gpu.upload(da, a);
    try gpu.upload(db, b);
    var size: i32 = n;
    const args = [_]?*anyopaque{ @ptrCast(&dc), @ptrCast(&da), @ptrCast(&db), @ptrCast(&size) };

    const Way = struct { name: [:0]const u8, grid: [3]u32 };
    const ways = [_]Way{
        .{ .name = "naive", .grid = .{ n / 16, n / 16, 1 } },
        .{ .name = "tiled", .grid = .{ n / 16, n / 16, 1 } },
        .{ .name = "blocked", .grid = .{ n / 64, n / 64, 1 } },
    };
    const flops = 2.0 * @as(f64, n) * n * n;
    var tflops: [3]f64 = undefined;
    std.debug.print("\n{d}x{d} matmul on {s}:\n", .{ n, n, gpu.name() });
    for (ways, &tflops) |w, *tf| {
        const f = try gpu.function(ptx, w.name);
        const secs = try gpu.time(3, f, w.grid, .{ 16, 16, 1 }, 0, &args);
        try gpu.download(c, dc);
        // spot checks against the CPU, in f64
        var r = std.Random.DefaultPrng.init(9);
        for (0..32) |_| {
            const i = r.random().uintLessThan(usize, n);
            const j = r.random().uintLessThan(usize, n);
            var want: f64 = 0;
            for (0..n) |k| want += @as(f64, a[i * n + k]) * b[k * n + j];
            try t.expectApproxEqAbs(want, c[i * n + j], 1e-3);
        }
        tf.* = flops / secs * 1e-12;
        std.debug.print("  {s:<8} {d:>8.3} ms  {d:>6.2} TFLOPS\n", .{ w.name, secs * 1e3, tf.* });
    }
    try t.expect(tflops[2] > tflops[0]); // blocking beats naive
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include cuda
