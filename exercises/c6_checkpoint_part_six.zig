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
    ???;
}

/// (202) Coalescing. The 32 threads of a warp each load one f32: thread t
/// loads element t * stride of an array that starts on a sector boundary.
/// Memory is served in 32-byte sectors. How many sectors does the warp's
/// load touch? (stride >= 1; stride 0, every thread reading the same
/// float, would be 1 sector.)
fn sectorsPerWarp(stride: usize) usize {
    ???;
}

/// (205) mma.sync m16n8k16: which element of the 16x16 matrix A does the
/// LOW half of register r (0 to 3) of lane `lane` (0 to 31) hold? Returns
/// { row, column }. (The high half holds the next column.)
fn aFragment(lane: usize, r: usize) [2]usize {
    ???;
}

/// (201) A whole kernel, as C source:
///     KERNEL void relu(float *out, const float *x, int n)
/// out[i] = max(x[i], 0) for every i < n. It is launched with enough
/// blocks to cover n, so some threads have nothing to do.
const relu_kernel = ???;

/// (203) A whole kernel, as C source:
///     KERNEL void block_max(float *out, const float *x)
/// It is launched with blocks of 256 threads. Block b writes the largest
/// of ITS 256 elements, x[256 * b ..], to out[b]: a tree in shared
/// memory, with a barrier between the steps, and no atomics.
const block_max_kernel = ???;

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
