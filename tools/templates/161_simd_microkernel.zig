// ═══ PART IV: performance engineering and modern models ═══════════════
//
// Parts I-III built tinygrad and the maths. Part IV sharpens the tools a
// kernel engineer uses every day: the CPU up close (31), how a GPU really
// executes (32), the blocks inside today's LLMs (33), and the arithmetic
// of measuring and planning real runs (34). It ends by assembling a whole
// transformer block.
//
// ─── Exercise 161: a SIMD matmul microkernel ──────────────────────────
//
// Chapter 31: the CPU, for real. Fast CPU matmuls (OpenBLAS, BLIS, MKL)
// are built around one tiny function, the *microkernel*. It computes a
// small block of C, say 4 rows by 8 columns, entirely in registers:
//
//     for k in 0..K:
//         a = A[0..4][k]          4 numbers, one per row
//         b = B[k][0..8]          8 numbers, ONE vector register
//         for r in 0..4:
//             C[r] += a[r] * b    one vector fused multiply-add per row
//
// That's the outer product view of matmul (059), one k at a time. Each
// step loads 4 + 8 = 12 numbers and does 32 multiply-adds: an intensity
// that keeps the math units busy (155's register blocking). The 4 rows of
// C stay in 4 vector registers the whole time and are written once, at the
// end.
//
// Zig notes:
//   * @Vector(8, f32) is a SIMD register's worth of floats. `+` and `*`
//     work lane by lane.
//   * @splat(x) fills every lane with x ("broadcast").
//   * @mulAdd(T, a, b, c) is a * b + c with ONE rounding: the hardware's
//     fused multiply-add (FMA) instruction, when the CPU has one.
//
// YOUR TASK: finish the microkernel's inner step, and store the result.
//
const std = @import("std");

const MR = 4; // rows of C per microkernel
const NR = 8; // columns of C per microkernel: one vector
const V = @Vector(NR, f32);

/// C[0..MR][0..NR] += A[0..MR][0..k] · B[0..k][0..NR].
/// a is row-major with row stride lda, b row-major with row stride ldb.
fn microkernel(k: usize, a: []const f32, lda: usize, b: []const f32, ldb: usize, c: []f32, ldc: usize) void {
    var acc: [MR]V = undefined;
    for (&acc, 0..) |*row, r| row.* = c[r * ldc ..][0..NR].*;

    for (0..k) |kk| {
        const bv: V = b[kk * ldb ..][0..NR].*;
        for (&acc, 0..) |*row, r| {
            const av: V = ⟪@splat(a[r * lda + kk])|||???⟫;
            row.* = ⟪@mulAdd(V, av, bv, row.*)|||???⟫;
        }
    }

    for (acc, 0..) |row, r| ⟪c[r * ldc ..][0..NR].* = row;|||???;⟫
}

/// Whole matmul, one MR x NR block at a time. m % MR == 0, n % NR == 0.
fn matmul(m: usize, k: usize, n: usize, a: []const f32, b: []const f32, c: []f32) void {
    @memset(c, 0);
    var i: usize = 0;
    while (i < m) : (i += MR) {
        var j: usize = 0;
        while (j < n) : (j += NR) {
            microkernel(k, a[i * k ..], k, b[j..], n, c[i * n + j ..], n);
        }
    }
}

fn naive(m: usize, k: usize, n: usize, a: []const f32, b: []const f32, c: []f32) void {
    for (0..m) |i| for (0..n) |j| {
        var s: f32 = 0;
        for (0..k) |kk| s += a[i * k + kk] * b[kk * n + j];
        c[i * n + j] = s;
    };
}

test "one microkernel call" {
    // A = [[1,2],[3,4],[5,6],[7,8]] (4x2), B = 2x8 with rows 1..8 and all 1s
    const a = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const b = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 } ++ [_]f32{1} ** 8;
    var c = [_]f32{0} ** 32;
    microkernel(2, &a, 2, &b, 8, &c, 8);
    // row 0: 1 * [1..8] + 2 * 1
    try std.testing.expectEqualSlices(f32, &.{ 3, 4, 5, 6, 7, 8, 9, 10 }, c[0..8]);
    // row 3: 7 * [1..8] + 8 * 1
    try std.testing.expectEqualSlices(f32, &.{ 15, 22, 29, 36, 43, 50, 57, 64 }, c[24..32]);
}

test "a full matmul matches the triple loop" {
    const m = 8;
    const k = 13;
    const n = 16;
    var a: [m * k]f32 = undefined;
    var b: [k * n]f32 = undefined;
    for (&a, 0..) |*x, i| x.* = @floatFromInt(@as(i32, @intCast(i % 7)) - 3);
    for (&b, 0..) |*x, i| x.* = @floatFromInt(@as(i32, @intCast(i % 5)) - 2);
    var fast: [m * n]f32 = undefined;
    var slow: [m * n]f32 = undefined;
    matmul(m, k, n, &a, &b, &fast);
    naive(m, k, n, &a, &b, &slow);
    // small integers: every product and sum is exact, so the answers match exactly
    try std.testing.expectEqualSlices(f32, &slow, &fast);
}
