//
// ─── Exercise 132: Adagrad and RMSprop ─────────────────────────────────
//
// Adam (038) didn't come from nowhere. It combined momentum with two
// earlier ideas for giving every weight its own step size.
//
// Adagrad: divide each step by the square root of ALL the squared
// gradients so far:
//
//     G += g²
//     w -= lr * g / (sqrt(G) + ε)
//
// Weights with big, frequent gradients get small steps; rare features get
// big ones. But G only ever grows, so the steps shrink toward zero and
// eventually training stalls.
//
// RMSprop (proposed by Hinton in a Coursera lecture, never formally
// published!) fixes that by using a moving average instead of a sum, so
// it forgets old gradients:
//
//     v = ρ v + (1 - ρ) g²
//     w -= lr * g / (sqrt(v) + ε)
//
// Add momentum and bias correction and you have Adam.
//
// YOUR TASK: write both steps.
//
const std = @import("std");

const Adagrad = struct {
    lr: f64,
    g2: f64 = 0,

    fn step(o: *Adagrad, w: *f64, g: f64) f64 {
        o.g2 += ???;
        const delta = ???;
        w.* -= delta;
        return delta;
    }
};

const RmsProp = struct {
    lr: f64,
    rho: f64 = 0.9,
    v: f64 = 0,

    fn step(o: *RmsProp, w: *f64, g: f64) f64 {
        o.v = ???;
        const delta = o.lr * g / (@sqrt(o.v) + 1e-8);
        w.* -= delta;
        return delta;
    }
};

test "Adagrad's steps keep shrinking, even with a steady gradient" {
    var o: Adagrad = .{ .lr = 0.1 };
    var w: f64 = 0;
    const first = o.step(&w, 1);
    var last: f64 = 0;
    for (0..99) |_| last = o.step(&w, 1);
    try std.testing.expectApproxEqAbs(0.1, first, 1e-6);
    try std.testing.expectApproxEqAbs(0.01, last, 1e-6); // 1/sqrt(100)
}

test "RMSprop's steps settle at lr" {
    var o: RmsProp = .{ .lr = 0.1 };
    var w: f64 = 0;
    var last: f64 = 0;
    for (0..200) |_| last = o.step(&w, 1);
    try std.testing.expectApproxEqAbs(0.1, last, 1e-4);
}

test "both ignore the gradient's scale" {
    var small: RmsProp = .{ .lr = 0.1 };
    var big: RmsProp = .{ .lr = 0.1 };
    var a: f64 = 0;
    var b: f64 = 0;
    for (0..50) |_| {
        _ = small.step(&a, 0.001);
        _ = big.step(&b, 1000);
    }
    try std.testing.expectApproxEqRel(a, b, 1e-4);
}
