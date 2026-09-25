// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 178: compute-optimal models ─────────────────────────────
//
// You have a fixed compute budget C (in FLOPs). Should you train a big
// model on few tokens, or a small one on many? 177 says C ≈ 6ND, so every
// choice of N fixes D = C / (6N).
//
// *Scaling laws* measure how the final loss depends on N and D. The
// "Chinchilla" paper (Hoffmann et al., 2022) trained hundreds of models
// and found that, for the best loss at a given budget, parameters and
// tokens should grow TOGETHER, roughly in proportion:
//
//     D ≈ 20 N          (about 20 training tokens per parameter)
//
// Their Chinchilla model, 70B parameters on 1.4T tokens, beat the 280B
// Gopher trained with the same compute on fewer tokens.
//
// Put the two equations together: C = 6 N (20 N) = 120 N², so
//
//     N = sqrt(C / 120)        D = 20 N
//
// One caveat, and it matters: Chinchilla-optimal minimizes TRAINING
// compute. A model is then used for inference billions of times, where a
// smaller model is cheaper forever. So many recent models are trained far
// past 20 tokens per parameter (Llama 3 8B saw about 15T tokens, nearly
// 2000 per parameter).
//
// YOUR TASK: the compute-optimal N and D for a budget.
//
const std = @import("std");

const tokens_per_param = 20.0;

fn optimalParams(compute: f64) f64 {
    return @sqrt(compute / (6 * tokens_per_param));
}

fn optimalTokens(compute: f64) f64 {
    return tokens_per_param * optimalParams(compute);
}

test "Chinchilla itself" {
    // 70B params on 1.4T tokens: C = 6 * 70e9 * 1.4e12
    const c = 6 * 70e9 * 1.4e12;
    try std.testing.expectApproxEqRel(70e9, optimalParams(c), 1e-9);
    try std.testing.expectApproxEqRel(1.4e12, optimalTokens(c), 1e-9);
}

test "the budget splits as square roots" {
    // 100x the compute: 10x the parameters and 10x the tokens
    const c = 1e22;
    try std.testing.expectApproxEqRel(10 * optimalParams(c), optimalParams(100 * c), 1e-9);
    try std.testing.expectApproxEqRel(10 * optimalTokens(c), optimalTokens(100 * c), 1e-9);
}
