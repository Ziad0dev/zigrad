//
// ─── Exercise 035: the gradient of matmul ──────────────────────────────
//
// C = A · B, with A [M, K], B [K, N], C [M, N]:
//
//     C[i][j] = sum over k of A[i][k] * B[k][j]
//
// Say dC (the grad arriving at C) is known. What's dA?
// A[i][k] shows up in C[i][j] for EVERY j, each time multiplied by
// B[k][j]. Add up all its effects (the += rule):
//
//     dA[i][k] = sum over j of dC[i][j] * B[k][j]   =  (dC · Bᵀ)[i][k]
//
// Same reasoning for B:
//
//     dB[k][j] = sum over i of A[i][k] * dC[i][j]   =  (Aᵀ · dC)[k][j]
//
// Can't remember which goes where? Match the shapes. dA must be [M, K].
// dC is [M, N] and B is [K, N]. The only product of those two that comes
// out [M, K] is dC · Bᵀ.
//
// In tinygrad nobody writes this. matmul is reshape + expand + mul + sum
// (exercise 019), and autograd chains their four rules, which works out
// to exactly these two products.
//
// YOUR TASK: finish matmulGrad().
//
const std = @import("std");

/// out = a · b, with a [m, k] and b [k, n], both row-major.
fn matmul(a: []const f64, b: []const f64, m: usize, k: usize, n: usize, out: []f64) void {
    for (0..m) |i| {
        for (0..n) |j| {
            var acc: f64 = 0;
            for (0..k) |kk| acc += a[i * k + kk] * b[kk * n + j];
            out[i * n + j] = acc;
        }
    }
}

/// out = transpose of a, where a is [rows, cols].
fn transpose(a: []const f64, rows: usize, cols: usize, out: []f64) void {
    for (0..rows) |r| {
        for (0..cols) |c| out[c * rows + r] = a[r * cols + c];
    }
}

/// Given A [m, k], B [k, n] and dC [m, n], compute dA and dB.
fn matmulGrad(alloc: std.mem.Allocator, a: []const f64, b: []const f64, dc: []const f64, m: usize, k: usize, n: usize, da: []f64, db: []f64) !void {
    // dA = dC · Bᵀ       [m, n] · [n, k] = [m, k]
    const bt = try alloc.alloc(f64, k * n);
    defer alloc.free(bt);
    transpose(b, k, n, bt);
    matmul(dc, bt, ⟪m, n, k|||???⟫, da);

    // dB = Aᵀ · dC       [k, m] · [m, n] = [k, n]
    const at = try alloc.alloc(f64, m * k);
    defer alloc.free(at);
    ⟪transpose(a, m, k, at);|||???⟫
    ⟪matmul(at, dc, k, m, n, db);|||???⟫
}

// loss = sum of C[i][j] * R[i][j]. Its grad with respect to C is just R.
fn loss(a: []const f64, b: []const f64, r: []const f64, m: usize, k: usize, n: usize) f64 {
    var c: [16]f64 = undefined;
    matmul(a, b, m, k, n, c[0 .. m * n]);
    var total: f64 = 0;
    for (c[0 .. m * n], r) |x, y| total += x * y;
    return total;
}

test "matches measured slopes" {
    const m = 2;
    const k = 3;
    const n = 2;
    var a = [_]f64{ 1, -2, 0.5, 3, 0, -1 };
    var b = [_]f64{ 2, 1, -1, 0.5, 4, -3 };
    const r = [_]f64{ 1, -1, 2, 0.5 }; // plays the role of dC

    var da: [m * k]f64 = undefined;
    var db: [k * n]f64 = undefined;
    try matmulGrad(std.testing.allocator, &a, &b, &r, m, k, n, &da, &db);

    const h = 1e-6;
    for (&a, 0..) |*x, i| {
        const orig = x.*;
        x.* = orig + h;
        const up = loss(&a, &b, &r, m, k, n);
        x.* = orig - h;
        const down = loss(&a, &b, &r, m, k, n);
        x.* = orig;
        try std.testing.expectApproxEqAbs((up - down) / (2 * h), da[i], 1e-6);
    }
    for (&b, 0..) |*x, i| {
        const orig = x.*;
        x.* = orig + h;
        const up = loss(&a, &b, &r, m, k, n);
        x.* = orig - h;
        const down = loss(&a, &b, &r, m, k, n);
        x.* = orig;
        try std.testing.expectApproxEqAbs((up - down) / (2 * h), db[i], 1e-6);
    }
}
