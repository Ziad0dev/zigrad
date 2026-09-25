//
// ─── Exercise 175: mixture of experts ─────────────────────────────────
//
// Bigger models tend to be better, but every parameter costs compute on
// every token. A *mixture of experts* (MoE) layer breaks that link: it
// holds E separate MLPs ("experts"), and a small *router* sends each token
// to only k of them. Mixtral 8x7B has 8 experts per layer and uses 2 per
// token: it stores about 47B parameters but only computes with about 13B
// per token.
//
// Routing one token:
//   1. router logits: one score per expert (a linear layer, 082)
//   2. keep the top k experts (like 063's top-k)
//   3. softmax over just those k scores: the mixing weights
//   4. output = sum over the chosen experts of weight * expert(x)
//
// Two practical problems. If the router favours a few experts, they get
// overloaded while others idle, so training adds a *load-balancing* loss.
// And for efficient batched kernels, many implementations give each expert
// a fixed *capacity* of tokens per batch: tokens beyond it are *dropped*
// (they skip the layer, passing through the residual connection, 115).
// Counting how many tokens go to each expert is a histogram, and turning
// counts into buffer offsets is a prefix sum (169).
//
// YOUR TASK: pick the top-k experts, weight them, and count the load.
//
const std = @import("std");

const E = 4; // experts
const K = 2; // experts per token

/// Indices of the K largest logits, best first.
fn topK(logits: [E]f64) [K]usize {
    var chosen: [K]usize = undefined;
    var used = [_]bool{false} ** E;
    for (&chosen) |*c| {
        var best: ?usize = null;
        for (0..E) |e| {
            if (used[e]) continue;
            if (best == null or logits[e] > logits[best.?]) best = e;
        }
        c.* = best.?;
        ???;
    }
    return chosen;
}

/// Softmax over the chosen experts' logits only.
fn weights(logits: [E]f64, chosen: [K]usize) [K]f64 {
    const m = logits[chosen[0]]; // the biggest (018)
    var w: [K]f64 = undefined;
    var total: f64 = 0;
    for (&w, chosen) |*x, e| {
        x.* = ???;
        total += x.*;
    }
    for (&w) |*x| x.* /= total;
    return w;
}

/// A toy expert: expert e multiplies by e + 1.
fn expert(e: usize, x: f64) f64 {
    return x * @as(f64, @floatFromInt(e + 1));
}

fn moe(x: f64, logits: [E]f64) f64 {
    const chosen = topK(logits);
    const w = weights(logits, chosen);
    var out: f64 = 0;
    for (chosen, w) |e, wi| out += ???;
    return out;
}

/// Tokens routed to each expert (each token counts for all K of its choices).
fn load(all_logits: []const [E]f64) [E]usize {
    var counts = [_]usize{0} ** E;
    for (all_logits) |l| {
        for (topK(l)) |e| ???;
    }
    return counts;
}

test "routing one token" {
    const logits = [E]f64{ 0.1, 2.0, -1.0, 2.0 - @log(3.0) };
    const chosen = topK(logits);
    try std.testing.expectEqual([K]usize{ 1, 3 }, chosen);
    // e^0 : e^-ln3 = 3 : 1
    const w = weights(logits, chosen);
    try std.testing.expectApproxEqAbs(0.75, w[0], 1e-12);
    try std.testing.expectApproxEqAbs(0.25, w[1], 1e-12);
    // 0.75 * (2x) + 0.25 * (4x) at x = 1
    try std.testing.expectApproxEqAbs(2.5, moe(1, logits), 1e-12);
}

test "load per expert" {
    const tokens = [_][E]f64{
        .{ 3, 2, 0, 0 },
        .{ 3, 0, 2, 0 },
        .{ 3, 2, 0, 0 },
        .{ 0, 0, 1, 2 },
    };
    // expert 0 is picked by three tokens: a hot expert
    try std.testing.expectEqual([E]usize{ 3, 2, 2, 1 }, load(&tokens));
}
