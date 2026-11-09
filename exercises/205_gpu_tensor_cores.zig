//
// zig test flags: -lc
//
// ─── Exercise 205: tensor cores, for real ─────────────────────────────
//
// 080 simulated a tensor core. Here is the real instruction, the one
// tinygrad's TC opt emits on NVIDIA GPUs (tinygrad/renderer/tc.py,
// cuda_sm80):
//
//     mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32
//
//     D (16x8, f32) = A (16x16, f16) . B (16x8, f16) + C (16x8, f32)
//
// ONE instruction, issued by a whole warp of 32 threads at once: 2048
// multiply-adds. No thread holds a whole matrix. Each holds a FRAGMENT, in
// registers, laid out exactly as the PTX manual says. With lane = thread
// id in the warp, g = lane / 4 and q = lane % 4:
//
//     A: 4 registers, each two f16s side by side (low half first).
//        register r holds row g + 8 * (r & 1), columns 2q + 8 * (r >> 1),
//        and the column after it.
//     B: 2 registers. register r holds column g, rows 2q + 8r and the row
//        after it.
//     C, D: 4 floats. c0, c1: row g, columns 2q, 2q+1. c2, c3: row g + 8.
//
// Get one index wrong and the answer is garbage: this layout is what
// tinygrad's tensor core descriptions encode (which thread holds which
// element), and why the TC opt is the hardest one in postrange.py.
//
// The inputs are f16 (049): half the bytes, and tensor cores multiply them
// exactly, then add in f32.
//
// YOUR TASK: which element register r of A holds, and the loop of mma's
// that walks k.
//
const std = @import("std");

/// Register r of a warp's A fragment: its row and (first) column. (g, q, r are ints in C.)
const a_row = ???;
const a_col = ???;

const kernels =
    \\#define MMA(d, a, b, c) asm volatile("mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32 " \
    \\  "{%0,%1,%2,%3}, {%4,%5,%6,%7}, {%8,%9}, {%10,%11,%12,%13};" \
    \\  : "=f"(d[0]), "=f"(d[1]), "=f"(d[2]), "=f"(d[3]) \
    \\  : "r"(a[0]), "r"(a[1]), "r"(a[2]), "r"(a[3]), "r"(b[0]), "r"(b[1]), \
    \\    "f"(c[0]), "f"(c[1]), "f"(c[2]), "f"(c[3]))
    \\
    \\// One warp: C[m0.., n0..] (16x8) += A[m0.., k0..] (16x16) . B[k0.., n0..] (16x8).
    \\static void tile(float acc[4], const unsigned short *A, const unsigned short *B, int N, int m0, int n0, int k0) {
    \\  int lane = threadIdx_x & 31, g = lane >> 2, q = lane & 3;
    \\  unsigned a[4], b[2];
    \\  for (int r = 0; r < 4; r++) {
    \\    int row = m0 +
++ a_row ++ ", col = k0 + " ++ a_col ++
    \\;
    \\    a[r] = A[row * N + col] | ((unsigned)A[row * N + col + 1] << 16);
    \\  }
    \\  for (int r = 0; r < 2; r++) {
    \\    int k = k0 + q * 2 + 8 * r;
    \\    b[r] = B[k * N + n0 + g] | ((unsigned)B[(k + 1) * N + n0 + g] << 16);
    \\  }
    \\  float d[4];
    \\  MMA(d, a, b, acc);
    \\  for (int i = 0; i < 4; i++) acc[i] = d[i];
    \\}
    \\
    \\static void store(float *C, const float acc[4], int N, int m0, int n0) {
    \\  int lane = threadIdx_x & 31, g = lane >> 2, q = lane & 3;
    \\  C[(m0 + g) * N + n0 + q * 2] = acc[0];
    \\  C[(m0 + g) * N + n0 + q * 2 + 1] = acc[1];
    \\  C[(m0 + g + 8) * N + n0 + q * 2] = acc[2];
    \\  C[(m0 + g + 8) * N + n0 + q * 2 + 1] = acc[3];
    \\}
    \\
    \\KERNEL void one_tile(float *C, const unsigned short *A, const unsigned short *B) {
    \\  float acc[4] = {0, 0, 0, 0};
    \\  tile(acc, A, B, 16, 0, 0, 0);
    \\  store(C, acc, 16, 0, 0);   // C is 16 wide here too: columns 0..7 used
    \\}
    \\
    \\// Each warp computes one 16x8 tile of C; 4 warps per block along n.
    \\KERNEL void mma_gemm(float *C, const unsigned short *A, const unsigned short *B, int N) {
    \\  int warp = threadIdx_x >> 5;
    \\  int m0 = blockIdx_y * 16, n0 = (blockIdx_x * 4 + warp) * 8;
    \\  float acc[4] = {0, 0, 0, 0};
    \\  for (int k0 = 0; k0 < N; k0 += 16)
++ walk_k ++
    \\
    \\  store(C, acc, N, m0, n0);
    \\}
