//
// ─── Exercise 057: solving linear systems ──────────────────────────────
//
// Gradient descent takes many small steps. For some problems you can jump
// straight to the answer by solving equations. Solve A x = b:
//
//     2x + 1y = 5
//     1x + 3y = 10      ->   x = 1, y = 3
//
// *Gaussian elimination*: use row 0 to wipe x out of every row below it
// (subtract row 0 times factor = A[r][0] / A[0][0]), then use row 1 to
// wipe y out of the rows below, and so on. That leaves a triangle,
// which you solve from the bottom up ("back substitution").
//
// To avoid dividing by tiny numbers (floats again!), swap the row with the
// biggest entry into the pivot position first ("partial pivoting").
//
// The payoff: fitting a line y = w x + b by least squares has an exact
// answer, the *normal equations*:
//
//     (Xᵀ X) p = Xᵀ y       with X's rows = [x_i, 1], p = [w, b]
//
// (Set the gradient of the squared error to zero, exercise 032, and this
// is what comes out.) Same line gradient descent crawled toward, in one
// shot. Why not always do this? For n parameters it costs about n^3
// operations. A network with a million weights: 10^18. Hence gradient
// descent.
//
// YOUR TASK: finish the elimination step and the back substitution.
//
const std = @import("std");

/// Solves a x = b in place. a is [n, n] (destroyed), b becomes x.
fn solve(a: []f64, b: []f64, n: usize) void {
    for (0..n) |col| {
        // partial pivoting: bring the biggest |entry| into row `col`
        var best = col;
        for (col + 1..n) |r| {
            if (@abs(a[r * n + col]) > @abs(a[best * n + col])) best = r;
        }
        if (best != col) {
            for (0..n) |c| std.mem.swap(f64, &a[col * n + c], &a[best * n + c]);
            std.mem.swap(f64, &b[col], &b[best]);
        }
        // eliminate this column from every row below
        for (col + 1..n) |r| {
            const factor = ⟪a[r * n + col] / a[col * n + col]|||???⟫;
            for (col..n) |c| a[r * n + c] -= factor * a[col * n + c];
            ⟪b[r] -= factor * b[col];|||???;⟫
        }
    }
    // back substitution, bottom row first
    var i = n;
    while (i > 0) {
        i -= 1;
        var rest = b[i];
        for (i + 1..n) |c| rest -= ⟪a[i * n + c] * b[c]|||???⟫;
        b[i] = ⟪rest / a[i * n + i]|||???⟫;
    }
}

/// Least-squares line through the points, via the normal equations.
fn fitLine(xs: []const f64, ys: []const f64) [2]f64 {
    // Xᵀ X = | Σx²  Σx |     Xᵀ y = | Σxy |
    //        | Σx   n  |            | Σy  |
    var sxx: f64 = 0;
    var sx: f64 = 0;
    var sxy: f64 = 0;
    var sy: f64 = 0;
    for (xs, ys) |x, y| {
        sxx += x * x;
        sx += x;
        sxy += x * y;
        sy += y;
    }
    var a = [_]f64{ sxx, sx, sx, @floatFromInt(xs.len) };
    var b = [_]f64{ sxy, sy };
    solve(&a, &b, 2);
    return b;
}

test "2x2" {
    var a = [_]f64{ 2, 1, 1, 3 };
    var b = [_]f64{ 5, 10 };
    solve(&a, &b, 2);
    try std.testing.expectApproxEqAbs(1.0, b[0], 1e-12);
    try std.testing.expectApproxEqAbs(3.0, b[1], 1e-12);
}

test "3x3, needing a row swap" {
    // the first pivot is 0: without pivoting this divides by zero
    var a = [_]f64{ 0, 2, 1, 1, 1, 1, 2, 1, 3 };
    var b = [_]f64{ 7, 6, 13 }; // x = 1, y = 2, z = 3
    solve(&a, &b, 3);
    try std.testing.expectApproxEqAbs(1.0, b[0], 1e-12);
    try std.testing.expectApproxEqAbs(2.0, b[1], 1e-12);
    try std.testing.expectApproxEqAbs(3.0, b[2], 1e-12);
}

test "the exact least-squares line" {
    const wb = fitLine(&.{ 1, 2, 3, 4 }, &.{ 3, 5, 7, 9 }); // y = 2x + 1
    try std.testing.expectApproxEqAbs(2.0, wb[0], 1e-12);
    try std.testing.expectApproxEqAbs(1.0, wb[1], 1e-12);

    // noisy points: the best line isn't perfect, but it's exact to compute
    const noisy = fitLine(&.{ 0, 1, 2 }, &.{ 1, 2, 4 });
    try std.testing.expectApproxEqAbs(1.5, noisy[0], 1e-12);
    try std.testing.expectApproxEqAbs(5.0 / 6.0, noisy[1], 1e-12);
}
