// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 083: LayerNorm ───────────────────────────────────────────
//
// Deep networks train badly when activations drift to huge or tiny sizes
// (037). *Normalization* layers fix the scale as data flows through.
// LayerNorm, used in every transformer, normalizes each example (row) on
// its own:
//
//     μ  = mean of the row          σ² = variance of the row
//     x̂  = (x - μ) / sqrt(σ² + ε)  mean 0, variance 1   (ε avoids ÷0)
//     y  = γ ⊙ x̂ + β               learned scale and shift, per feature
//
// The backward pass is the classic tricky one, because μ and σ depend on
// EVERY x in the row: nudging one x moves them all. With N features and
// dx̂ = dy ⊙ γ, careful chain-ruling gives
//
//     dx = (1/σ) * ( dx̂ - mean(dx̂) - x̂ * mean(dx̂ ⊙ x̂) )
//
// Reading it: pass the gradient through the division by σ, then subtract
// the parts that would just shift the mean (mean(dx̂)) or change the
// scale (the x̂ term). Normalization "doesn't care" about those
// directions, so they're projected out of the gradient.
//
//     dγ = sum over rows of dy ⊙ x̂        dβ = sum over rows of dy
//
// YOUR TASK: finish the forward normalization and the dx formula.
//
const std = @import("std");

const eps = 1e-5;

const LayerNorm = struct {
    n: usize, // features per row
    gamma: []f64,
    beta: []f64,

    /// Also writes x̂ and 1/σ per row, which backward needs.
    fn forward(l: LayerNorm, x: []const f64, rows: usize, y: []f64, xhat: []f64, inv_std: []f64) void {
        const nf: f64 = @floatFromInt(l.n);
        for (0..rows) |r| {
            const row = x[r * l.n ..][0..l.n];
            var mu: f64 = 0;
            for (row) |v| mu += v;
            mu /= nf;
            var v2: f64 = 0;
            for (row) |v| v2 += (v - mu) * (v - mu);
            v2 /= nf;
            inv_std[r] = 1 / @sqrt(v2 + eps);
            for (0..l.n) |j| {
                xhat[r * l.n + j] = (row[j] - mu) * inv_std[r];
                y[r * l.n + j] = l.gamma[j] * xhat[r * l.n + j] + l.beta[j];
            }
        }
    }

    fn backward(l: LayerNorm, rows: usize, dy: []const f64, xhat: []const f64, inv_std: []const f64, dx: []f64, dgamma: []f64, dbeta: []f64) void {
        const nf: f64 = @floatFromInt(l.n);
        @memset(dgamma, 0);
        @memset(dbeta, 0);
        for (0..rows) |r| {
            var mean_d: f64 = 0; //    mean(dx̂)
            var mean_dx: f64 = 0; //   mean(dx̂ ⊙ x̂)
            for (0..l.n) |j| {
                const i = r * l.n + j;
                const dxh = dy[i] * l.gamma[j];
                mean_d += dxh / nf;
                mean_dx += dxh * xhat[i] / nf;
                dgamma[j] += dy[i] * xhat[i];
                dbeta[j] += dy[i];
            }
            for (0..l.n) |j| {
                const i = r * l.n + j;
                const dxh = dy[i] * l.gamma[j];
                dx[i] = inv_std[r] * (dxh - mean_d - xhat[i] * mean_dx);
            }
        }
    }
};

/// Check an analytic gradient against measured slopes (026).
/// `ctx` must have `fn loss(self) f64`, which reads `param`.
fn gradCheck(ctx: anytype, param: []f64, analytic: []const f64) !void {
    const h = 1e-6;
    for (param, analytic, 0..) |*p, g, i| {
        const orig = p.*;
        p.* = orig + h;
        const up = ctx.loss();
        p.* = orig - h;
        const down = ctx.loss();
        p.* = orig;
        const measured = (up - down) / (2 * h);
        if (@abs(measured - g) > 1e-5 * @max(1, @abs(measured))) {
            std.debug.print("gradient {d}: yours {d}, measured {d}\n", .{ i, g, measured });
            return error.WrongGradient;
        }
    }
}

const Check = struct {
    l: LayerNorm,
    x: []f64,
    r: []const f64,
    rows: usize,

    fn loss(c: Check) f64 {
        var y: [16]f64 = undefined;
        var xhat: [16]f64 = undefined;
        var inv: [4]f64 = undefined;
        const n = c.rows * c.l.n;
        c.l.forward(c.x, c.rows, y[0..n], xhat[0..n], inv[0..c.rows]);
        var total: f64 = 0;
        for (y[0..n], c.r) |a, b| total += a * b;
        return total;
    }
};

test "rows come out with mean 0, variance 1" {
    var gamma = [_]f64{ 1, 1, 1, 1 };
    var beta = [_]f64{ 0, 0, 0, 0 };
    const l: LayerNorm = .{ .n = 4, .gamma = &gamma, .beta = &beta };
    const x = [_]f64{ 1, 2, 3, 4, 100, 300, 200, 400 };
    var y: [8]f64 = undefined;
    var xhat: [8]f64 = undefined;
    var inv: [2]f64 = undefined;
    l.forward(&x, 2, &y, &xhat, &inv);
    for (0..2) |r| {
        var m: f64 = 0;
        var v: f64 = 0;
        for (y[r * 4 ..][0..4]) |a| m += a / 4;
        for (y[r * 4 ..][0..4]) |a| v += (a - m) * (a - m) / 4;
        try std.testing.expectApproxEqAbs(0.0, m, 1e-9);
        try std.testing.expectApproxEqAbs(1.0, v, 1e-3);
    }
}

test "LayerNorm gradients" {
    var gamma = [_]f64{ 1.5, -0.5, 2, 0.7 };
    var beta = [_]f64{ 0.1, 0.2, -0.3, 0 };
    var x = [_]f64{ 1, 2.5, -3, 4, 0.2, -1, 0.7, 3 };
    const r = [_]f64{ 1, -2, 0.5, 3, 2, 1, -1, 0.25 };
    const l: LayerNorm = .{ .n = 4, .gamma = &gamma, .beta = &beta };
    const c: Check = .{ .l = l, .x = &x, .r = &r, .rows = 2 };

    var y: [8]f64 = undefined;
    var xhat: [8]f64 = undefined;
    var inv: [2]f64 = undefined;
    l.forward(&x, 2, &y, &xhat, &inv);
    var dx: [8]f64 = undefined;
    var dgamma: [4]f64 = undefined;
    var dbeta: [4]f64 = undefined;
    l.backward(2, &r, &xhat, &inv, &dx, &dgamma, &dbeta);
    try gradCheck(c, &x, &dx);
    try gradCheck(c, &gamma, &dgamma);
    try gradCheck(c, &beta, &dbeta);
}
