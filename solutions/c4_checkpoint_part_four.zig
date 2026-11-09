// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Checkpoint 4: Part IV, from memory ───────────────────────────────
//
// No blanks, nothing new: five functions from the four chapters of Part
// IV. Try each cold. If you have to look one up, read YOUR finished
// exercise (its number is in the doc comment), close it, and write it
// from memory.
//
// YOUR TASK: write amdahl(), warpSum(), prefixSum(), rmsNorm() and topP().
//
const std = @import("std");

/// (164) Amdahl's law: the speedup on n workers of a program of which the
/// fraction `serial` can't be parallelized.
fn amdahl(serial: f64, n: f64) f64 {
    return 1 / (serial + (1 - serial) / n);
}

/// (168) Sum a warp's 32 lanes the way the GPU does: in 5 butterfly steps
/// (offsets 16, 8, 4, 2, 1). In each step EVERY lane adds the value its
/// partner, lane XOR offset, had before the step. Afterwards every lane
/// holds the total.
fn warpSum(lanes: *[32]f32) void {
    var offset: usize = 16;
    while (offset > 0) : (offset >>= 1) {
        const old = lanes.*;
        for (lanes, 0..) |*v, i| v.* += old[i ^ offset];
    }
}

/// (169) A parallel prefix sum (Hillis-Steele): x[i] becomes x[0] + ... +
/// x[i]. In the step with distance d (1, 2, 4, ...) every element at
/// i >= d adds the OLD value d places to its left. `tmp` is as long as x.
/// Returns the number of steps taken.
fn prefixSum(x: []f32, tmp: []f32) usize {
    var steps: usize = 0;
    var d: usize = 1;
    while (d < x.len) : (d *= 2) {
        @memcpy(tmp, x);
        for (d..x.len) |i| x[i] = tmp[i] + tmp[i - d];
        steps += 1;
    }
    return steps;
}

const eps = 1e-6;

/// (171) RMSNorm: x divided by its root mean square (eps goes under the
/// square root, with the mean of squares), times the gain g, element by
/// element. No mean is subtracted.
fn rmsNorm(x: []const f64, g: []const f64, y: []f64) void {
    var sq: f64 = 0;
    for (x) |v| sq += v * v;
    const rms = @sqrt(sq / @as(f64, @floatFromInt(x.len)) + eps);
    for (x, g, y) |v, gain, *o| o.* = gain * v / rms;
}

/// (174) Nucleus sampling's filter: keep the smallest set of the most
/// likely tokens whose probabilities add up to at least p, zero the rest,
/// and renormalize what's kept so it sums to 1. Returns how many were
/// kept. There are at most 64 tokens, and no two are equally likely.
fn topP(probs: []f64, p: f64) usize {
    var kept = [_]bool{false} ** 64;
    var total: f64 = 0;
    var count: usize = 0;
    while (total < p and count < probs.len) {
        // the most likely token not kept yet
        var best: ?usize = null;
        for (probs, 0..) |v, i| {
            if (!kept[i] and (best == null or v > probs[best.?])) best = i;
        }
        kept[best.?] = true;
        total += probs[best.?];
        count += 1;
    }
    for (probs, 0..) |*v, i| v.* = if (kept[i]) v.* / total else 0;
    return count;
}

const t = std.testing;

test "Amdahl" {
    try t.expectApproxEqAbs(1, amdahl(0.1, 1), 1e-12);
    try t.expectApproxEqAbs(1.0 / (0.1 + 0.9 / 8.0), amdahl(0.1, 8), 1e-12); // 4.7x on 8 workers
    try t.expectApproxEqAbs(16, amdahl(0, 16), 1e-12);
    try t.expectApproxEqAbs(1, amdahl(1, 16), 1e-12);
    try t.expect(amdahl(0.1, 1e9) < 10); // the ceiling is 1 / serial
    try t.expect(amdahl(0.1, 1e9) > 9.99);
}

test "a warp sum by shuffles" {
    var lanes: [32]f32 = undefined;
    for (&lanes, 0..) |*v, i| v.* = @floatFromInt(i * i);
    warpSum(&lanes);
    for (lanes) |v| try t.expectEqual(10416, v); // 0 + 1 + 4 + ... + 31^2, in EVERY lane
    var one = [_]f32{0} ** 32;
    one[13] = 7;
    warpSum(&one);
    for (one) |v| try t.expectEqual(7, v);
}

