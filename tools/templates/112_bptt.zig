//
// ─── Exercise 112: backpropagation through time ────────────────────────
//
// How do you train an RNN? *Unroll* it: a sequence of T steps is just a
// T-layer network where every layer shares the same weights. Then run
// ordinary backprop (030) from the last step back to the first. That's
// "backpropagation through time" (BPTT).
//
// For a scalar RNN, h_t = tanh(w h_(t-1) + u x_t), with loss = h_T:
//
//     dh  = 1                               (d loss / d h_T)
//     for t = T down to 1:
//         dpre = dh * (1 - h_t^2)           (tanh' = 1 - tanh^2, 039)
//         dw  += dpre * h_(t-1)             (w was used at EVERY step:
//         du  += dpre * x_t                  its gradient is a sum, 030)
//         dh   = dpre * w                   (pass back to h_(t-1))
//
// YOUR TASK: write the backward loop.
//
const std = @import("std");

fn forward(w: f64, u: f64, xs: []const f64, hs: []f64) f64 {
    var h: f64 = 0;
    hs[0] = 0;
    for (xs, 1..) |x, t| {
        h = std.math.tanh(w * h + u * x);
        hs[t] = h;
    }
    return h;
}

/// Gradients of h_T with respect to w and u. hs = [h_0, h_1, ..., h_T].
fn backward(w: f64, xs: []const f64, hs: []const f64) [2]f64 {
    var dh: f64 = 1;
    var dw: f64 = 0;
    var du: f64 = 0;
    var t = xs.len;
    while (t > 0) : (t -= 1) {
        const dpre = ⟪dh * (1 - hs[t] * hs[t])|||???⟫;
        dw += ⟪dpre * hs[t - 1]|||???⟫;
        du += ⟪dpre * xs[t - 1]|||???⟫;
        dh = ⟪dpre * w|||???⟫;
    }
    return .{ dw, du };
}

test "BPTT matches measured slopes" {
    const xs = [_]f64{ 0.5, -1, 0.3, 0.8, -0.2, 1 };
    var hs: [xs.len + 1]f64 = undefined;
    const w = 0.7;
    const u = 1.3;
    _ = forward(w, u, &xs, &hs);
    const g = backward(w, &xs, &hs);

    const h = 1e-6;
    const dw = (forward(w + h, u, &xs, &hs) - forward(w - h, u, &xs, &hs)) / (2 * h);
    const du = (forward(w, u + h, &xs, &hs) - forward(w, u - h, &xs, &hs)) / (2 * h);
    try std.testing.expectApproxEqAbs(dw, g[0], 1e-8);
    try std.testing.expectApproxEqAbs(du, g[1], 1e-8);
}
