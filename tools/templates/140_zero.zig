//
// ─── Exercise 140: where the memory goes (ZeRO) ────────────────────────
//
// Training memory per parameter, with mixed precision (100) and Adam (038):
//
//     f16 weights            2 bytes
//     f16 gradients          2 bytes
//     f32 master weights     4 bytes
//     f32 Adam m             4 bytes
//     f32 Adam v             4 bytes
//                           --------
//                           16 bytes per parameter
//
// A 7-billion-parameter model needs 112 GB before a single activation,
// more than any one GPU. Plain data parallelism (053) keeps ALL of it on
// EVERY device.
//
// *ZeRO* (the DeepSpeed paper; PyTorch's FSDP does the same) shards it
// across N data-parallel devices instead:
//     stage 1: shard the optimizer state (12 bytes)       2 + 2 + 12/N
//     stage 2: also the gradients                          2 + (2 + 12)/N
//     stage 3: also the weights themselves                 16/N
// Each device gathers the pieces it needs just in time, trading extra
// communication for memory.
//
// YOUR TASK: write bytes per parameter for each stage.
//
const std = @import("std");

fn bytesPerParam(stage: u2, n: f64) f64 {
    return switch (stage) {
        0 => ⟪16|||???⟫,
        1 => ⟪2 + 2 + 12 / n|||???⟫,
        2 => ⟪2 + (2 + 12) / n|||???⟫,
        3 => ⟪16 / n|||???⟫,
    };
}

fn gigabytes(params: f64, stage: u2, n: f64) f64 {
    return params * bytesPerParam(stage, n) / 1e9;
}

test "a 7B model" {
    try std.testing.expectApproxEqAbs(112.0, gigabytes(7e9, 0, 8), 1e-9);
    try std.testing.expectApproxEqAbs(38.5, gigabytes(7e9, 1, 8), 1e-9);
    try std.testing.expectApproxEqAbs(26.25, gigabytes(7e9, 2, 8), 1e-9);
    try std.testing.expectApproxEqAbs(14.0, gigabytes(7e9, 3, 8), 1e-9); // fits on a 24 GB card
}
