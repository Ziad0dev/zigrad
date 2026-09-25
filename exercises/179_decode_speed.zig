//
// ─── Exercise 179: how fast can a model talk? ─────────────────────────
//
// Generating one token (094) runs every weight matrix on ONE vector:
// matrix-vector products, 2 FLOPs per weight but also 1 weight READ per
// multiply-add. That's an arithmetic intensity of about 1 FLOP per byte in
// f16 (044): hopelessly memory-bound. So at batch size 1:
//
//     time per token ≈ weight bytes / memory bandwidth
//
// A 7B model in f16 is 14 GB. On a GPU with 3.35 TB/s (like an H100 SXM),
// the upper limit is 3.35e12 / 14e9 ≈ 239 tokens/s, whatever its FLOPs.
// That's why quantization (141-143) speeds up generation almost in
// proportion: 4-bit weights are 4x fewer bytes to read.
//
// *Batching* is the other lever. Serving B users at once reads each weight
// ONCE for all B tokens, so the memory time stays the same while the
// useful work grows B-fold, until compute becomes the limit:
//
//     memory time  = weight bytes / bandwidth          (per step)
//     compute time = 2 * N * B / peak flops           (per step)
//
// They're equal at B = peak * bytes_per_weight / (2 * bandwidth): for f16,
// just peak / bandwidth, a few hundred on modern GPUs. Below that, bigger
// batches are almost free. That's why inference servers batch aggressively
// (145), and why speculative decoding (144) works: checking several draft
// tokens costs barely more than one.
//
// (This ignores reading the KV cache, which grows with the context and
// matters for long conversations, 145.)
//
// YOUR TASK: the memory-bound token rate, and the crossover batch size.
//
const std = @import("std");

fn tokensPerSecond(params: f64, bytes_per_weight: f64, bandwidth: f64) f64 {
    return ???;
}

/// Seconds for one decoding step serving `batch` sequences: whichever
/// limit is slower.
fn stepTime(params: f64, bytes_per_weight: f64, batch: f64, bandwidth: f64, peak: f64) f64 {
    const memory = params * bytes_per_weight / bandwidth;
    const compute = ???;
    return @max(memory, compute);
}

/// The batch size where compute time catches up with memory time.
fn crossoverBatch(bytes_per_weight: f64, bandwidth: f64, peak: f64) f64 {
    return ???;
}

test "the speed limit" {
    try std.testing.expectApproxEqRel(239.2857142857143, tokensPerSecond(7e9, 2, 3.35e12), 1e-9);
    // 4-bit weights: 4x faster
    try std.testing.expectApproxEqRel(4 * tokensPerSecond(7e9, 2, 3.35e12), tokensPerSecond(7e9, 0.5, 3.35e12), 1e-9);
}

test "batching is free until the crossover" {
    const peak = 989e12; // H100 bf16, dense
    const bw = 3.35e12;
    const b = crossoverBatch(2, bw, peak);
    try std.testing.expectApproxEqRel(295.2238805970149, b, 1e-9);
    // batch 1 and batch 64 take the same time per step...
    try std.testing.expectEqual(stepTime(7e9, 2, 1, bw, peak), stepTime(7e9, 2, 64, bw, peak));
    // ...but past the crossover the step gets slower
    try std.testing.expect(stepTime(7e9, 2, 1000, bw, peak) > stepTime(7e9, 2, 64, bw, peak));
}
