// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// zig test flags: -lc
//
// ─── Exercise 203: summing a billion... well, 16 million floats ───────
//
// Chapter 40: ML kernels. A reduction is the second kernel shape in deep
// learning (after elementwise): sums, means, norms, softmax's max and
// sum. On a GPU, thousands of threads each hold a piece; combining them is
// the whole problem. Three ways, each faster than the last:
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
//      register directly. No shared memory, no barriers.
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
const tree_step = "if (tid < s) sh[tid] += sh[tid + s];";
/// One step of the butterfly: add the value from lane (lane XOR o).
const shuffle_step = "v += shfl_xor(v, o);";

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
    cuEventDestroy_v2: *const fn (?*anyopaque) callconv(.c) CUresult,
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
        defer _ = gpu.cu.cuEventDestroy_v2(start);
        try gpu.cu.check(gpu.cu.cuEventCreate(&stop, 0));
        defer _ = gpu.cu.cuEventDestroy_v2(stop);
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
