//
// ─── Exercise 065: the Jacobian ────────────────────────────────────────
//
// Chapter 13: autograd, done properly. Chapter 5 took derivatives of
// functions from one number to one number. Layers map vectors to vectors,
// f: n inputs -> m outputs. Its derivative is a whole matrix, the
// *Jacobian*:
//
//     J[i][j] = how much output i moves when input j is nudged
//             = ∂f_i / ∂x_j                      (J is m x n)
//
// Example: f(x, y) = [x * y,  x + y,  sin x]
//
//     J = | y      x |      row i: output i
//         | 1      1 |      column j: input j
//         | cos x  0 |
//
// Two important shapes:
//   * elementwise ops (relu, exp...): output i only depends on input i,
//     so J is DIAGONAL
//   * a linear map f(x) = A x: J = A, everywhere
//
// And the chain rule for vectors is a matrix product (055!):
//     J of (f after g) = J_f · J_g
//
// You can measure a Jacobian one column at a time: nudge input j both
// ways, and column j is (f(x + h e_j) - f(x - h e_j)) / 2h (026).
//
// YOUR TASK: finish jacobian().
//
const std = @import("std");

const Fn = *const fn (x: []const f64, out: []f64) void;

/// J is [m, n], row-major. n, m <= 8.
fn jacobian(f: Fn, x: []const f64, m: usize, jac: []f64) void {
    const n = x.len;
    const h = 1e-6;
    var xp: [8]f64 = undefined;
    var xm: [8]f64 = undefined;
    var fp: [8]f64 = undefined;
    var fm: [8]f64 = undefined;
    for (0..n) |j| {
        @memcpy(xp[0..n], x);
        @memcpy(xm[0..n], x);
        xp[j] += h;
        xm[j] -= h;
        f(xp[0..n], fp[0..m]);
        f(xm[0..n], fm[0..m]);
        for (0..m) |i| jac[???] = ???;
    }
}

fn example(x: []const f64, out: []f64) void {
    out[0] = x[0] * x[1];
    out[1] = x[0] + x[1];
    out[2] = @sin(x[0]);
}

fn squares(x: []const f64, out: []f64) void {
    for (x, out) |v, *o| o.* = v * v;
}

fn linear(x: []const f64, out: []f64) void {
    // A = | 1 2 3 |
    //     | 4 5 6 |
    out[0] = 1 * x[0] + 2 * x[1] + 3 * x[2];
    out[1] = 4 * x[0] + 5 * x[1] + 6 * x[2];
}

fn expectClose(expected: []const f64, got: []const f64) !void {
    for (expected, got) |e, g| try std.testing.expectApproxEqAbs(e, g, 1e-6);
}

test "the example" {
    var jac: [6]f64 = undefined;
    jacobian(&example, &.{ 2, 3 }, 3, &jac);
    try expectClose(&.{ 3, 2, 1, 1, @cos(2.0), 0 }, &jac);
}

test "elementwise ops have diagonal Jacobians" {
    var jac: [9]f64 = undefined;
    jacobian(&squares, &.{ 1, 2, 3 }, 3, &jac);
    try expectClose(&.{ 2, 0, 0, 0, 4, 0, 0, 0, 6 }, &jac);
}

test "a linear map is its own Jacobian" {
    var jac: [6]f64 = undefined;
    jacobian(&linear, &.{ 0.3, -7, 2 }, 2, &jac);
    try expectClose(&.{ 1, 2, 3, 4, 5, 6 }, &jac);
}