test "a parallel prefix sum" {
    var x = [_]f32{ 3, 1, 4, 1, 5, 9, 2, 6 };
    var tmp: [8]f32 = undefined;
    try t.expectEqual(3, prefixSum(&x, &tmp)); // log2(8)
    try t.expectEqualSlices(f32, &.{ 3, 4, 8, 9, 14, 23, 25, 31 }, &x);
    // a length that isn't a power of two
    var y = [_]f32{ 1, 1, 1, 1, 1 };
    try t.expectEqual(3, prefixSum(&y, tmp[0..5])); // d = 1, 2, 4
    try t.expectEqualSlices(f32, &.{ 1, 2, 3, 4, 5 }, &y);
    var z = [_]f32{42};
    try t.expectEqual(0, prefixSum(&z, tmp[0..1]));
    try t.expectEqual(42, z[0]);
}

test "RMSNorm" {
    var y: [4]f64 = undefined;
    // rms of (3, -4, 0, 0) is sqrt(25 / 4) = 2.5
    rmsNorm(&.{ 3, -4, 0, 0 }, &.{ 1, 1, 1, 1 }, &y);
    try t.expectApproxEqAbs(1.2, y[0], 1e-6);
    try t.expectApproxEqAbs(-1.6, y[1], 1e-6);
    try t.expectEqual(0, y[2]);
    // the mean is NOT removed: a constant row stays constant, at +-1
    rmsNorm(&.{ 5, 5, 5, 5 }, &.{ 1, 2, -1, 0 }, &y);
    try t.expectApproxEqAbs(1, y[0], 1e-6);
    try t.expectApproxEqAbs(2, y[1], 1e-6);
    try t.expectApproxEqAbs(-1, y[2], 1e-6);
    try t.expectEqual(0, y[3]);
    // eps is under the root: sqrt(0 + 1e-6) = 1e-3, so 0 / 1e-3 is 0, not nan
    rmsNorm(&.{ 0, 0, 0, 0 }, &.{ 1, 1, 1, 1 }, &y);
    for (y) |v| try t.expectEqual(0, v);
    rmsNorm(&.{ 1e-3, 0, 0, 0 }, &.{ 1, 1, 1, 1 }, &y);
    try t.expectApproxEqAbs(1e-3 / @sqrt(0.25e-6 + 1e-6), y[0], 1e-9);
}

test "top-p" {
    var probs = [_]f64{ 0.1, 0.5, 0.05, 0.3, 0.05 };
    // 0.5 + 0.3 = 0.8 reaches 0.75: two tokens survive
    try t.expectEqual(2, topP(&probs, 0.75));
    try t.expectApproxEqAbs(0.625, probs[1], 1e-12);
    try t.expectApproxEqAbs(0.375, probs[3], 1e-12);
    try t.expectEqual(0, probs[0]);
    try t.expectEqual(0, probs[2]);
    // exactly reaching p is enough
    var exact = [_]f64{ 0.25, 0.5, 0.125, 0.125 };
    try t.expectEqual(2, topP(&exact, 0.75));
    try t.expectEqual(0, exact[2]);
    // a confident model keeps one token
    var sure = [_]f64{ 0.02, 0.97, 0.01 };
    try t.expectEqual(1, topP(&sure, 0.9));
    try t.expectEqual(1, sure[1]);
    // the full 64 tokens, all kept
    var many: [64]f64 = undefined;
    for (&many, 0..) |*m, i| m.* = @as(f64, @floatFromInt(i + 1)) / 2080.0; // 1 + 2 + ... + 64 = 2080
    try t.expectEqual(64, topP(&many, 1));
    try t.expectApproxEqAbs(64.0 / 2080.0, many[63], 1e-12);
    // p = 1 keeps everything, unchanged
    var all = [_]f64{ 0.25, 0.5, 0.125, 0.0625, 0.0625 };
    try t.expectEqual(5, topP(&all, 1));
    try t.expectApproxEqAbs(0.0625, all[4], 1e-12);
}
