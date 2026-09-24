// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 058: eigenvectors and the learning rate ──────────────────
//
// Most vectors change direction when a matrix hits them. Special ones
// only get stretched: A v = λ v. v is an *eigenvector* and λ (lambda)
// its *eigenvalue*, the stretch factor.
//
//     A = | 2 1 |      A [1, 1] = [3, 3] = 3 [1, 1]      λ = 3
//         | 1 2 |      A [1,-1] = [1,-1] = 1 [1,-1]      λ = 1
//
// *Power iteration* finds the biggest one: multiply any starting vector by
// A again and again (normalizing so it doesn't blow up). The biggest
// stretch wins, and the vector turns toward its eigenvector. Then
// λ = dot(v, A v) for a unit vector v (the "Rayleigh quotient").
//
// Why an ML person cares: remember exercise 032? For f = (x - 3)^2,
// gradient descent diverged when lr > 1. In general, near a minimum the
// loss curves like a bowl whose steepness in each direction is an
// eigenvalue of the *Hessian* (the matrix of second derivatives). Along
// the steepest direction, each step multiplies the error by (1 - lr * λ),
// so:
//
//     gradient descent is stable only if  lr < 2 / λmax
//
// For f = (x-3)^2 the Hessian is just [2], so lr < 1. Exactly what 032
// found by experiment.
//
// For fitting a line (w, b) with mean squared error, the Hessian is
// (2/n) Xᵀ X, with X's rows = [x_i, 1].
//
// YOUR TASK: finish powerIteration() and maxStableLr().
//
const std = @import("std");

fn matVec(a: []const f64, n: usize, x: []const f64, out: []f64) void {
    for (0..n) |i| {
        var acc: f64 = 0;
        for (0..n) |j| acc += a[i * n + j] * x[j];
        out[i] = acc;
    }
}

fn dot(a: []const f64, b: []const f64) f64 {
    var acc: f64 = 0;
    for (a, b) |x, y| acc += x * y;
    return acc;
}

/// The largest eigenvalue of the symmetric n x n matrix a (n <= 8).
fn powerIteration(a: []const f64, n: usize, steps: usize) f64 {
    var v: [8]f64 = @splat(1);
    var av: [8]f64 = undefined;
    for (0..steps) |_| {
        matVec(a, n, v[0..n], av[0..n]);
        const len = @sqrt(dot(av[0..n], av[0..n]));
        for (v[0..n], av[0..n]) |*x, y| x.* = y / len;
    }
    matVec(a, n, v[0..n], av[0..n]);
    return dot(v[0..n], av[0..n]);
}

fn maxStableLr(lambda_max: f64) f64 {
    return 2 / lambda_max;
}

/// Gradient descent on the line fit; returns the final loss.
fn descend(xs: []const f64, ys: []const f64, lr: f64, steps: usize) f64 {
    const n: f64 = @floatFromInt(xs.len);
    var w: f64 = 0;
    var b: f64 = 0;
    var loss: f64 = 0;
    for (0..steps) |_| {
        var dw: f64 = 0;
        var db: f64 = 0;
        loss = 0;
        for (xs, ys) |x, y| {
            const err = w * x + b - y;
            loss += err * err / n;
            dw += 2 * err * x / n;
            db += 2 * err / n;
        }
        w -= lr * dw;
        b -= lr * db;
    }
    return loss;
}

test "power iteration" {
    try std.testing.expectApproxEqAbs(3.0, powerIteration(&.{ 2, 1, 1, 2 }, 2, 100), 1e-9);
    try std.testing.expectApproxEqAbs(5.0, powerIteration(&.{ 5, 0, 0, 0, 1, 0, 0, 0, 2 }, 3, 200), 1e-9);
}

test "the learning rate limit, predicted" {
    const xs = [_]f64{ 1, 2, 3, 4 };
    const ys = [_]f64{ 3, 5, 7, 9 };
    // Hessian = (2/n) Xᵀ X = (2/4) | Σx² Σx | = 0.5 | 30 10 |
    //                               | Σx  n  |       | 10  4 |
    const hessian = [_]f64{ 15, 5, 5, 2 };
    const lr_max = maxStableLr(powerIteration(&hessian, 2, 200));

    try std.testing.expect(descend(&xs, &ys, 0.95 * lr_max, 2000) < 1e-6); // converges
    try std.testing.expect(descend(&xs, &ys, 1.05 * lr_max, 2000) > 1e6); //  explodes
}