;

/// The body of the k loop: one more 16-deep slice of A and B into acc.
const walk_k = ???;

const t = std.testing;

fn toHalf(x: f32) u16 {
    return @bitCast(@as(f16, @floatCast(x)));
}

fn fromHalf(x: u16) f32 {
    return @floatCast(@as(f16, @bitCast(x)));
}

test "one tile, element by element" {
    const ptx = try compilePtx(t.allocator, kernels, "sm_80");
    defer t.allocator.free(ptx);
    var gpu = Gpu.open() catch return error.SkipZigTest;
    if (gpu.attribute(75) < 8) return error.SkipZigTest; // compute capability 8.0+ for this mma
    var a: [256]u16 = undefined;
    var b: [256]u16 = undefined;
    for (&a, 0..) |*x, i| x.* = toHalf(@as(f32, @floatFromInt(@as(i32, @intCast(i % 7)) - 3)) * 0.5);
    for (&b, 0..) |*x, i| x.* = toHalf(@as(f32, @floatFromInt(@as(i32, @intCast(i % 5)) - 2)) * 0.25);
    var da = try gpu.alloc(512);
    defer gpu.free(da);
    var db = try gpu.alloc(512);
    defer gpu.free(db);
    var dc = try gpu.alloc(1024);
    defer gpu.free(dc);
    try gpu.upload(da, &a);
    try gpu.upload(db, &b);
    const f = try gpu.function(ptx, "one_tile");
    const args = [_]?*anyopaque{ @ptrCast(&dc), @ptrCast(&da), @ptrCast(&db) };
    try gpu.launch(f, .{ 1, 1, 1 }, .{ 32, 1, 1 }, 0, &args);
    try gpu.sync();
    var c: [256]f32 = undefined;
    try gpu.download(&c, dc);
    for (0..16) |i| for (0..8) |j| {
        var want: f32 = 0;
        for (0..16) |k| want += fromHalf(a[i * 16 + k]) * fromHalf(b[k * 16 + j]);
        try t.expectApproxEqAbs(want, c[i * 16 + j], 1e-3);
    };
}

test "a whole matmul on tensor cores" {
    const ptx = try compilePtx(t.allocator, kernels, "sm_80");
    defer t.allocator.free(ptx);
    var gpu = Gpu.open() catch return error.SkipZigTest;
    if (gpu.attribute(75) < 8) return error.SkipZigTest;
    const n: u32 = 2048;
    const a = try t.allocator.alloc(u16, n * n);
    defer t.allocator.free(a);
    const b = try t.allocator.alloc(u16, n * n);
    defer t.allocator.free(b);
    const c = try t.allocator.alloc(f32, n * n);
    defer t.allocator.free(c);
    var prng = std.Random.DefaultPrng.init(5);
    for (a, b) |*x, *y| {
        x.* = toHalf(prng.random().float(f32) - 0.5);
        y.* = toHalf(prng.random().float(f32) - 0.5);
    }
    var da = try gpu.alloc(n * n * 2);
    defer gpu.free(da);
    var db = try gpu.alloc(n * n * 2);
    defer gpu.free(db);
    var dc = try gpu.alloc(n * n * 4);
    defer gpu.free(dc);
    try gpu.upload(da, a);
    try gpu.upload(db, b);
    var size: i32 = n;
    const args = [_]?*anyopaque{ @ptrCast(&dc), @ptrCast(&da), @ptrCast(&db), @ptrCast(&size) };
    const f = try gpu.function(ptx, "mma_gemm");
    const secs = try gpu.time(3, f, .{ n / 32, n / 16, 1 }, .{ 128, 1, 1 }, 0, &args);
    try gpu.download(c, dc);
    var r = std.Random.DefaultPrng.init(11);
    for (0..32) |_| {
        const i = r.random().uintLessThan(usize, n);
        const j = r.random().uintLessThan(usize, n);
        var want: f64 = 0;
        for (0..n) |k| want += @as(f64, fromHalf(a[i * n + k])) * fromHalf(b[k * n + j]);
        try t.expectApproxEqAbs(want, c[i * n + j], 1e-2);
    }
    const flops = 2.0 * @as(f64, n) * n * n;
    std.debug.print("\n{d}x{d} f16 matmul on {s}'s tensor cores: {d:.3} ms, {d:.2} TFLOPS\n(about where 204's f32 kernel got: with every load straight from global\nmemory, the tensor cores mostly wait. Staging tiles in shared memory, as\n204 did, with ldmatrix and cp.async, is how fast libraries feed them.)\n", .{ n, n, gpu.name(), secs * 1e3, flops / secs * 1e-12 });
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
