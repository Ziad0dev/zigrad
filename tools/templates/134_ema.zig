//
// ─── Exercise 134: averaging the weights ───────────────────────────────
//
// With noisy mini-batch gradients, SGD never sits still at the bottom: the
// weights keep jittering around the best point. A cheap, very effective
// trick is to keep an *exponential moving average* (EMA) of the weights
// alongside training, and use the average for evaluation:
//
//     ema = decay * ema + (1 - decay) * w          (decay ≈ 0.99..0.9999)
//
// The jitter averages out, and the EMA sits much closer to the centre of
// the valley than any single iterate. Diffusion models and many
// large-scale training setups evaluate EMA weights.
//
// Starting from ema = 0 biases early values toward 0, the same problem
// Adam fixed (038). Same fix: divide by (1 - decay^t).
//
// YOUR TASK: write the EMA update and its bias correction.
//
const std = @import("std");

const Ema = struct {
    decay: f64,
    value: f64 = 0,
    t: f64 = 0,

    fn update(e: *Ema, w: f64) void {
        e.t += 1;
        e.value = ⟪e.decay * e.value + (1 - e.decay) * w|||???⟫;
    }

    fn corrected(e: Ema) f64 {
        return ⟪e.value / (1 - std.math.pow(f64, e.decay, e.t))|||???⟫;
    }
};

test "bias correction" {
    var e: Ema = .{ .decay = 0.99 };
    e.update(5);
    try std.testing.expectApproxEqAbs(0.05, e.value, 1e-12); // biased toward 0
    try std.testing.expectApproxEqAbs(5.0, e.corrected(), 1e-12);
}

test "the average beats the last iterate" {
    // noisy SGD on f(w) = (w - 3)^2: the gradient gets noise added
    var prng = std.Random.DefaultPrng.init(134);
    var w: f64 = 0;
    var e: Ema = .{ .decay = 0.99 };
    var last_err: f64 = 0;
    var ema_err: f64 = 0;
    for (0..20_000) |step| {
        const g = 2 * (w - 3) + 4 * prng.random().floatNorm(f64);
        w -= 0.05 * g;
        e.update(w);
        if (step >= 10_000) {
            last_err += (w - 3) * (w - 3) / 10_000;
            ema_err += (e.corrected() - 3) * (e.corrected() - 3) / 10_000;
        }
    }
    try std.testing.expect(ema_err < last_err / 10);
}
