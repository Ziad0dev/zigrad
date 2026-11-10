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
const strided_index = ???;

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
    return ???;
}

/// TFLOPS for `threads` threads doing `iters` rounds of 8 FMAs each.
fn fmaTflops(threads: usize, iters: usize, secs: f64) f64 {
    const fmas = @as(f64, @floatFromInt(threads)) * @as(f64, @floatFromInt(iters)) * 8.0;
    return ???;
}

/// FLOPs per byte where memory-bound turns compute-bound (044).
fn ridgePoint(tflops: f64, gbps: f64) f64 {
    return ???;
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
