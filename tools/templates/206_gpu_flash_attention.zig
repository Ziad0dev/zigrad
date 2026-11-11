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

/// How much the old sums shrink when the maximum grows from m to m_new:
/// a whole C statement that DECLARES `scale` (the next two lines use it).
const online_scale = ⟪"float scale = EXP(m - m_new);"|||???⟫;
/// The new running sum of weights, with p = exp(s - m_new).
const online_l = ⟪"l = l * scale + p;"|||???⟫;
/// The new running sums of weighted values, for this lane's two dimensions.
const online_acc = ⟪"acc0 = acc0 * scale + p * Vs[j][lane]; acc1 = acc1 * scale + p * Vs[j][lane + 32];"|||???⟫;

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
    const scale = ⟪@exp(st.m - m_new)|||???⟫;
    const p = @exp(s - m_new);
    st.l = ⟪st.l * scale + p|||???⟫;
    for (&st.acc, v) |*a, vc| a.* = ⟪a.* * scale + p * vc|||???⟫;
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

//@include cuda
