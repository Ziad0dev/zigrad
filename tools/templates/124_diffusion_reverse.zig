//
// ─── Exercise 124: diffusion, removing noise ───────────────────────────
//
// Generation runs the noising backwards: start from pure noise x_T and
// step down to x_0. At each step a network predicts the noise ε that's in
// x_t. Given that prediction, two formulas do the rest.
//
// 1. Invert the one-shot noising (123) to estimate the clean data:
//
//        x̂_0 = (x_t - sqrt(1 - ᾱ_t) ε) / sqrt(ᾱ_t)
//
// 2. The DDPM step: the mean of x_(t-1) given x_t:
//
//        μ = (x_t - β_t / sqrt(1 - ᾱ_t) * ε) / sqrt(α_t)
//
//    then add fresh noise with standard deviation sqrt(β_t) (except at
//    the last step).
//
// That DDPM mean isn't arbitrary: it equals the exact Gaussian posterior
// mean of x_(t-1) given x_t and x_0,
//
//        μ = (sqrt(ᾱ_(t-1)) β_t / (1 - ᾱ_t)) x_0 + (sqrt(α_t) (1 - ᾱ_(t-1)) / (1 - ᾱ_t)) x_t
//
// with x̂_0 plugged in for x_0. The tests check that both forms agree,
// which is a nice piece of algebra to verify numerically.
//
// With a PERFECT noise predictor (we know the true ε here), x̂_0 is exact.
//
// YOUR TASK: write predictX0() and ddpmMean().
//
const std = @import("std");

fn predictX0(xt: f64, eps: f64, abar: f64) f64 {
    return ⟪(xt - @sqrt(1 - abar) * eps) / @sqrt(abar)|||???⟫;
}

fn ddpmMean(xt: f64, eps: f64, beta: f64, abar: f64) f64 {
    const alpha = 1 - beta;
    return ⟪(xt - beta / @sqrt(1 - abar) * eps) / @sqrt(alpha)|||???⟫;
}

fn posteriorMean(x0: f64, xt: f64, beta: f64, abar: f64, abar_prev: f64) f64 {
    const alpha = 1 - beta;
    return @sqrt(abar_prev) * beta / (1 - abar) * x0 + @sqrt(alpha) * (1 - abar_prev) / (1 - abar) * xt;
}

test "a perfect noise prediction recovers x_0 exactly" {
    const x0 = 0.73;
    const eps = -1.2;
    const abar = 0.3;
    const xt = @sqrt(abar) * x0 + @sqrt(1 - abar) * eps;
    try std.testing.expectApproxEqAbs(x0, predictX0(xt, eps, abar), 1e-12);
}

test "the DDPM mean is the posterior mean" {
    const x0 = -0.4;
    const eps = 0.9;
    const beta = 0.02;
    const abar_prev = 0.5;
    const abar = abar_prev * (1 - beta);
    const xt = @sqrt(abar) * x0 + @sqrt(1 - abar) * eps;

    const via_eps = ddpmMean(xt, eps, beta, abar);
    const via_x0 = posteriorMean(predictX0(xt, eps, abar), xt, beta, abar, abar_prev);
    try std.testing.expectApproxEqAbs(via_x0, via_eps, 1e-12);
}
