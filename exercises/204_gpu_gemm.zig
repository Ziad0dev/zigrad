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
const load_tiles = ???;
/// Wait for the whole block.
const barrier = ???;
/// Version 3: one step of the 4x4 block of multiply-adds.
const block_fma = ???;

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

const CUresult = c_int;

/// The handful of driver functions we use, looked up by name in libcuda.so.
const Cuda = struct {
    lib: std.DynLib,
    cuInit: *const fn (c_uint) callconv(.c) CUresult,
    cuDeviceGet: *const fn (*c_int, c_int) callconv(.c) CUresult,
    cuDeviceGetName: *const fn ([*]u8, c_int, c_int) callconv(.c) CUresult,
    cuDeviceGetAttribute: *const fn (*c_int, c_int, c_int) callconv(.c) CUresult,
    cuDevicePrimaryCtxRetain: *const fn (*?*anyopaque, c_int) callconv(.c) CUresult,
    cuCtxSetCurrent: *const fn (?*anyopaque) callconv(.c) CUresult,
    cuModuleLoadData: *const fn (*?*anyopaque, [*]const u8) callconv(.c) CUresult,
    cuModuleUnload: *const fn (?*anyopaque) callconv(.c) CUresult,
    cuModuleGetFunction: *const fn (*?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) CUresult,
    cuMemAlloc_v2: *const fn (*u64, usize) callconv(.c) CUresult,
    cuMemFree_v2: *const fn (u64) callconv(.c) CUresult,
    cuMemcpyHtoD_v2: *const fn (u64, *const anyopaque, usize) callconv(.c) CUresult,
    cuMemcpyDtoH_v2: *const fn (*anyopaque, u64, usize) callconv(.c) CUresult,
    cuMemsetD8_v2: *const fn (u64, u8, usize) callconv(.c) CUresult,
    cuLaunchKernel: *const fn (?*anyopaque, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint, ?*anyopaque, ?[*]?*anyopaque, ?[*]?*anyopaque) callconv(.c) CUresult,
    cuCtxSynchronize: *const fn () callconv(.c) CUresult,
    cuEventCreate: *const fn (*?*anyopaque, c_uint) callconv(.c) CUresult,
    cuEventRecord: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) CUresult,
    cuEventSynchronize: *const fn (?*anyopaque) callconv(.c) CUresult,
    cuEventElapsedTime: *const fn (*f32, ?*anyopaque, ?*anyopaque) callconv(.c) CUresult,
    cuGetErrorString: *const fn (CUresult, *[*:0]const u8) callconv(.c) CUresult,

    fn load() !Cuda {
        // where libcuda lives: the loader's search path, NixOS, Debian/Ubuntu, WSL
        const paths = [_][]const u8{ "libcuda.so.1", "/run/opengl-driver/lib/libcuda.so.1", "/usr/lib/x86_64-linux-gnu/libcuda.so.1", "/usr/lib/wsl/lib/libcuda.so.1" };
        var lib = for (paths) |p| {
            if (std.DynLib.open(p)) |l| break l else |_| {}
        } else return error.NoCuda;
        var c: Cuda = undefined;
        c.lib = lib;
        inline for (@typeInfo(Cuda).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "lib")) continue;
            @field(c, f.name) = lib.lookup(f.type, f.name) orelse return error.NoCuda;
        }
        return c;
    }

    fn check(c: *const Cuda, r: CUresult) !void {
        if (r == 0) return;
        var s: [*:0]const u8 = undefined;
        _ = c.cuGetErrorString(r, &s);
        std.debug.print("CUDA error {d}: {s}\n", .{ r, s });
        return error.Cuda;
    }
};

