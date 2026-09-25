//
// ─── Exercise 098: weight decay, and why AdamW exists ──────────────────
//
// *Weight decay* pulls weights toward zero a little every step, which
// discourages the huge weights that come with memorizing (101). Two ways
// to do it:
//
//   L2 penalty: add (λ/2) |w|^2 to the loss, which adds λ w to the
//               gradient.
//   decoupled:  after the optimizer step, w -= lr * λ * w, separately.
//
// With plain SGD these are the same thing. With Adam they are NOT: Adam
// divides the gradient by its recent size (038). The λ w term gets
// "normalized" too, so a tiny penalty turns into steps of size ~lr, and
// weights with large gradients get barely decayed at all.
//
// *AdamW* ("Adam with decoupled weight decay") keeps the decay OUT of the
// gradient, so it does exactly what it says. It's the default optimizer
// for training transformers (tinygrad has nn.optim.AdamW).
//
// The tests make the difference stark: a weight with NO loss gradient at
// all. AdamW shrinks it gently by (1 - lr λ) per step. Adam with an L2
// penalty sends it to 0 in a handful of steps.
//
// YOUR TASK: write both update steps.
//
const std = @import("std");

const Adam = struct {
    lr: f64,
    wd: f64, // λ
    b1: f64 = 0.9,
    b2: f64 = 0.999,
    eps: f64 = 1e-8,
    m: f64 = 0,
    v: f64 = 0,
    t: f64 = 0,

    fn adamStep(o: *Adam, w: *f64, grad: f64) void {
        o.t += 1;
        o.m = o.b1 * o.m + (1 - o.b1) * grad;
        o.v = o.b2 * o.v + (1 - o.b2) * grad * grad;
        const m_hat = o.m / (1 - std.math.pow(f64, o.b1, o.t));
        const v_hat = o.v / (1 - std.math.pow(f64, o.b2, o.t));
        w.* -= o.lr * m_hat / (@sqrt(v_hat) + o.eps);
    }

    /// Adam, with λ w added to the gradient.
    fn stepL2(o: *Adam, w: *f64, grad: f64) void {
        o.adamStep(w, ⟪grad + o.wd * w.*|||???⟫);
    }

    /// AdamW: a normal Adam step, then decay separately.
    fn stepAdamW(o: *Adam, w: *f64, grad: f64) void {
        o.adamStep(w, grad);
        ⟪w.* -= o.lr * o.wd * w.*;|||???;⟫
    }
};

test "AdamW decays by exactly (1 - lr λ) per step" {
    var o: Adam = .{ .lr = 0.1, .wd = 0.01 };
    var w: f64 = 1;
    for (0..10) |_| o.stepAdamW(&w, 0);
    try std.testing.expectApproxEqAbs(std.math.pow(f64, 1 - 0.1 * 0.01, 10), w, 1e-12);
}

test "Adam + L2 decays at full speed, whatever λ is" {
    var o: Adam = .{ .lr = 0.1, .wd = 0.01 };
    var w: f64 = 1;
    for (0..10) |_| o.stepL2(&w, 0);
    try std.testing.expect(@abs(w) < 0.15); // wiped out, by a "tiny" penalty
}

test "with SGD they'd be the same" {
    const lr = 0.1;
    const wd = 0.01;
    const g = 0.5;
    var a: f64 = 1;
    var b: f64 = 1;
    a -= lr * (g + wd * a); //      L2
    b -= lr * g;
    b -= lr * wd * 1; //            decoupled (using the old w)
    try std.testing.expectApproxEqAbs(a, b, 1e-15);
}
