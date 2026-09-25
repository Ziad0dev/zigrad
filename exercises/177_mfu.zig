//
// ─── Exercise 177: how many FLOPs does training take? ─────────────────
//
// A matmul with a [d_in, d_out] weight costs 2 * d_in * d_out FLOPs per
// token (a multiply and an add per weight, 044). So a forward pass through
// a model with N parameters costs about 2N FLOPs per token. Backward costs
// about twice that: every weight matmul needs one matmul for the input's
// gradient and one for the weight's (035, 082). Total:
//
//     training FLOPs ≈ 6 * N * D          (N parameters, D tokens)
//
// This "6ND" rule ignores attention's own score computations (small unless
// the context is long) and the elementwise ops (tiny), and it's accurate
// enough to plan with.
//
// *Model FLOPs utilization* (MFU, from Google's PaLM paper, 2022) asks: of
// the chip's peak FLOP/s, how much are we actually using for the model?
//
//     MFU = (6 * N * tokens_per_second) / peak_flops
//
// Well-tuned large training runs reach roughly 35-55%. Anything much lower
// means time lost to communication, memory-bound kernels (044), pipeline
// bubbles (139) or the input pipeline.
//
// YOUR TASK: FLOPs per token, total training FLOPs, MFU, and wall-clock
// days.
//
const std = @import("std");

fn trainFlopsPerToken(params: f64) f64 {
    return ???;
}

fn trainFlops(params: f64, tokens: f64) f64 {
    return ???;
}

fn mfu(params: f64, tokens_per_second: f64, peak_flops: f64) f64 {
    return ???;
}

/// Days to train, on `gpus` chips of `peak_flops` each, at utilization `u`.
fn days(params: f64, tokens: f64, gpus: f64, peak_flops: f64, u: f64) f64 {
    const seconds = ???;
    return seconds / 86400;
}

test "6ND" {
    // a 7B model on 2 trillion tokens
    try std.testing.expectApproxEqRel(8.4e22, trainFlops(7e9, 2e12), 1e-12);
}

test "MFU" {
    // 7B model, 10,000 tokens/s per GPU, 1 PFLOP/s peak: 42%
    try std.testing.expectApproxEqRel(0.42, mfu(7e9, 1e4, 1e15), 1e-12);
}

test "how long?" {
    // 8.4e22 FLOPs on 1024 GPUs of 1 PFLOP/s at 40%: about 2.4 days
    try std.testing.expectApproxEqRel(2.3735, days(7e9, 2e12, 1024, 1e15, 0.4), 1e-3);
}
