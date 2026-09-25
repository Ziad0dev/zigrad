//
// ─── Exercise 123: diffusion, adding noise ─────────────────────────────
//
// Diffusion models (Stable Diffusion, DALL-E 2, Sora...) learn to UNDO
// noise. Training starts from the easy direction: destroy data by adding a
// little Gaussian noise at each of T steps, with noise amounts β_1..β_T
// (the "schedule", usually growing from ~0.0001 to ~0.02):
//
//     x_t = sqrt(1 - β_t) x_(t-1) + sqrt(β_t) ε
//
// The sqrt(1 - β) shrink keeps the variance at 1: if x_(t-1) has variance
// 1, then (1 - β) + β = 1. After enough steps, pure noise.
//
// You don't have to loop: noise is Gaussian, and sums of Gaussians are
// Gaussian, so any step t has a closed form. With α_t = 1 - β_t and
// ᾱ_t = α_1 · α_2 · ... · α_t (how much signal survives):
//
//     x_t = sqrt(ᾱ_t) x_0 + sqrt(1 - ᾱ_t) ε
//
// Training then picks a random t, noises x_0 in ONE shot, and asks the
// network to predict ε. That's it.
//
// YOUR TASK: build ᾱ, and noise in one shot.
//
const std = @import("std");

const steps = 1000;

fn betaAt(t: usize) f64 {
    // linear schedule from 1e-4 to 0.02 (the DDPM paper's)
    return 1e-4 + (0.02 - 1e-4) * @as(f64, @floatFromInt(t)) / (steps - 1);
}

fn alphaBar(out: *[steps]f64) void {
    var prod: f64 = 1;
    for (out, 0..) |*a, t| {
        prod *= ⟪1 - betaAt(t)|||???⟫;
        a.* = prod;
    }
}

fn noisy(x0: f64, abar: f64, eps: f64) f64 {
    return ⟪@sqrt(abar) * x0 + @sqrt(1 - abar) * eps|||???⟫;
}

test "the signal fades to nothing" {
    var ab: [steps]f64 = undefined;
    alphaBar(&ab);
    try std.testing.expect(ab[0] > 0.999);
    try std.testing.expect(ab[steps - 1] < 1e-4);
    for (1..steps) |t| try std.testing.expect(ab[t] < ab[t - 1]);
}

test "one shot equals step by step" {
    var ab: [steps]f64 = undefined;
    alphaBar(&ab);
    // Step by step with the SAME total noise isn't directly comparable
    // sample by sample, but the statistics must match: check the variance
    // of x_t for data with variance 1.
    var prng = std.Random.DefaultPrng.init(123);
    const rand = prng.random();
    const t = 300;
    var var_loop: f64 = 0;
    var var_shot: f64 = 0;
    var cov_loop: f64 = 0; // how much of x_0 survives
    var cov_shot: f64 = 0;
    const n = 4000;
    for (0..n) |_| {
        const x0 = rand.floatNorm(f64);
        var x = x0;
        for (0..t + 1) |s| x = @sqrt(1 - betaAt(s)) * x + @sqrt(betaAt(s)) * rand.floatNorm(f64);
        const y = noisy(x0, ab[t], rand.floatNorm(f64));
        var_loop += x * x / n;
        var_shot += y * y / n;
        cov_loop += x * x0 / n;
        cov_shot += y * x0 / n;
    }
    try std.testing.expectApproxEqAbs(1.0, var_loop, 0.06);
    try std.testing.expectApproxEqAbs(1.0, var_shot, 0.06);
    try std.testing.expectApproxEqAbs(@sqrt(ab[t]), cov_shot, 0.04);
    try std.testing.expectApproxEqAbs(cov_loop, cov_shot, 0.06);
}
