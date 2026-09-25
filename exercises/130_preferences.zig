//
// ─── Exercise 130: learning from preferences (RLHF, DPO) ───────────────
//
// How do you tell a language model what a "good" answer is? It's much
// easier for people to COMPARE two answers than to score one. The
// *Bradley-Terry* model turns comparisons into probabilities: with
// rewards r_w (the winner) and r_l (the loser),
//
//     P(winner preferred) = σ(r_w - r_l)
//
// RLHF (reinforcement learning from human feedback):
//   1. train a reward model on preference pairs, with loss
//          -log σ(r_w - r_l)
//   2. fine-tune the LLM with policy gradients (129) to maximize that
//      reward, while a KL penalty (062) keeps it close to the original
//
// *DPO* (direct preference optimization) skips the reward model and the
// RL. It uses the model's own log-probabilities, relative to a frozen
// reference model, as an implicit reward:
//
//     margin = β * [ (log π(w) - log π_ref(w)) - (log π(l) - log π_ref(l)) ]
//     loss   = -log σ(margin)
//
// Lowering it raises the winner's probability and lowers the loser's,
// compared with where they started.
//
// YOUR TASK: write the three formulas.
//
const std = @import("std");

fn sigmoid(x: f64) f64 {
    return 1 / (1 + @exp(-x));
}

fn preferProb(r_w: f64, r_l: f64) f64 {
    return ???;
}

fn rewardModelLoss(r_w: f64, r_l: f64) f64 {
    return ???;
}

fn dpoLoss(logp_w: f64, logp_l: f64, ref_w: f64, ref_l: f64, beta: f64) f64 {
    const margin = ???;
    return -@log(sigmoid(margin));
}

test "Bradley-Terry" {
    try std.testing.expectApproxEqAbs(0.5, preferProb(2, 2), 1e-12);
    try std.testing.expect(preferProb(3, 1) > 0.88);
    try std.testing.expectApproxEqAbs(@log(2.0), rewardModelLoss(1, 1), 1e-12);
}

test "DPO starts at log 2, and falls as the winner gains" {
    // policy = reference: no preference expressed yet
    try std.testing.expectApproxEqAbs(@log(2.0), dpoLoss(-5, -6, -5, -6, 0.1), 1e-12);
    // winner more likely than under the reference, loser less likely
    try std.testing.expect(dpoLoss(-4, -7, -5, -6, 0.1) < @log(2.0));
    // the wrong way round: worse than log 2
    try std.testing.expect(dpoLoss(-6, -5, -5, -6, 0.1) > @log(2.0));
}
