// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// zig test flags: -lc
//
// ─── Exercise 206: flash attention on the GPU ─────────────────────────
//
// 095 derived flash attention on the CPU. On a GPU it's the difference
// between a transformer that fits and one that doesn't. Attention for
// one head, N tokens of dimension d:
//
//     O = softmax(Q K^T / sqrt(d)) V
//
// Naive: three kernels. Scores S = Q K^T (N x N, written to memory), a
// softmax over each row of S (read, write), then O = S V (read). At N = 4096
// that's a 64 MB matrix, written once and read twice, to compute a 1 MB
// result. Memory-bound, and quadratic in memory.
//
// Flash: ONE kernel. A WARP owns one query row: lane l holds dimensions l
// and l + 32 of q (d = 64), and of the output. The block's 8 warps share a
// tile of K and V in shared memory. For each key, every lane multiplies
// its two dimensions, and 5 shuffles (168) add them up across the warp.
// The softmax can't wait for all N scores, so it runs ONLINE, carrying:
//
//     m     the largest score so far
//     l     the sum of exp(score - m) so far
//     acc   the sum of exp(score - m) * v so far      (2 numbers per lane)
//
// and for each new score s, with v its row of V:
//
//     m_new = max(m, s)
//     scale = exp(m - m_new)        how much the old sums shrink (<= 1)
//     p     = exp(s - m_new)        the new key's weight
//     l     = l * scale + p
//     acc   = acc * scale + p * v
//
// At the end, O = acc / l. The N x N matrix never exists. (The real
// FlashAttention does the same per TILE of keys, on tensor cores.)
//
// exp is EXP2 underneath, like tinygrad's: exp(x) = exp2(x * log2(e))
// (015), and exp2 is one hardware instruction (ex2.approx in PTX).
//
// YOUR TASK: the online update (scale, l and acc), twice: in Zig, in
// onlineStep(), where a test checks it on the CPU, and then as C for the
// GPU kernel.
//
const std = @import("std");

/// How much the old sums shrink when the maximum grows from m to m_new.
const online_scale = "float scale = EXP(m - m_new);";
/// The new running sum of weights, with p = exp(s - m_new).
const online_l = "l = l * scale + p;";
/// The new running sums of weighted values, for this lane's two dimensions.
const online_acc = "acc0 = acc0 * scale + p * Vs[j][lane]; acc1 = acc1 * scale + p * Vs[j][lane + 32];";

const D = 64; // the head dimension

