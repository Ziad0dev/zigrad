//
// ─── Exercise 064: random numbers for a lazy, parallel world ───────────
//
// A normal random generator (like std.Random) has a *state* that every
// call updates: number 1000 can't be computed until 1 to 999 are done.
// That's a problem for tinygrad. Tensor.rand() is lazy, fused into
// kernels, and computed by thousands of GPU threads at once.
//
// The solution is a *counter-based* generator: random number i is just
// a scrambling hash of (seed, i):
//
//     rand(seed, i) = hash(seed, i)
//
// Every element can be computed independently, in any order, on any
// thread, and it's still reproducible. tinygrad uses Threefry, a
// counter-based generator built from 32-bit adds, rotations and xors.
// Here we use SplitMix64's mixer, which works the same way: multiply
// and xor-shift until every input bit affects every output bit.
//
// Bits to a float in [0, 1): an f32 has 24 bits of precision, so take
// the top 24 random bits and divide by 2^24.
//
// The exponent trick (used on GPUs, and by tinygrad): put 23 random bits
// into the fraction of the float 1.0 (bits 0x3F800000). That gives a
// number in [1, 2). Subtract 1.
//
// YOUR TASK: write uniform() and uniformFast().
//
const std = @import("std");

fn hash(seed: u64, counter: u64) u64 {
    var z = seed +% (counter +% 1) *% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// In [0, 1), from the top 24 bits.
fn uniform(seed: u64, i: u64) f32 {
    const bits = hash(seed, i) >> 40; // 24 bits left
    return ⟪@as(f32, @floatFromInt(bits)) / (1 << 24)|||???⟫;
}

/// In [0, 1), with the exponent trick.
fn uniformFast(seed: u64, i: u64) f32 {
    const frac: u32 = @truncate(hash(seed, i) >> 41); // 23 bits
    const one_to_two: f32 = @bitCast(⟪@as(u32, 0x3F800000) | frac|||???⟫);
    return ⟪one_to_two - 1|||???⟫;
}

test "in range, and uniform-ish" {
    var sum: f64 = 0;
    var sum_fast: f64 = 0;
    for (0..100_000) |i| {
        const u = uniform(42, i);
        const v = uniformFast(42, i);
        try std.testing.expect(u >= 0 and u < 1);
        try std.testing.expect(v >= 0 and v < 1);
        sum += u;
        sum_fast += v;
    }
    try std.testing.expectApproxEqAbs(0.5, sum / 100_000, 0.005);
    try std.testing.expectApproxEqAbs(0.5, sum_fast / 100_000, 0.005);
}

test "any order, same numbers" {
    var forward: [100]f32 = undefined;
    var backward: [100]f32 = undefined;
    for (0..100) |i| forward[i] = uniform(7, i);
    var i: usize = 100;
    while (i > 0) {
        i -= 1;
        backward[i] = uniform(7, i);
    }
    try std.testing.expectEqualSlices(f32, &forward, &backward);
}

test "different seeds, different numbers" {
    var same: usize = 0;
    for (0..1000) |j| {
        if (uniform(1, j) == uniform(2, j)) same += 1;
    }
    try std.testing.expect(same < 5);
}
