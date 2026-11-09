// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// Part VI: machine learning kernels on a real GPU. Parts I-V ran every
// "GPU" exercise as a simulation on the CPU. These run on your NVIDIA GPU,
// through the same path tinygrad's CUDA backend takes
// (tinygrad/runtime/ops_cuda.py): the CUDA driver library, loaded at run
// time, with no CUDA toolkit installed. Kernels are written in C and
// compiled to PTX by `zig cc` (LLVM's NVPTX backend); the driver compiles
// PTX for whatever GPU you have. Without an NVIDIA GPU, the tests compile
// the kernels and then skip.
//
// zig test flags: -lc
// (the driver is loaded with dlopen, which needs libc: zig build passes
// -lc for you; run these by hand with `zig test -lc ...`)
//
// ─── Exercise 201: talking to the GPU ─────────────────────────────────
//
// Chapter 39: the driver. A GPU is a separate computer: its own memory, its
// own programs, a queue of work (106). The CUDA driver API is a C library,
// libcuda.so, that ships with the NVIDIA driver. Running a kernel is:
//
//     cuInit, cuDeviceGet, cuDevicePrimaryCtxRetain   find the GPU, get a context
//     cuModuleLoadData(ptx)                           compile PTX for this GPU
//     cuModuleGetFunction(module, "name")             find the kernel
//     cuMemAlloc, cuMemcpyHtoD                        put the inputs in GPU memory
//     cuLaunchKernel(f, grid, block, args)            run it
//     cuCtxSynchronize, cuMemcpyDtoH                  wait, and copy the result back
//
// cuLaunchKernel's arguments are the subtle part: `kernelParams` is an
// array of POINTERS to each argument's value. A device pointer is passed
// as a pointer to the u64 holding it. Get that wrong and the GPU reads
// garbage addresses (CUDA_ERROR_ILLEGAL_ADDRESS, if you're lucky).
//
// PTX (Parallel Thread eXecution) is NVIDIA's portable assembly: tinygrad
// renders it directly with its PTX renderer (tinygrad/renderer/ptx.py).
// Each thread computes its global index from three special registers:
// %ctaid.x (block id), %ntid.x (block size), %tid.x (thread id in block),
// exactly 077's gid = block_id * block_size + thread_id.
//
// Timing uses CUDA events: markers in the GPU's queue that record when the
// GPU reaches them (176). The difference is the kernel's own time,
// without the CPU's launch overhead (108).
//
// YOUR TASK: the grid size, the kernel's argument array, and the copies.
//
const std = @import("std");

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

const t = std.testing;

/// How many blocks of `block` threads cover n: n / block, rounded UP (077).
fn blocksFor(n: u32, block: u32) u32 {
    return (n + block - 1) / block;
}

test "rounding up" {
    try t.expectEqual(4, blocksFor(1024, 256)); // exactly 4: no spare block
    try t.expectEqual(5, blocksFor(1025, 256)); // one more thread needs one more block
    try t.expectEqual(391, blocksFor(100_000, 256));
}

/// Hand-written PTX: out[i] = a[i] + b[i], for i < n.
const vector_add_ptx =
    \\.version 7.0
    \\.target sm_52
    \\.address_size 64
    \\.visible .entry add(.param .u64 out, .param .u64 a, .param .u64 b, .param .u32 n)
    \\{
    \\  .reg .pred %p<2>; .reg .b32 %r<6>; .reg .f32 %f<4>; .reg .b64 %rd<11>;
    \\  ld.param.u64 %rd1, [out]; ld.param.u64 %rd2, [a]; ld.param.u64 %rd3, [b]; ld.param.u32 %r1, [n];
    \\  mov.u32 %r2, %ctaid.x; mov.u32 %r3, %ntid.x; mov.u32 %r4, %tid.x;
    \\  mad.lo.s32 %r5, %r2, %r3, %r4;         // gid = block * blocksize + thread
    \\  setp.ge.s32 %p1, %r5, %r1;              // past the end?
    \\  @%p1 bra DONE;
    \\  cvta.to.global.u64 %rd4, %rd1; cvta.to.global.u64 %rd5, %rd2; cvta.to.global.u64 %rd6, %rd3;
    \\  mul.wide.s32 %rd7, %r5, 4;              // byte offset: 4 bytes per float
    \\  add.s64 %rd8, %rd5, %rd7; add.s64 %rd9, %rd6, %rd7; add.s64 %rd10, %rd4, %rd7;
    \\  ld.global.f32 %f1, [%rd8]; ld.global.f32 %f2, [%rd9];
    \\  add.f32 %f3, %f1, %f2;
    \\  st.global.f32 [%rd10], %f3;
    \\DONE:
    \\  ret;
    \\}
