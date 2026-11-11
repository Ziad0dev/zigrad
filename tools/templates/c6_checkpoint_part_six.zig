//
// zig test flags: -lc
//
// ─── Checkpoint 6: Part VI, from memory ───────────────────────────────
//
// No blanks, nothing new: three functions and two whole GPU kernels, from
// Part VI. Try each cold. If you have to look one up, read YOUR finished
// exercise (its number is in the doc comment), close it, and write it
// from memory. The kernels are C, with 201's shorthand: KERNEL, SHARED,
// blockIdx_x, blockDim_x, threadIdx_x, __syncthreads(). Two things that
// differ from CUDA proper: a SHARED array must be `static` (static SHARED
// float sh[256];, as in 203), and there is no math.h: no fmaxf, no INFINITY. Write
// x > y ? x : y, and start a maximum from the first element.
//
// YOUR TASK: write blocksFor(), sectorsPerWarp(), aFragment(), and the
// kernels `relu` and `block_max`.
//
const std = @import("std");

/// (201) How many blocks of `block` threads it takes to cover n elements.
fn blocksFor(n: u32, block: u32) u32 {
    //⟪
    return (n + block - 1) / block;
    //|||
    ???;
    //⟫
}

/// (202) Coalescing. The 32 threads of a warp each load one f32: thread t
/// loads element t * stride of an array that starts on a sector boundary.
/// Memory is served in 32-byte sectors. How many sectors does the warp's
/// load touch? (stride >= 1; stride 0, every thread reading the same
/// float, would be 1 sector.)
fn sectorsPerWarp(stride: usize) usize {
    //⟪
    // thread t reads bytes 4 * stride * t ..: a new sector every 32 bytes, at most one per thread
    return @min(32, 4 * stride);
    //|||
    ???;
    //⟫
}

/// (205) mma.sync m16n8k16: which element of the 16x16 matrix A does the
/// LOW half of register r (0 to 3) of lane `lane` (0 to 31) hold? Returns
/// { row, column }. (The high half holds the next column.)
fn aFragment(lane: usize, r: usize) [2]usize {
    //⟪
    const g = lane / 4;
    const q = lane % 4;
    return .{ g + 8 * (r & 1), 2 * q + 8 * (r >> 1) };
    //|||
    ???;
    //⟫
}

/// (201) A whole kernel, as C source:
///     KERNEL void relu(float *out, const float *x, int n)
/// out[i] = max(x[i], 0) for every i < n. It is launched with enough
/// blocks to cover n, so some threads have nothing to do.
//⟪
const relu_kernel =
    \\KERNEL void relu(float *out, const float *x, int n) {
    \\  int i = blockIdx_x * blockDim_x + threadIdx_x;
    \\  if (i < n) out[i] = x[i] > 0.0f ? x[i] : 0.0f;
    \\}
    \\
;
//|||
const relu_kernel = ???;
//⟫

/// (203) A whole kernel, as C source:
///     KERNEL void block_max(float *out, const float *x)
/// It is launched with blocks of 256 threads. Block b writes the largest
/// of ITS 256 elements, x[256 * b ..], to out[b]: a tree in shared
/// memory, with a barrier between the steps, and no atomics.
//⟪
const block_max_kernel =
    \\KERNEL void block_max(float *out, const float *x) {
    \\  static SHARED float sh[256];
    \\  int tid = threadIdx_x;
    \\  sh[tid] = x[blockIdx_x * 256 + tid];
    \\  __syncthreads();
    \\  for (int s = 128; s > 0; s >>= 1) {
    \\    if (tid < s && sh[tid + s] > sh[tid]) sh[tid] = sh[tid + s];
    \\    __syncthreads();
    \\  }
    \\  if (tid == 0) out[blockIdx_x] = sh[0];
    \\}
    \\
;
//|||
const block_max_kernel = ???;
//⟫

const t = std.testing;

test "blocks" {
    try t.expectEqual(4, blocksFor(1024, 256));
    try t.expectEqual(5, blocksFor(1025, 256));
    try t.expectEqual(1, blocksFor(1, 256));
    try t.expectEqual(391, blocksFor(100_000, 256));
}

