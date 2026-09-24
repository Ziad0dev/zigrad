//
// ─── Exercise 067: forward mode vs reverse mode ────────────────────────
//
// There are two ways to push derivatives through a chain
// f = f3 ∘ f2 ∘ f1, whose Jacobian is J = J3 · J2 · J1:
//
//   * forward mode (dual numbers, 029) computes J u for a direction u,
//     a *Jacobian-vector product* (JVP): u -> J1 u -> J2 (J1 u) -> ...
//     One pass gives one COLUMN of information.
//
//   * reverse mode (backprop, 030) computes vᵀ J, a VJP (066):
//     vᵀ -> vᵀ J3 -> (vᵀ J3) J2 -> ...
//     One pass gives one ROW.
//
// Both are consistent: for any u and v, vᵀ (J u) = (vᵀ J) u.
//
// The full Jacobian of f: n inputs -> m outputs costs n forward passes, or
// m reverse passes. A loss has m = 1 output and n = millions of weights:
// one reverse pass versus millions of forward ones. That single fact is
// why deep learning runs on reverse mode.
//
// (Why not multiply the Jacobians out? J3 · J2 · J1 as matrices costs far
// more than pushing one vector through. Always multiply a VECTOR by a
// matrix, never matrix by matrix, when you can.)
//
// YOUR TASK: write jvp(), vjp() and passesNeeded().
//
const std = @import("std");

fn matVec(a: []const f64, m: usize, n: usize, x: []const f64, out: []f64) void {
    for (0..m) |i| {
        var acc: f64 = 0;
        for (0..n) |j| acc += a[i * n + j] * x[j];
        out[i] = acc;
    }
}

fn vecMat(v: []const f64, a: []const f64, m: usize, n: usize, out: []f64) void {
    @memset(out, 0);
    for (0..m) |i| {
        for (0..n) |j| out[j] += v[i] * a[i * n + j];
    }
}

// A chain: f1: 3 -> 4, f2: 4 -> 2, f3: 2 -> 1
const j1 = [_]f64{ 1, 0, 2, -1, 1, 0, 0, 3, 1, 2, 2, 0 }; // [4, 3]
const j2 = [_]f64{ 1, 2, 0, -1, 0.5, 0, 1, 1 }; //         [2, 4]
const j3 = [_]f64{ 3, -2 }; //                             [1, 2]

/// J u, through the chain: J3 (J2 (J1 u)).
fn jvp(u: []const f64, out: []f64) void {
    var a: [4]f64 = undefined;
    var b: [2]f64 = undefined;
    matVec(&j1, 4, 3, u, &a);
    ⟪matVec(&j2, 2, 4, &a, &b);|||???⟫
    ⟪matVec(&j3, 1, 2, &b, out);|||???⟫
}

/// vᵀ J, through the chain backwards: ((vᵀ J3) J2) J1.
fn vjp(v: []const f64, out: []f64) void {
    var a: [2]f64 = undefined;
    var b: [4]f64 = undefined;
    vecMat(v, &j3, 1, 2, &a);
    ⟪vecMat(&a, &j2, 2, 4, &b);|||???⟫
    ⟪vecMat(&b, &j1, 4, 3, out);|||???⟫
}

const Mode = enum { forward, reverse };

/// Passes needed to get the whole Jacobian of an n -> m function.
fn passesNeeded(mode: Mode, n: usize, m: usize) usize {
    return switch (mode) {
        .forward => ⟪n|||???⟫,
        .reverse => ⟪m|||???⟫,
    };
}

test "both agree: vᵀ (J u) = (vᵀ J) u" {
    const u = [_]f64{ 0.5, -1, 2 };
    const v = [_]f64{1.5};
    var ju: [1]f64 = undefined;
    var vj: [3]f64 = undefined;
    jvp(&u, &ju);
    vjp(&v, &vj);
    const left = v[0] * ju[0];
    const right = vj[0] * u[0] + vj[1] * u[1] + vj[2] * u[2];
    try std.testing.expectApproxEqAbs(left, right, 1e-12);
}

test "one reverse pass gives the whole gradient" {
    // the gradient of this scalar function is vᵀ J with v = [1]
    var grad: [3]f64 = undefined;
    vjp(&.{1}, &grad);
    // ...and each forward pass gives just one entry of it
    for (0..3) |j| {
        var e: [3]f64 = @splat(0);
        e[j] = 1;
        var one: [1]f64 = undefined;
        jvp(&e, &one);
        try std.testing.expectApproxEqAbs(grad[j], one[0], 1e-12);
    }
}

test "why deep learning uses reverse mode" {
    const weights = 1_000_000;
    try std.testing.expectEqual(1_000_000, passesNeeded(.forward, weights, 1));
    try std.testing.expectEqual(1, passesNeeded(.reverse, weights, 1));
}
