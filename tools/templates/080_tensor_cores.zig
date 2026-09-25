//
// ─── Exercise 080: tensor cores ────────────────────────────────────────
//
// Modern GPUs have special units for exactly one thing: multiplying small
// matrix tiles. NVIDIA calls them tensor cores, AMD matrix cores, Apple
// simdgroup matrices. One instruction does
//
//     C_tile += A_tile · B_tile       (e.g. 16x16x16: 4096 multiply-adds)
//
// with low-precision inputs (f16 or bf16, 049) and an f32 accumulator.
// They're where most of a GPU's advertised FLOPs come from: on
// datacenter GPUs, often 10x or more what the regular cores can do.
//
// Using them is tiling (046) again, with the inner tile product replaced
// by the special instruction ("mma", matrix multiply-accumulate):
//
//     for each output tile (bi, bj):
//         C = 0
//         for each bk:  C += mma(A tile (bi, bk), B tile (bk, bj))
//         store C
//
// tinygrad has a TC OptOp that rewrites a matmul-shaped kernel to use
// them, with per-GPU descriptions of each tensor core's tile shape and
// which thread holds which elements.
//
// Here the "tensor core" does 4x4x4 tiles: inputs rounded to f16,
// accumulating in f32.
//
// YOUR TASK: finish mma() and the tile loading.
//
const std = @import("std");

const T = 4;

/// The special instruction: c += a · b, on T x T tiles.
fn mma(a: *const [T][T]f16, b: *const [T][T]f16, c: *[T][T]f32, count: *usize) void {
    count.* += 1;
    for (0..T) |i| {
        for (0..T) |j| {
            var acc = c[i][j];
            for (0..T) |k| acc += ⟪@as(f32, a[i][k]) * @as(f32, b[k][j])|||???⟫;
            c[i][j] = acc;
        }
    }
}

/// a [m, k] · b [k, n], all multiples of T.
fn matmulTC(a: []const f32, b: []const f32, m: usize, k: usize, n: usize, out: []f32, count: *usize) void {
    var bi: usize = 0;
    while (bi < m) : (bi += T) {
        var bj: usize = 0;
        while (bj < n) : (bj += T) {
            var c: [T][T]f32 = @splat(@splat(0));
            var bk: usize = 0;
            while (bk < k) : (bk += T) {
                var ta: [T][T]f16 = undefined;
                var tb: [T][T]f16 = undefined;
                for (0..T) |r| {
                    for (0..T) |s| {
                        ta[r][s] = @floatCast(a[⟪(bi + r) * k + (bk + s)|||???⟫]);
                        tb[r][s] = @floatCast(b[⟪(bk + r) * n + (bj + s)|||???⟫]);
                    }
                }
                mma(&ta, &tb, &c, count);
            }
            for (0..T) |r| {
                for (0..T) |s| out[(bi + r) * n + (bj + s)] = c[r][s];
            }
        }
    }
}

test "tensor-core matmul" {
    const m = 8;
    const k = 12;
    const n = 8;
    var a: [m * k]f32 = undefined;
    var b: [k * n]f32 = undefined;
    for (&a, 0..) |*x, i| x.* = @as(f32, @floatFromInt(i % 9)) * 0.1 - 0.4;
    for (&b, 0..) |*x, i| x.* = @as(f32, @floatFromInt(i % 7)) * 0.15 - 0.45;

    var exact: [m * n]f32 = undefined;
    for (0..m) |i| {
        for (0..n) |j| {
            var acc: f32 = 0;
            for (0..k) |kk| acc += a[i * k + kk] * b[kk * n + j];
            exact[i * n + j] = acc;
        }
    }

    var out: [m * n]f32 = undefined;
    var count: usize = 0;
    matmulTC(&a, &b, m, k, n, &out, &count);
    for (exact, out) |e, o| try std.testing.expectApproxEqAbs(e, o, 5e-3); // f16 inputs: close, not exact
    try std.testing.expectEqual((m / T) * (n / T) * (k / T), count);
}
