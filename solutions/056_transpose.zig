// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 056: the transpose ───────────────────────────────────────
//
// The transpose Aᵀ swaps rows and columns: Aᵀ[j][i] = A[i][j]. It kept
// showing up in backward passes (exercises 034, 035). Here's why.
//
// The defining property: for any x and y,
//
//     dot(A x, y) = dot(x, Aᵀ y)
//
// Backprop asks: "the output y = A x got gradient dy. What's dx?" By the
// chain rule dx[j] = sum over i of dy[i] * A[i][j], and that's exactly
// (Aᵀ dy)[j]. So the backward pass of "multiply by A" is "multiply by Aᵀ".
//
// And you never need to build Aᵀ in memory: just read A with the indices
// swapped. (That's a permute view, exercise 011!)
//
// Two identities worth knowing:
//     (A B)ᵀ = Bᵀ Aᵀ          (reverse the order)
//     Aᵀ A is symmetric        (it equals its own transpose)
//
// YOUR TASK: write transpose, matVec (A x) and matVecT (Aᵀ y, without
// building Aᵀ).
//
const std = @import("std");

/// out = transpose of a, where a is [rows, cols].
fn transpose(a: []const f64, rows: usize, cols: usize, out: []f64) void {
    for (0..rows) |i| {
        for (0..cols) |j| out[j * rows + i] = a[i * cols + j];
    }
}

/// out = A x, where A is [rows, cols], x has cols elements.
fn matVec(a: []const f64, rows: usize, cols: usize, x: []const f64, out: []f64) void {
    for (0..rows) |i| {
        var acc: f64 = 0;
        for (0..cols) |j| acc += a[i * cols + j] * x[j];
        out[i] = acc;
    }
}

/// out = Aᵀ y, where A is [rows, cols], y has rows elements.
fn matVecT(a: []const f64, rows: usize, cols: usize, y: []const f64, out: []f64) void {
    @memset(out, 0);
    for (0..rows) |i| {
        for (0..cols) |j| out[j] += a[i * cols + j] * y[i];
    }
}

fn matmul(a: []const f64, b: []const f64, m: usize, k: usize, n: usize, out: []f64) void {
    for (0..m) |i| {
        for (0..n) |j| {
            var acc: f64 = 0;
            for (0..k) |kk| acc += a[i * k + kk] * b[kk * n + j];
            out[i * n + j] = acc;
        }
    }
}

fn dot(a: []const f64, b: []const f64) f64 {
    var acc: f64 = 0;
    for (a, b) |x, y| acc += x * y;
    return acc;
}

const ma = [_]f64{ 1, 2, 3, 4, 5, 6 }; // [2, 3]
const mb = [_]f64{ 1, -1, 0, 2, 3, 1 }; // [3, 2]

test "transpose" {
    var t: [6]f64 = undefined;
    transpose(&ma, 2, 3, &t);
    try std.testing.expectEqualSlices(f64, &.{ 1, 4, 2, 5, 3, 6 }, &t);
}

test "dot(A x, y) == dot(x, Aᵀ y)" {
    const x = [_]f64{ 0.5, -1, 2 };
    const y = [_]f64{ 3, -2 };
    var ax: [2]f64 = undefined;
    var aty: [3]f64 = undefined;
    matVec(&ma, 2, 3, &x, &ax);
    matVecT(&ma, 2, 3, &y, &aty);
    try std.testing.expectApproxEqAbs(dot(&ax, &y), dot(&x, &aty), 1e-12);
}

test "(A B)ᵀ = Bᵀ Aᵀ" {
    var ab: [4]f64 = undefined;
    var ab_t: [4]f64 = undefined;
    matmul(&ma, &mb, 2, 3, 2, &ab);
    transpose(&ab, 2, 2, &ab_t);

    var at: [6]f64 = undefined;
    var bt: [6]f64 = undefined;
    var bt_at: [4]f64 = undefined;
    transpose(&ma, 2, 3, &at);
    transpose(&mb, 3, 2, &bt);
    matmul(&bt, &at, 2, 3, 2, &bt_at);
    try std.testing.expectEqualSlices(f64, &ab_t, &bt_at);
}

test "Aᵀ A is symmetric" {
    var at: [6]f64 = undefined;
    var ata: [9]f64 = undefined;
    transpose(&ma, 2, 3, &at);
    matmul(&at, &ma, 3, 2, 3, &ata);
    for (0..3) |i| {
        for (0..3) |j| try std.testing.expectEqual(ata[i * 3 + j], ata[j * 3 + i]);
    }
}