test "sectors a warp touches" {
    try t.expectEqual(4, sectorsPerWarp(1)); //   128 bytes in a row: every byte used
    try t.expectEqual(8, sectorsPerWarp(2));
    try t.expectEqual(12, sectorsPerWarp(3));
    try t.expectEqual(32, sectorsPerWarp(8)); //  a sector each: 32 bytes moved to deliver 4
    try t.expectEqual(32, sectorsPerWarp(100)); // and it can't get worse than that
    // against counting them
    for (1..12) |stride| {
        var seen = [_]bool{false} ** 2048;
        var count: usize = 0;
        for (0..32) |lane| {
            const sector = lane * stride * 4 / 32;
            if (!seen[sector]) count += 1;
            seen[sector] = true;
        }
        try t.expectEqual(count, sectorsPerWarp(stride));
    }
}

test "the A fragment covers the matrix exactly once" {
    var seen = [_]bool{false} ** 256;
    for (0..32) |lane| for (0..4) |r| {
        const e = aFragment(lane, r);
        try t.expect(e[0] < 16 and e[1] < 15 and e[1] % 2 == 0); // a pair starts on an even column
        for (0..2) |half| {
            const at = e[0] * 16 + e[1] + half;
            try t.expect(!seen[at]);
            seen[at] = true;
        }
    };
    // the PTX manual's layout, at a few places
    try t.expectEqual([2]usize{ 0, 0 }, aFragment(0, 0));
    try t.expectEqual([2]usize{ 8, 0 }, aFragment(0, 1));
    try t.expectEqual([2]usize{ 0, 8 }, aFragment(0, 2));
    try t.expectEqual([2]usize{ 8, 8 }, aFragment(0, 3));
    try t.expectEqual([2]usize{ 1, 6 }, aFragment(7, 0)); // lane 7: g = 1, q = 3
    try t.expectEqual([2]usize{ 15, 14 }, aFragment(31, 3));
}

test "relu, on the GPU" {
    const ptx = try compilePtx(t.allocator, relu_kernel, "sm_70");
    defer t.allocator.free(ptx);
    var gpu = Gpu.open() catch return error.SkipZigTest;
    const n: u32 = 100_000; // not a multiple of the block size
    const x = try t.allocator.alloc(f32, n + 256);
    defer t.allocator.free(x);
    const out = try t.allocator.alloc(f32, n + 256);
    defer t.allocator.free(out);
    var prng = std.Random.DefaultPrng.init(21);
    for (x) |*v| v.* = prng.random().float(f32) - 0.5;
    @memset(out, -7);
    var dx = try gpu.alloc(x.len * 4);
    defer gpu.free(dx);
    var dout = try gpu.alloc(out.len * 4);
    defer gpu.free(dout);
    try gpu.upload(dx, x);
    try gpu.upload(dout, out);
    var count: i32 = n;
    const args = [_]?*anyopaque{ @ptrCast(&dout), @ptrCast(&dx), @ptrCast(&count) };
    try gpu.launch(try gpu.function(ptx, "relu"), .{ blocksFor(n, 256), 1, 1 }, .{ 256, 1, 1 }, 0, &args);
    try gpu.sync();
    try gpu.download(out, dout);
    for (x[0..n], out[0..n]) |v, o| try t.expectEqual(@max(v, 0), o);
    // the spare threads of the last block wrote nothing
    for (out[n..]) |o| try t.expectEqual(-7, o);
}

test "a max per block, on the GPU" {
    const ptx = try compilePtx(t.allocator, block_max_kernel, "sm_70");
    defer t.allocator.free(ptx);
    var gpu = Gpu.open() catch return error.SkipZigTest;
    const blocks: u32 = 1000;
    const x = try t.allocator.alloc(f32, blocks * 256);
    defer t.allocator.free(x);
    var out: [blocks]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(22);
    // every block is all negative, so a max that starts from 0 is caught
    for (x) |*v| v.* = -1 - prng.random().float(f32);
    var dx = try gpu.alloc(x.len * 4);
    defer gpu.free(dx);
    var dout = try gpu.alloc(blocks * 4);
    defer gpu.free(dout);
    try gpu.upload(dx, x);
    const args = [_]?*anyopaque{ @ptrCast(&dout), @ptrCast(&dx) };
    try gpu.launch(try gpu.function(ptx, "block_max"), .{ blocks, 1, 1 }, .{ 256, 1, 1 }, 0, &args);
    try gpu.sync();
    try gpu.download(&out, dout);
    for (out, 0..) |got, b| {
        var want = x[b * 256];
        for (x[b * 256 ..][0..256]) |v| want = @max(want, v);
        try t.expectEqual(want, got);
    }
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include cuda
