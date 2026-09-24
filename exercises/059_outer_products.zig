//
// ─── Exercise 059: outer products and low rank ─────────────────────────
//
// The dot product of two vectors is a single number. The *outer product*
// goes the other way: u ⊗ v is a whole matrix, (u ⊗ v)[i][j] = u[i] * v[j].
//
//     [1, 2] ⊗ [3, 4, 5] = | 3 4  5 |
//                          | 6 8 10 |
//
// Every row is a multiple of v: it's a *rank-1* matrix, the simplest kind.
//
// A third way to see matmul (after "dot products" and "composing
// functions"): A · B is a SUM of outer products, column k of A times row
// k of B:
//
//     A · B = sum over k of A[:, k] ⊗ B[k, :]
//
// And you've seen one already: the weight gradient of a linear layer
// y = W x is dW = dy ⊗ x (exercise 035, with one example).
//
// Low rank matters in practice. A 4096 x 4096 matrix has 16.7 million
// numbers. LoRA fine-tuning freezes W and learns a small change B · A,
// with B [4096, r] and A [r, 4096] and a rank r like 8: only 65,536
// numbers to train, 256 times fewer.
//
// YOUR TASK: write outer(), matmulByOuter() and loraParams().
//
const std = @import("std");

fn outer(u: []const f64, v: []const f64, out: []f64) void {
    for (u, 0..) |x, i| {
        for (v, 0..) |y, j| out[i * v.len + j] = ???;
    }
}

/// A [m, k] · B [k, n], computed as k outer products added together.
fn matmulByOuter(a: []const f64, b: []const f64, m: usize, k: usize, n: usize, out: []f64) void {
    @memset(out, 0);
    var col: [16]f64 = undefined;
    var piece: [256]f64 = undefined;
    for (0..k) |kk| {
        // column kk of A, and row kk of B
        for (0..m) |i| col[i] = a[i * k + kk];
        const row = b[kk * n ..][0..n];
        ???
        for (out, piece[0 .. m * n]) |*o, p| ???;
    }
}

/// Trainable numbers in a rank-r update of a [rows, cols] matrix.
fn loraParams(rows: usize, cols: usize, r: usize) usize {
    return ???;
}

test "outer product" {
    var out: [6]f64 = undefined;
    outer(&.{ 1, 2 }, &.{ 3, 4, 5 }, &out);
    try std.testing.expectEqualSlices(f64, &.{ 3, 4, 5, 6, 8, 10 }, &out);
}

test "matmul is a sum of outer products" {
    const a = [_]f64{ 1, 2, 3, 4, 5, 6 };
    const b = [_]f64{ 7, 8, 9, 10, 11, 12 };
    var c: [4]f64 = undefined;
    matmulByOuter(&a, &b, 2, 3, 2, &c);
    try std.testing.expectEqualSlices(f64, &.{ 58, 64, 139, 154 }, &c); // exercise 019's answer
}

test "LoRA is tiny" {
    try std.testing.expectEqual(65536, loraParams(4096, 4096, 8));
    try std.testing.expectEqual(256, 4096 * 4096 / loraParams(4096, 4096, 8));
}