;

test "a vector add, on the GPU" {
    var gpu = Gpu.open() catch return error.SkipZigTest;
    const n: u32 = 100_000;
    const a = try t.allocator.alloc(f32, n);
    defer t.allocator.free(a);
    const b = try t.allocator.alloc(f32, n);
    defer t.allocator.free(b);
    const out = try t.allocator.alloc(f32, n);
    defer t.allocator.free(out);
    for (a, b, 0..) |*x, *y, i| {
        x.* = @floatFromInt(i);
        y.* = 0.5;
    }
    const f = try gpu.function(vector_add_ptx, "add");
    var da = try gpu.alloc(n * 4);
    defer gpu.free(da);
    var db = try gpu.alloc(n * 4);
    defer gpu.free(db);
    var dout = try gpu.alloc(n * 4);
    defer gpu.free(dout);
    try gpu.upload(da, a);
    try gpu.upload(db, b);
    // 256 threads per block, and enough blocks to cover all n
    const block: u32 = 256;
    const blocks = blocksFor(n, block);
    var count = n;
    const args = [_]?*anyopaque{ @ptrCast(&dout), @ptrCast(&da), @ptrCast(&db), @ptrCast(&count) };
    try gpu.launch(f, .{ blocks, 1, 1 }, .{ block, 1, 1 }, 0, &args);
    try gpu.sync();
    try gpu.download(out, dout);
    for (a, out) |x, y| try t.expectEqual(x + 0.5, y);
    std.debug.print("\nran on: {s}\n", .{gpu.name()});
}

test "C to PTX with zig cc, then on the GPU" {
    // compiling needs no GPU: this part runs everywhere
    const ptx = try compilePtx(t.allocator,
        \\KERNEL void saxpy(float *y, const float *x, float a, int n) {
        \\  int i = blockIdx_x * blockDim_x + threadIdx_x;
        \\  if (i < n) y[i] = a * x[i] + y[i];
        \\}
    , "sm_70");
    defer t.allocator.free(ptx);
    try t.expect(std.mem.indexOf(u8, ptx, ".visible .entry saxpy") != null);
    try t.expect(std.mem.indexOf(u8, ptx, "%ctaid.x") != null);

    var gpu = Gpu.open() catch return error.SkipZigTest;
    const n: u32 = 4096;
    var x: [n]f32 = undefined;
    var y: [n]f32 = undefined;
    for (&x, &y, 0..) |*xi, *yi, i| {
        xi.* = @floatFromInt(i);
        yi.* = 1;
    }
    const f = try gpu.function(ptx, "saxpy");
    var dx = try gpu.alloc(n * 4);
    defer gpu.free(dx);
    var dy = try gpu.alloc(n * 4);
    defer gpu.free(dy);
    try gpu.upload(dx, &x);
    try gpu.upload(dy, &y);
    var alpha: f32 = 2;
    var count: i32 = n;
    const args = [_]?*anyopaque{ @ptrCast(&dy), @ptrCast(&dx), @ptrCast(&alpha), @ptrCast(&count) };
    const secs = try gpu.time(10, f, .{ n / 256, 1, 1 }, .{ 256, 1, 1 }, 0, &args);
    try gpu.download(&y, dy);
    // 11 launches (warm-up + 10): y = 1 + 11 * 2x
    for (x, y) |xi, yi| try t.expectEqual(1 + 22 * xi, yi);
    try t.expect(secs > 0 and secs < 0.1);
}
