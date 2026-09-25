//
// ─── Exercise 168: warp shuffles ──────────────────────────────────────
//
// 078 summed a block through shared memory, with a barrier between every
// step. Inside ONE warp there's a faster way: *shuffle* instructions let a
// thread read another thread's register directly, no shared memory, no
// block-wide barrier: the lanes named in the mask swap values in a single
// instruction.
//
//     __shfl_xor_sync(mask, v, offset)   CUDA: "give me the v of the lane
//                                        whose id is mine XOR offset"
//
// The butterfly reduction: every lane adds the value from lane ^ 16, then
// lane ^ 8, ^ 4, ^ 2, ^ 1. Five steps for 32 lanes (log2 32), and
// afterwards EVERY lane holds the full sum, not just lane 0:
//
//     step offset 16: lane 0 += lane 16, lane 16 += lane 0, ...
//     step offset  8: lane 0 += lane 8,  lane 8 += lane 0,  ...
//     ...
//
// Why XOR? Each step pairs every lane with exactly one partner, and the
// two swap values, so afterwards both hold the same partial sum and
// nobody's work is wasted. Fast reductions (softmax's max and sum,
// LayerNorm's mean) do a warp shuffle first, and touch shared memory only
// to combine warps.
//
// The simulation below runs each step for all 32 lanes "at once": every
// lane reads the OLD values, then all of them write.
//
// YOUR TASK: the shuffle, and the butterfly loop.
//
const std = @import("std");

const warp = 32;
const Lanes = [warp]f32;

/// Every lane i gets the value of lane i ^ offset.
fn shflXor(v: Lanes, offset: usize) Lanes {
    var out: Lanes = undefined;
    for (&out, 0..) |*o, lane| o.* = ⟪v[lane ^ offset]|||???⟫;
    return out;
}

/// Butterfly sum: afterwards every lane holds the total.
fn warpSum(v: Lanes) Lanes {
    var x = v;
    var offset: usize = warp / 2;
    while (offset > 0) : (offset /= 2) {
        const other = shflXor(x, offset);
        for (&x, other) |*a, b| ⟪a.* += b;|||???;⟫
    }
    return x;
}

/// Same shape of loop for max: the identity doesn't matter, every lane
/// starts with a real value.
fn warpMax(v: Lanes) Lanes {
    var x = v;
    var offset: usize = warp / 2;
    while (offset > 0) : (offset /= 2) {
        const other = shflXor(x, offset);
        for (&x, other) |*a, b| a.* = ⟪@max(a.*, b)|||???⟫;
    }
    return x;
}

test "a shuffle swaps partners" {
    var v: Lanes = undefined;
    for (&v, 0..) |*x, i| x.* = @floatFromInt(i);
    const s = shflXor(v, 1);
    try std.testing.expectEqual(1, s[0]);
    try std.testing.expectEqual(0, s[1]);
    try std.testing.expectEqual(31, shflXor(v, 16)[15]);
}

test "every lane ends with the sum" {
    var v: Lanes = undefined;
    for (&v, 0..) |*x, i| x.* = @floatFromInt(i);
    const s = warpSum(v);
    for (s) |x| try std.testing.expectEqual(496, x); // 0 + 1 + ... + 31
}

test "and with the max" {
    var v: Lanes = undefined;
    for (&v, 0..) |*x, i| x.* = @floatFromInt((i * 7) % 32);
    v[13] = 100;
    for (warpMax(v)) |x| try std.testing.expectEqual(100, x);
}