const kernels =
    \\#define D 64
    \\#define TILE 64
    \\#define EXP(x) __nvvm_ex2_approx_f((x) * 1.4426950408889634f)
    \\
    \\// naive 1: S[i][j] = (Q[i] . K[j]) * scale
    \\KERNEL void scores(float *S, const float *Q, const float *K, int N, float scale) {
    \\  int i = blockIdx_y * 16 + threadIdx_y, j = blockIdx_x * 16 + threadIdx_x;
    \\  float s = 0.0f;
    \\  for (int c = 0; c < D; c++) s += Q[i * D + c] * K[j * D + c];
    \\  S[(long)i * N + j] = s * scale;
    \\}
    \\
    \\// naive 2: softmax each row of S in place, one block of 256 per row
    \\KERNEL void softmax_rows(float *S, int N) {
    \\  static SHARED float sh[256];
    \\  float *row = S + (long)blockIdx_x * N;
    \\  int tid = threadIdx_x;
    \\  float m = -__builtin_inff();
    \\  for (int j = tid; j < N; j += 256) m = row[j] > m ? row[j] : m;
    \\  sh[tid] = m; __syncthreads();
    \\  for (int s = 128; s > 0; s >>= 1) { if (tid < s && sh[tid + s] > sh[tid]) sh[tid] = sh[tid + s]; __syncthreads(); }
    \\  m = sh[0]; __syncthreads();
    \\  float l = 0.0f;
    \\  for (int j = tid; j < N; j += 256) { float e = EXP(row[j] - m); row[j] = e; l += e; }
    \\  sh[tid] = l; __syncthreads();
    \\  for (int s = 128; s > 0; s >>= 1) { if (tid < s) sh[tid] += sh[tid + s]; __syncthreads(); }
    \\  l = sh[0];
    \\  for (int j = tid; j < N; j += 256) row[j] /= l;
    \\}
    \\
    \\// naive 3: O[i][c] = sum over j of P[i][j] V[j][c]
    \\KERNEL void weighted_sum(float *O, const float *P, const float *V, int N) {
    \\  int i = blockIdx_x, c = threadIdx_x;
    \\  float o = 0.0f;
    \\  for (int j = 0; j < N; j++) o += P[(long)i * N + j] * V[j * D + c];
    \\  O[i * D + c] = o;
    \\}
    \\
    \\// flash: one warp per query row; 8 rows per block share K and V tiles
    \\KERNEL void flash(float *O, const float *Q, const float *K, const float *V, int N, float sm_scale) {
    \\  static SHARED float Ks[TILE][D];
    \\  static SHARED float Vs[TILE][D];
    \\  int lane = threadIdx_x & 31, i = blockIdx_x * 8 + (threadIdx_x >> 5);
    \\  float q0 = Q[i * D + lane] * sm_scale, q1 = Q[i * D + lane + 32] * sm_scale;
    \\  float m = -__builtin_inff(), l = 0.0f, acc0 = 0.0f, acc1 = 0.0f;
    \\  for (int t0 = 0; t0 < N; t0 += TILE) {
    \\    for (int e = threadIdx_x; e < TILE * D; e += 256) {
    \\      Ks[e / D][e % D] = K[t0 * D + e];
    \\      Vs[e / D][e % D] = V[t0 * D + e];
    \\    }
    \\    __syncthreads();
    \\    for (int j = 0; j < TILE; j++) {
    \\      float s = q0 * Ks[j][lane] + q1 * Ks[j][lane + 32];
    \\      for (int o = 16; o > 0; o >>= 1) s += shfl_xor(s, o);   // every lane has the score
    \\      float m_new = m > s ? m : s;
    \\      
++ online_scale ++
    \\
    \\      float p = EXP(s - m_new);
    \\      
++ online_l ++ " " ++ online_acc ++
    \\
    \\      m = m_new;
    \\    }
    \\    __syncthreads();
    \\  }
    \\  O[i * D + lane] = acc0 / l;
    \\  O[i * D + lane + 32] = acc1 / l;
    \\}
;

/// The online update on the CPU, one score at a time: the state a warp carries.
const Online = struct { m: f32 = -std.math.inf(f32), l: f32 = 0, acc: [2]f32 = .{ 0, 0 } };

fn onlineStep(st: *Online, s: f32, v: [2]f32) void {
    const m_new = @max(st.m, s);
    const scale = @exp(st.m - m_new);
    const p = @exp(s - m_new);
    st.l = st.l * scale + p;
    for (&st.acc, v) |*a, vc| a.* = a.* * scale + p * vc;
    st.m = m_new;
}

const t = std.testing;

test "the online softmax, on the CPU" {
    // scores 1, 3, 2 with values (1, 0), (0, 1), (1, 1): one pass equals softmax-then-sum
    var st: Online = .{};
    const scores = [_]f32{ 1, 3, 2 };
    const vals = [_][2]f32{ .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } };
    for (scores, vals) |s, v| onlineStep(&st, s, v);
    var z: f32 = 0;
    var want = [2]f32{ 0, 0 };
    for (scores, vals) |s, v| {
        const e = @exp(s);
        z += e;
        want[0] += e * v[0];
        want[1] += e * v[1];
    }
    try t.expectApproxEqRel(want[0] / z, st.acc[0] / st.l, 1e-6);
    try t.expectApproxEqRel(want[1] / z, st.acc[1] / st.l, 1e-6);
}

