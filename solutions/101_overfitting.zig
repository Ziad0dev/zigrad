// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 101: overfitting ─────────────────────────────────────────
//
// The goal of training isn't a low loss on the training data. It's
// doing well on data the model has NEVER SEEN. A model with enough
// parameters can simply memorize the training set, noise and all, and
// then fail on anything new. That's *overfitting*.
//
// Classic demonstration: 10 noisy points from a straight line.
//   * a line (2 parameters) can't fit the noise: small errors everywhere
//   * a degree-9 polynomial (10 parameters) passes through all 10 points
//     EXACTLY: zero training error! But it wiggles wildly in between, so
//     it's terrible on new points.
//
// So we always hold out *validation* data, never trained on, and judge
// models by it. Stop training when validation loss starts rising ("early
// stopping"), and pick model sizes and settings by it.
//
// *Regularization* fights overfitting by preferring small weights.
// Adding λ |w|^2 to the loss (the L2 penalty, 098) turns the normal
// equations of 057 into ridge regression:
//
//     (XᵀX + λ I) w = Xᵀ y
//
// The polynomial can no longer use huge coefficients to hit every noisy
// point exactly, and it generalizes much better.
//
// YOUR TASK: build the polynomial features, add the ridge term, and
// compute the mean squared error.
//
const std = @import("std");

/// Solves a x = b (057, with partial pivoting). a is [n, n].
fn solve(a: []f64, b: []f64, n: usize) void {
    for (0..n) |col| {
        var best = col;
        for (col + 1..n) |r| {
            if (@abs(a[r * n + col]) > @abs(a[best * n + col])) best = r;
        }
        for (0..n) |c| std.mem.swap(f64, &a[col * n + c], &a[best * n + c]);
        std.mem.swap(f64, &b[col], &b[best]);
        for (col + 1..n) |r| {
            const f = a[r * n + col] / a[col * n + col];
            for (col..n) |c| a[r * n + c] -= f * a[col * n + c];
            b[r] -= f * b[col];
        }
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        var rest = b[i];
        for (i + 1..n) |c| rest -= a[i * n + c] * b[c];
        b[i] = rest / a[i * n + i];
    }
}

/// 1, x, x^2, ..., x^degree
fn features(x: f64, degree: usize, out: []f64) void {
    var p: f64 = 1;
    for (0..degree + 1) |k| {
        out[k] = p;
        p *= x;
    }
}

/// Least squares with an L2 penalty λ. Returns the coefficients.
fn fit(xs: []const f64, ys: []const f64, degree: usize, lambda: f64, w: []f64) void {
    const n = degree + 1;
    var xtx: [100]f64 = @splat(0);
    var xty: [10]f64 = @splat(0);
    var row: [10]f64 = undefined;
    for (xs, ys) |x, y| {
        features(x, degree, row[0..n]);
        for (0..n) |i| {
            xty[i] += row[i] * y;
            for (0..n) |j| xtx[i * n + j] += row[i] * row[j];
        }
    }
    for (0..n) |i| xtx[i * n + i] += lambda;
    solve(xtx[0 .. n * n], xty[0..n], n);
    @memcpy(w, xty[0..n]);
}

fn predict(w: []const f64, x: f64) f64 {
    var row: [10]f64 = undefined;
    features(x, w.len - 1, row[0..w.len]);
    var y: f64 = 0;
    for (w, row[0..w.len]) |a, b| y += a * b;
    return y;
}

fn mse(w: []const f64, xs: []const f64, ys: []const f64) f64 {
    var total: f64 = 0;
    for (xs, ys) |x, y| {
        const e = predict(w, x) - y;
        total += e * e;
    }
    return total / @as(f64, @floatFromInt(xs.len));
}

// y = 2x + 1, plus fixed "noise"
const train_noise = [_]f64{ 0.15, -0.2, 0.1, -0.05, 0.2, -0.15, 0.05, 0.18, -0.1, 0.12 };
const val_noise = [_]f64{ -0.1, 0.05, 0.12, -0.08, 0.02, -0.15, 0.1, -0.03, 0.07 };

test "memorizing vs learning" {
    var tx: [10]f64 = undefined;
    var ty: [10]f64 = undefined;
    for (&tx, &ty, 0..) |*x, *y, i| {
        x.* = -1 + 2 * @as(f64, @floatFromInt(i)) / 9;
        y.* = 2 * x.* + 1 + train_noise[i];
    }
    var vx: [9]f64 = undefined; // halfway between the training points
    var vy: [9]f64 = undefined;
    for (&vx, &vy, 0..) |*x, *y, i| {
        x.* = -1 + (2 * @as(f64, @floatFromInt(i)) + 1) / 9;
        y.* = 2 * x.* + 1 + val_noise[i];
    }

    var line: [2]f64 = undefined;
    var wiggly: [10]f64 = undefined;
    var ridge: [10]f64 = undefined;
    fit(&tx, &ty, 1, 0, &line);
    fit(&tx, &ty, 9, 0, &wiggly);
    fit(&tx, &ty, 9, 1e-3, &ridge);

    // the degree-9 polynomial nails the training data...
    try std.testing.expect(mse(&wiggly, &tx, &ty) < 1e-9);
    try std.testing.expect(mse(&line, &tx, &ty) > 0.01);
    // ...and does far worse on new data
    try std.testing.expect(mse(&wiggly, &vx, &vy) > 3 * mse(&line, &vx, &vy));
    // a little regularization helps a lot
    try std.testing.expect(mse(&ridge, &vx, &vy) < mse(&wiggly, &vx, &vy) / 3);
}
