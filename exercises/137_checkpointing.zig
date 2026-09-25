//
// ─── Exercise 137: activation checkpointing ────────────────────────────
//
// Backward needs the forward pass's activations (x̂ in LayerNorm, 083;
// the inputs of every matmul, 035...). For n layers, that's n stored
// activations, and for big models activations use more memory than the
// weights.
//
// *Checkpointing* trades compute for memory: store only every k-th
// activation. During backward, when a segment's activations are needed,
// recompute them from the nearest checkpoint.
//
//     memory:  n / k checkpoints  +  k activations for the segment being
//              recomputed
//     compute: about one extra forward pass in total
//
// n/k + k is smallest at k = sqrt(n): 100 layers need about 20 stored
// activations instead of 100. (PyTorch offers this as
// torch.utils.checkpoint. It's also called rematerialization.)
//
// YOUR TASK: write the memory formula and find the best k.
//
const std = @import("std");

fn memory(n: usize, k: usize) usize {
    return ???; // checkpoints (rounded up) + one segment
}

fn bestK(n: usize) usize {
    var best: usize = 1;
    for (1..n + 1) |k| {
        if (???) best = k;
    }
    return best;
}

/// Counts forward-layer evaluations for one checkpointed forward+backward.
fn forwardEvals(n: usize, k: usize) usize {
    var evals: usize = n; // the normal forward pass
    // backward walks segments from the end; each is recomputed once
    var start: usize = 0;
    while (start < n) : (start += k) {
        const seg = @min(k, n - start);
        evals += ???; // its first activation is the stored checkpoint
    }
    return evals;
}

test "memory" {
    try std.testing.expectEqual(101, memory(100, 1)); // store everything (plus 1)
    try std.testing.expectEqual(20, memory(100, 10));
}

test "the best k is about sqrt(n)" {
    try std.testing.expectEqual(10, bestK(100));
    const k = bestK(10_000);
    try std.testing.expect(k >= 95 and k <= 105);
    try std.testing.expect(memory(10_000, k) <= 200); // instead of 10,000
}

test "the price: less than one extra forward pass" {
    try std.testing.expect(forwardEvals(100, 10) < 200);
}