test "naive vs flash, on the GPU" {
    const ptx = try compilePtx(t.allocator, kernels, "sm_70");
    defer t.allocator.free(ptx);
    var gpu = Gpu.open() catch return error.SkipZigTest;

    const n: u32 = 4096;
    const q = try t.allocator.alloc(f32, n * D);
    defer t.allocator.free(q);
    const k = try t.allocator.alloc(f32, n * D);
    defer t.allocator.free(k);
    const v = try t.allocator.alloc(f32, n * D);
    defer t.allocator.free(v);
    const o_naive = try t.allocator.alloc(f32, n * D);
    defer t.allocator.free(o_naive);
    const o_flash = try t.allocator.alloc(f32, n * D);
    defer t.allocator.free(o_flash);
    var prng = std.Random.DefaultPrng.init(2);
    for (q, k, v) |*a, *b, *c| {
        a.* = prng.random().floatNorm(f32);
        b.* = prng.random().floatNorm(f32);
        c.* = prng.random().floatNorm(f32);
    }
    var dq = try gpu.alloc(n * D * 4);
    defer gpu.free(dq);
    var dk = try gpu.alloc(n * D * 4);
    defer gpu.free(dk);
    var dv = try gpu.alloc(n * D * 4);
    defer gpu.free(dv);
    var do_ = try gpu.alloc(n * D * 4);
    defer gpu.free(do_);
    var ds = try gpu.alloc(@as(usize, n) * n * 4); // the N x N matrix flash never needs
    defer gpu.free(ds);
    try gpu.upload(dq, q);
    try gpu.upload(dk, k);
    try gpu.upload(dv, v);
    var size: i32 = n;
    var scale: f32 = 1.0 / @sqrt(@as(f32, D));

    // naive: three kernels, timed together
    const f_scores = try gpu.function(ptx, "scores");
    const f_softmax = try gpu.function(ptx, "softmax_rows");
    const f_sum = try gpu.function(ptx, "weighted_sum");
    const a1 = [_]?*anyopaque{ @ptrCast(&ds), @ptrCast(&dq), @ptrCast(&dk), @ptrCast(&size), @ptrCast(&scale) };
    const a2 = [_]?*anyopaque{ @ptrCast(&ds), @ptrCast(&size) };
    const a3 = [_]?*anyopaque{ @ptrCast(&do_), @ptrCast(&ds), @ptrCast(&dv), @ptrCast(&size) };
    const t1 = try gpu.time(3, f_scores, .{ n / 16, n / 16, 1 }, .{ 16, 16, 1 }, 0, &a1);
    const t2 = try gpu.time(3, f_softmax, .{ n, 1, 1 }, .{ 256, 1, 1 }, 0, &a2);
    // the softmax ran 4 times on S in place: recompute the scores and run it once
    try gpu.launch(f_scores, .{ n / 16, n / 16, 1 }, .{ 16, 16, 1 }, 0, &a1);
    try gpu.launch(f_softmax, .{ n, 1, 1 }, .{ 256, 1, 1 }, 0, &a2);
    const t3 = try gpu.time(3, f_sum, .{ n, 1, 1 }, .{ D, 1, 1 }, 0, &a3);
    try gpu.download(o_naive, do_);

    const f_flash = try gpu.function(ptx, "flash");
    const af = [_]?*anyopaque{ @ptrCast(&do_), @ptrCast(&dq), @ptrCast(&dk), @ptrCast(&dv), @ptrCast(&size), @ptrCast(&scale) };
    const tf = try gpu.time(3, f_flash, .{ n / 8, 1, 1 }, .{ 256, 1, 1 }, 0, &af);
    try gpu.download(o_flash, do_);

    // the same answer, everywhere
    for (o_naive, o_flash) |a, b| try t.expectApproxEqAbs(a, b, 1e-4);
    // and row 0 against the CPU, in f64
    var w: [4096]f64 = undefined;
    var mx: f64 = -std.math.inf(f64);
    for (0..n) |j| {
        var s: f64 = 0;
        for (0..D) |c| s += @as(f64, q[c]) * k[j * D + c];
        w[j] = s * scale;
        mx = @max(mx, w[j]);
    }
    var z: f64 = 0;
    for (&w) |*x| {
        x.* = @exp(x.* - mx);
        z += x.*;
    }
    for (0..D) |c| {
        var o: f64 = 0;
        for (0..n) |j| o += w[j] * v[j * D + c];
        try t.expectApproxEqAbs(o / z, o_flash[c], 1e-3);
    }
    std.debug.print(
        \\
        \\attention, N = {d}, d = {d}, on {s}:
        \\  naive: {d:.3} ms (scores {d:.3} + softmax {d:.3} + weighted sum {d:.3}), and a {d} MB matrix
        \\  flash: {d:.3} ms, and no matrix at all
        \\
    , .{ n, D, gpu.name(), (t1 + t2 + t3) * 1e3, t1 * 1e3, t2 * 1e3, t3 * 1e3, @as(usize, n) * n * 4 / (1 << 20), tf * 1e3 });
    try t.expect(tf < t1 + t2 + t3); // less memory traffic, less time
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
