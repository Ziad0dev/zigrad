// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 061: where loss functions come from ──────────────────────
//
// Why squared error? Why cross-entropy? Both fall out of ONE principle:
// *maximum likelihood*. Pick the parameters under which the data you
// actually saw was most probable.
//
// Probabilities of many independent examples multiply, and products of
// tiny numbers underflow (002), so take logs: products become sums. And
// optimizers minimize, so flip the sign. That's the *negative log
// likelihood* (NLL), and it IS the loss.
//
// Regression: assume y = prediction + normal noise with σ (060). The
// normal's log density is
//
//     log p(y) = -0.5 * log(2π σ^2) - (y - μ)^2 / (2 σ^2)
//
// The first part doesn't depend on the prediction μ. So minimizing the
// NLL is minimizing sum of (y - μ)^2: squared error! MSE secretly
// assumes Gaussian noise.
//
// Classification: the model gives probabilities p over classes, and the
// right class is t. The likelihood of that example is p[t], so the NLL is
// -log p[t]: cross-entropy (036).
//
// Yes/no (binary) outputs: p = chance of "yes", y is 1 or 0. The
// probability of what happened is p if y = 1, else 1 - p:
//
//     BCE = -(y log p + (1 - y) log(1 - p))
//
// And the best p for a coin that came up heads h times in n flips is
// h / n, which you can check numerically.
//
// YOUR TASK: write gaussianLogPdf(), bce() and nll().
//
const std = @import("std");

fn gaussianLogPdf(y: f64, mu: f64, sigma: f64) f64 {
    return -0.5 * @log(2 * std.math.pi * sigma * sigma) - (y - mu) * (y - mu) / (2 * sigma * sigma);
}

/// Negative log likelihood of all ys, if each is mu + noise with sigma.
fn nll(ys: []const f64, mu: f64, sigma: f64) f64 {
    var total: f64 = 0;
    for (ys) |y| total -= gaussianLogPdf(y, mu, sigma);
    return total;
}

fn bce(p: f64, y: f64) f64 {
    return -(y * @log(p) + (1 - y) * @log(1 - p));
}

fn sse(ys: []const f64, mu: f64) f64 {
    var total: f64 = 0;
    for (ys) |y| total += (y - mu) * (y - mu);
    return total;
}

test "the normal density" {
    // the peak of a standard normal is 1 / sqrt(2π) ≈ 0.3989
    try std.testing.expectApproxEqAbs(0.398942, @exp(gaussianLogPdf(0, 0, 1)), 1e-6);
    try std.testing.expectApproxEqAbs(0.241971, @exp(gaussianLogPdf(1, 0, 1)), 1e-6);
}

test "Gaussian NLL is squared error in disguise" {
    const ys = [_]f64{ 1, 2, 2.5, 4 };
    const sigma = 0.7;
    // NLL differences = squared-error differences / (2 σ^2), for any two μ
    const d_nll = nll(&ys, 1.0, sigma) - nll(&ys, 3.0, sigma);
    const d_sse = (sse(&ys, 1.0) - sse(&ys, 3.0)) / (2 * sigma * sigma);
    try std.testing.expectApproxEqAbs(d_sse, d_nll, 1e-9);

    // and the best μ is the mean
    var best: f64 = 0;
    var best_nll = std.math.inf(f64);
    var mu: f64 = 0;
    while (mu < 5) : (mu += 0.125) {
        if (nll(&ys, mu, sigma) < best_nll) {
            best_nll = nll(&ys, mu, sigma);
            best = mu;
        }
    }
    try std.testing.expectEqual(2.375, best); // (1 + 2 + 2.5 + 4) / 4
}

test "binary cross-entropy" {
    try std.testing.expectApproxEqAbs(-@log(0.9), bce(0.9, 1), 1e-12);
    try std.testing.expectApproxEqAbs(-@log(0.1), bce(0.9, 0), 1e-12);
}

test "the best coin is h / n" {
    // 7 heads in 10 flips: NLL = sum of bce over flips
    var best: f64 = 0;
    var best_loss = std.math.inf(f64);
    var p: f64 = 0.05;
    while (p < 1) : (p += 0.05) {
        const loss = 7 * bce(p, 1) + 3 * bce(p, 0);
        if (loss < best_loss) {
            best_loss = loss;
            best = p;
        }
    }
    try std.testing.expectApproxEqAbs(0.7, best, 1e-9);
}
