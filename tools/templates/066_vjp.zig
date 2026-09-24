//
// ─── Exercise 066: vector-Jacobian products ────────────────────────────
//
// Here's the formal version of every backward rule you've written.
//
// A loss is one number at the end of a chain of vector functions. Going
// backwards, each layer receives v = d(loss)/d(its output), a vector, and
// must hand back d(loss)/d(its input). By the chain rule that's
//
//     vᵀ J        a *vector-Jacobian product* (VJP)
//
// Backprop never builds J: for a layer with a million inputs and outputs,
// J would have 10^12 entries. Each op just knows a shortcut for vᵀ J:
//
//   * elementwise f (J diagonal):     vᵀ J = v ⊙ f'(x)     (⊙: elementwise)
//         relu: v where x > 0, else 0
//   * y = A x (J = A):                vᵀ J = Aᵀ v          (056)
//   * y = sum(x) (J is a row of 1s):  vᵀ J = v[0] everywhere
//   * softmax p = softmax(x):
//         J = diag(p) - p pᵀ, so      vᵀ J = p ⊙ (v - dot(v, p))
//
// That last one takes a line of algebra: vᵀ diag(p) = v ⊙ p, and
// vᵀ (p pᵀ) = dot(v, p) pᵀ. Subtract, and pull out the p.
//
// The tests build the full Jacobian numerically (065) and check that your
// shortcut gives exactly vᵀ J.
//
// YOUR TASK: write the four VJPs.
//
const std = @import("std");

fn reluVjp(x: []const f64, v: []const f64, out: []f64) void {
    for (x, v, out) |xi, vi, *o| o.* = ⟪if (xi > 0) vi else 0|||???⟫;
}

/// A is [m, n]; v has m elements; out has n.
fn matVecVjp(a: []const f64, m: usize, n: usize, v: []const f64, out: []f64) void {
    @memset(out, 0);
    for (0..m) |i| {
        for (0..n) |j| out[j] += ⟪a[i * n + j] * v[i]|||???⟫;
    }
}

fn sumVjp(v0: f64, out: []f64) void {
    @memset(out, ⟪v0|||???⟫);
}

fn softmaxVjp(p: []const f64, v: []const f64, out: []f64) void {
    var vp: f64 = 0;
    for (v, p) |vi, pi| vp += vi * pi;
    for (p, v, out) |pi, vi, *o| o.* = ⟪pi * (vi - vp)|||???⟫;
}

// ─── checking against the full Jacobian ───

fn jacobian(f: *const fn ([]const f64, []f64) void, x: []const f64, m: usize, jac: []f64) void {
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
        for (0..m) |i| jac[i * n + j] = (fp[i] - fm[i]) / (2 * h);
    }
}

/// vᵀ J, the slow way.
fn vtj(v: []const f64, jac: []const f64, n: usize, out: []f64) void {
    @memset(out, 0);
    for (v, 0..) |vi, i| {
        for (0..n) |j| out[j] += vi * jac[i * n + j];
    }
}

fn relu(x: []const f64, out: []f64) void {
    for (x, out) |v, *o| o.* = @max(v, 0);
}
const mat = [_]f64{ 1, -2, 0.5, 3, 0, 1 }; // [2, 3]
fn linear(x: []const f64, out: []f64) void {
    for (0..2) |i| out[i] = mat[i * 3] * x[0] + mat[i * 3 + 1] * x[1] + mat[i * 3 + 2] * x[2];
}
fn total(x: []const f64, out: []f64) void {
    out[0] = x[0] + x[1] + x[2];
}
fn softmax(x: []const f64, out: []f64) void {
    var m: f64 = -std.math.inf(f64);
    for (x) |v| m = @max(m, v);
    var s: f64 = 0;
    for (x, out) |v, *o| {
        o.* = @exp(v - m);
        s += o.*;
    }
    for (out) |*o| o.* /= s;
}

fn expectClose(expected: []const f64, got: []const f64) !void {
    for (expected, got) |e, g| try std.testing.expectApproxEqAbs(e, g, 1e-6);
}

const point = [_]f64{ 0.5, -1.5, 2 };

test "relu" {
    const v = [_]f64{ 1, 2, 3 };
    var jac: [9]f64 = undefined;
    var slow: [3]f64 = undefined;
    var fast: [3]f64 = undefined;
    jacobian(&relu, &point, 3, &jac);
    vtj(&v, &jac, 3, &slow);
    reluVjp(&point, &v, &fast);
    try expectClose(&slow, &fast);
}

test "matrix times vector" {
    const v = [_]f64{ 0.7, -1 };
    var jac: [6]f64 = undefined;
    var slow: [3]f64 = undefined;
    var fast: [3]f64 = undefined;
    jacobian(&linear, &point, 2, &jac);
    vtj(&v, &jac, 3, &slow);
    matVecVjp(&mat, 2, 3, &v, &fast);
    try expectClose(&slow, &fast);
}

test "sum" {
    var jac: [3]f64 = undefined;
    var slow: [3]f64 = undefined;
    var fast: [3]f64 = undefined;
    jacobian(&total, &point, 1, &jac);
    vtj(&.{2.5}, &jac, 3, &slow);
    sumVjp(2.5, &fast);
    try expectClose(&slow, &fast);
}

test "softmax" {
    const v = [_]f64{ 1, -2, 0.5 };
    var p: [3]f64 = undefined;
    softmax(&point, &p);
    var jac: [9]f64 = undefined;
    var slow: [3]f64 = undefined;
    var fast: [3]f64 = undefined;
    jacobian(&softmax, &point, 3, &jac);
    vtj(&v, &jac, 3, &slow);
    softmaxVjp(&p, &v, &fast);
    try expectClose(&slow, &fast);
}
