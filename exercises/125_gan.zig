//
// ─── Exercise 125: GANs, a game between two networks ───────────────────
//
// A *generative adversarial network* trains two networks against each
// other:
//   * a generator G turns noise z into fake data
//   * a discriminator D outputs D(x), the probability that x is real
//
// D minimizes the binary cross-entropy (061) of telling them apart:
//
//     loss_D = -log D(real) - log(1 - D(G(z)))
//
// G wants to fool D. The textbook minimax version gives G the loss
// log(1 - D(G(z))). But early in training D easily spots the fakes,
// D(G(z)) ≈ 0, and that loss is nearly flat there: G gets almost no
// gradient. The practical fix, the *non-saturating* loss:
//
//     loss_G = -log D(G(z))
//
// Same goal, but steep exactly where G is doing badly.
//
// And for a fixed G, the best possible discriminator is
//
//     D*(x) = p_data(x) / (p_data(x) + p_G(x))
//
// When G matches the data perfectly, D* = 1/2 everywhere: it can't do
// better than a coin flip.
//
// YOUR TASK: write the losses and their slopes with respect to d = D(G(z)).
//
const std = @import("std");

fn discriminatorLoss(d_real: f64, d_fake: f64) f64 {
    return ???;
}

/// log(1 - d), and its derivative with respect to d.
fn saturatingLoss(d: f64) f64 {
    return @log(1 - d);
}
fn saturatingSlope(d: f64) f64 {
    return ???;
}

/// -log(d), and its derivative with respect to d.
fn nonSaturatingLoss(d: f64) f64 {
    return -@log(d);
}
fn nonSaturatingSlope(d: f64) f64 {
    return ???;
}

fn optimalD(p_data: f64, p_g: f64) f64 {
    return ???;
}

test "slopes match the losses" {
    const h = 1e-7;
    for ([_]f64{ 0.01, 0.3, 0.8 }) |d| {
        try std.testing.expectApproxEqAbs((saturatingLoss(d + h) - saturatingLoss(d - h)) / (2 * h), saturatingSlope(d), 1e-5);
        try std.testing.expectApproxEqAbs((nonSaturatingLoss(d + h) - nonSaturatingLoss(d - h)) / (2 * h), nonSaturatingSlope(d), 1e-3);
    }
}

test "early in training, only the non-saturating loss gives a real gradient" {
    const d = 0.001; // D easily spots the fake
    try std.testing.expect(@abs(saturatingSlope(d)) < 1.01);
    try std.testing.expect(@abs(nonSaturatingSlope(d)) > 900);
}

test "the discriminator" {
    try std.testing.expectApproxEqAbs(-@log(0.9) - @log(0.8), discriminatorLoss(0.9, 0.2), 1e-12);
    try std.testing.expectApproxEqAbs(0.5, optimalD(0.3, 0.3), 1e-12); // a perfect generator
    try std.testing.expectApproxEqAbs(0.75, optimalD(0.3, 0.1), 1e-12);
}
