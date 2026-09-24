//
// ─── Exercise 038: momentum and Adam ───────────────────────────────────
//
// Plain gradient descent (exercise 032) has a problem in long, narrow
// valleys. Take f(x, y) = 0.5 * (10 x^2 + y^2): steep in x, gentle in y.
// A step size small enough not to bounce around in x crawls along y.
//
// Momentum: think of a ball rolling downhill. Keep a velocity that
// remembers past gradients:
//
//     v = mu * v + grad          (mu ≈ 0.9: keep 90% of the old speed)
//     w = w - lr * v
//
// Consistent directions (along the valley) build up speed. Directions
// that keep flipping (across it) cancel out.
//
// Adam: give every weight its own step size, based on how big its recent
// gradients have been. Keep two running averages:
//
//     m = b1 * m + (1 - b1) * grad       average gradient      (b1 = 0.9)
//     v = b2 * v + (1 - b2) * grad^2     average squared grad  (b2 = 0.999)
//
// Both start at 0, so early on they're too small (after step 1,
// m = 0.1 * grad). Dividing by (1 - b^t), where t is the step number,
// fixes that ("bias correction"):
//
//     m_hat = m / (1 - b1^t)       v_hat = v / (1 - b2^t)
//     w = w - lr * m_hat / (sqrt(v_hat) + eps)
//
// m_hat / sqrt(v_hat) is roughly "the gradient's direction, at size 1",
// so each weight moves about lr per step, however steep its slope. At
// t = 1 it's exactly grad / |grad| = ±1. Adam is the default optimizer in
// most of deep learning, and tinygrad has it in nn.optim.
//
// Zig note: `race` takes a *type* as a parameter (comptime Opt: type) and
// works for any optimizer that has a step() method. That's how Zig does
// generics.
//
// YOUR TASK: finish Momentum.step() and Adam.step().
//
const std = @import("std");

const Sgd = struct {
    lr: f64,

    fn step(o: *Sgd, w: *f64, grad: f64) void {
        w.* -= o.lr * grad;
    }
};

const Momentum = struct {
    lr: f64,
    mu: f64 = 0.9,
    velocity: f64 = 0,

    fn step(o: *Momentum, w: *f64, grad: f64) void {
        o.velocity = ⟪o.mu * o.velocity + grad|||???⟫;
        w.* -= o.lr * o.velocity;
    }
};

const Adam = struct {
    lr: f64,
    b1: f64 = 0.9,
    b2: f64 = 0.999,
    eps: f64 = 1e-8,
    m: f64 = 0,
    v: f64 = 0,
    t: f64 = 0,

    fn step(o: *Adam, w: *f64, grad: f64) void {
        o.t += 1;
        o.m = ⟪o.b1 * o.m + (1 - o.b1) * grad|||???⟫;
        o.v = ⟪o.b2 * o.v + (1 - o.b2) * grad * grad|||???⟫;
        const m_hat = o.m / ⟪(1 - std.math.pow(f64, o.b1, o.t))|||???⟫;
        const v_hat = o.v / (1 - std.math.pow(f64, o.b2, o.t));
        w.* -= o.lr * m_hat / (@sqrt(v_hat) + o.eps);
    }
};

/// Minimize 0.5 * (10 x^2 + y^2) from (1, 1). Returns the final loss.
fn race(comptime Opt: type, opt: Opt, steps: usize) f64 {
    var ox = opt; // one optimizer (with its own memory) per weight
    var oy = opt;
    var x: f64 = 1;
    var y: f64 = 1;
    for (0..steps) |_| {
        ox.step(&x, 10 * x); // d/dx
        oy.step(&y, y); //      d/dy
    }
    return 0.5 * (10 * x * x + y * y);
}

test "momentum builds up speed" {
    var o: Momentum = .{ .lr = 0.1 };
    var w: f64 = 0;
    o.step(&w, 1);
    try std.testing.expectApproxEqAbs(-0.1, w, 1e-12);
    o.step(&w, 1); // velocity 1.9
    try std.testing.expectApproxEqAbs(-0.29, w, 1e-12);
    o.step(&w, 1); // velocity 2.71
    try std.testing.expectApproxEqAbs(-0.561, w, 1e-12);
}

test "Adam's first step is lr, whatever the gradient" {
    var small: Adam = .{ .lr = 0.01 };
    var w: f64 = 1;
    small.step(&w, 0.3);
    try std.testing.expectApproxEqAbs(0.99, w, 1e-6);

    var big: Adam = .{ .lr = 0.01 };
    w = 1;
    big.step(&w, -50);
    try std.testing.expectApproxEqAbs(1.01, w, 1e-6);
}

test "the race through the valley" {
    const sgd = race(Sgd, .{ .lr = 0.01 }, 100);
    const momentum = race(Momentum, .{ .lr = 0.01 }, 100);
    const adam = race(Adam, .{ .lr = 0.05 }, 100);
    try std.testing.expect(momentum < sgd / 100);
    try std.testing.expect(adam < sgd / 100);
}
