// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 122: the maths of a VAE ──────────────────────────────────
//
// A *variational autoencoder* (VAE) makes the autoencoder generative. The
// encoder outputs a DISTRIBUTION for the code, normal with mean μ and
// standard deviation σ (060), and the loss has two parts:
//
//   1. reconstruction: decode a sampled code z, compare with the input
//   2. KL(N(μ, σ²) || N(0, 1)) (062): keep codes close to a standard
//      normal, so that sampling z ~ N(0, 1) later decodes to realistic data
//
// For normals the KL has a closed form:
//
//     KL = 0.5 * (μ² + σ² - 1 - ln σ²)
//
// The problem: you can't backprop through "sample z". The
// *reparameterization trick* moves the randomness out of the way:
//
//     z = μ + σ ε,    with ε ~ N(0, 1) drawn separately
//
// Now z is an ordinary function of μ and σ (dz/dμ = 1, dz/dσ = ε), and
// gradients flow. Diffusion models (next) use the same trick at every
// noise level.
//
// YOUR TASK: write the KL and the reparameterized sample, then use the
// trick to estimate a gradient.
//
const std = @import("std");

fn klToStandard(mu: f64, sigma: f64) f64 {
    return 0.5 * (mu * mu + sigma * sigma - 1 - @log(sigma * sigma));
}

fn sample(mu: f64, sigma: f64, eps: f64) f64 {
    return mu + sigma * eps;
}

test "KL is 0 exactly at the standard normal" {
    try std.testing.expectApproxEqAbs(0.0, klToStandard(0, 1), 1e-12);
    try std.testing.expect(klToStandard(1, 1) > 0);
    try std.testing.expect(klToStandard(0, 0.5) > 0);
}

test "the closed form matches a Monte Carlo estimate" {
    // KL = average over z ~ N(μ, σ²) of log p(z) - log q(z)
    const mu = 0.7;
    const sigma = 0.6;
    var prng = std.Random.DefaultPrng.init(122);
    var est: f64 = 0;
    const n = 200_000;
    for (0..n) |_| {
        const z = sample(mu, sigma, prng.random().floatNorm(f64));
        const log_p = -0.5 * ((z - mu) / sigma) * ((z - mu) / sigma) - @log(sigma);
        const log_q = -0.5 * z * z;
        est += (log_p - log_q) / n;
    }
    try std.testing.expectApproxEqAbs(klToStandard(mu, sigma), est, 0.01);
}

test "reparameterized gradients: d/dμ of E[z²] = 2μ" {
    // E[z²] = μ² + σ², so the true gradient is 2μ.
    // With z = μ + σ ε, d(z²)/dμ = 2z: average it over samples.
    const mu = 1.5;
    const sigma = 0.8;
    var prng = std.Random.DefaultPrng.init(7);
    var grad: f64 = 0;
    for (0..100_000) |_| {
        const z = sample(mu, sigma, prng.random().floatNorm(f64));
        grad += 2 * z / 100_000;
    }
    try std.testing.expectApproxEqAbs(2 * mu, grad, 0.02);
}