/// One GPU, ready to run kernels.
const Gpu = struct {
    cu: Cuda,
    dev: c_int,
    name_buf: [128]u8 = undefined,

    /// The first GPU, or error.NoCuda if there's no NVIDIA driver here.
    fn open() !Gpu {
        var gpu: Gpu = .{ .cu = try Cuda.load(), .dev = 0 };
        const cu = &gpu.cu;
        cu.check(cu.cuInit(0)) catch return error.NoCuda;
        cu.check(cu.cuDeviceGet(&gpu.dev, 0)) catch return error.NoCuda;
        var ctx: ?*anyopaque = null;
        try cu.check(cu.cuDevicePrimaryCtxRetain(&ctx, gpu.dev));
        try cu.check(cu.cuCtxSetCurrent(ctx));
        return gpu;
    }

    fn name(gpu: *Gpu) []const u8 {
        _ = gpu.cu.cuDeviceGetName(&gpu.name_buf, gpu.name_buf.len, gpu.dev);
        return std.mem.sliceTo(&gpu.name_buf, 0);
    }

    fn attribute(gpu: *Gpu, attr: c_int) c_int {
        var v: c_int = 0;
        _ = gpu.cu.cuDeviceGetAttribute(&v, attr, gpu.dev);
        return v;
    }

    /// PTX text (null-terminated) -> a kernel, compiled by the driver for this GPU.
    fn function(gpu: *Gpu, ptx: [:0]const u8, kernel_name: [:0]const u8) !?*anyopaque {
        var module: ?*anyopaque = null;
        try gpu.cu.check(gpu.cu.cuModuleLoadData(&module, ptx.ptr));
        var f: ?*anyopaque = null;
        try gpu.cu.check(gpu.cu.cuModuleGetFunction(&f, module, kernel_name.ptr));
        return f;
    }

    fn alloc(gpu: *Gpu, bytes: usize) !u64 {
        var p: u64 = 0;
        try gpu.cu.check(gpu.cu.cuMemAlloc_v2(&p, bytes));
        return p;
    }

    fn free(gpu: *Gpu, p: u64) void {
        _ = gpu.cu.cuMemFree_v2(p);
    }

    fn upload(gpu: *Gpu, dst: u64, src: anytype) !void {
        const bytes = std.mem.sliceAsBytes(src);
        try gpu.cu.check(gpu.cu.cuMemcpyHtoD_v2(dst, bytes.ptr, bytes.len));
    }

    fn download(gpu: *Gpu, dst: anytype, src: u64) !void {
        const bytes = std.mem.sliceAsBytes(dst);
        try gpu.cu.check(gpu.cu.cuMemcpyDtoH_v2(bytes.ptr, src, bytes.len));
    }

    /// Launch f on a grid of blocks. `args` are POINTERS to the argument values.
    fn launch(gpu: *Gpu, f: ?*anyopaque, grid: [3]u32, block: [3]u32, shared_bytes: u32, args: []const ?*anyopaque) !void {
        try gpu.cu.check(gpu.cu.cuLaunchKernel(f, grid[0], grid[1], grid[2], block[0], block[1], block[2], shared_bytes, null, @constCast(args.ptr), null));
    }

    fn sync(gpu: *Gpu) !void {
        try gpu.cu.check(gpu.cu.cuCtxSynchronize());
    }

    /// The best time of `runs` launches, in seconds, measured by the GPU itself.
    fn time(gpu: *Gpu, runs: usize, f: ?*anyopaque, grid: [3]u32, block: [3]u32, shared_bytes: u32, args: []const ?*anyopaque) !f64 {
        var start: ?*anyopaque = null;
        var stop: ?*anyopaque = null;
        try gpu.cu.check(gpu.cu.cuEventCreate(&start, 0));
        try gpu.cu.check(gpu.cu.cuEventCreate(&stop, 0));
        var best: f64 = std.math.inf(f64);
        try gpu.launch(f, grid, block, shared_bytes, args); // warm up (176)
        for (0..runs) |_| {
            try gpu.cu.check(gpu.cu.cuEventRecord(start, null));
            try gpu.launch(f, grid, block, shared_bytes, args);
            try gpu.cu.check(gpu.cu.cuEventRecord(stop, null));
            try gpu.cu.check(gpu.cu.cuEventSynchronize(stop));
            var ms: f32 = 0;
            try gpu.cu.check(gpu.cu.cuEventElapsedTime(&ms, start, stop));
            best = @min(best, @as(f64, ms) * 1e-3);
        }
        return best;
    }
};

/// Shorthand for C kernels: no CUDA headers needed, clang's builtins do it.
const cuda_prelude =
    \\#define KERNEL __attribute__((nvptx_kernel))
    \\#define SHARED __attribute__((address_space(3)))
    \\#define threadIdx_x __nvvm_read_ptx_sreg_tid_x()
    \\#define threadIdx_y __nvvm_read_ptx_sreg_tid_y()
    \\#define blockIdx_x __nvvm_read_ptx_sreg_ctaid_x()
    \\#define blockIdx_y __nvvm_read_ptx_sreg_ctaid_y()
    \\#define blockDim_x __nvvm_read_ptx_sreg_ntid_x()
    \\#define __syncthreads() __nvvm_bar_sync(0)
    \\#define shfl_xor(v, m) __nvvm_shfl_sync_bfly_f32(0xffffffffu, (v), (m), 0x1f)
    \\#define atomic_add(p, v) __nvvm_atom_add_gen_f((p), (v))
    \\
;

/// Compile CUDA-style C to PTX with zig cc. The PTX is null-terminated,
/// ready for cuModuleLoadData.
fn compilePtx(gpa: std.mem.Allocator, c_source: []const u8, sm: []const u8) ![:0]const u8 {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa); // for everything but the result
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const full = try std.mem.concat(alloc, u8, &.{ cuda_prelude, c_source });
    try tmp.dir.writeFile(io, .{ .sub_path = "k.c", .data = full });
    var dir_buf: [4096]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const c_path = try std.fs.path.join(alloc, &.{ dir, "k.c" });
    const ptx_path = try std.fs.path.join(alloc, &.{ dir, "k.ptx" });
    const mcpu = try std.fmt.allocPrint(alloc, "-mcpu={s}", .{sm});
    const result = try std.process.run(alloc, io, .{
        .argv = &.{ "zig", "cc", "-target", "nvptx64-cuda-none", mcpu, "-O3", "-S", "-w", c_path, "-o", ptx_path },
    });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("zig cc failed:\n{s}\n", .{result.stderr});
        return error.CompileFailed;
    }
    const ptx = try tmp.dir.readFileAlloc(io, "k.ptx", alloc, .limited(1 << 24));
    return gpa.dupeZ(u8, ptx);
}
