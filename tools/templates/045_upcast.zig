//
// ─── Exercise 045: unroll and upcast ───────────────────────────────────
//
// A plain loop does one element per iteration, and every iteration also
// pays for bookkeeping: bump i, compare with n, jump back. And each add
// waits for the previous one to finish, because they all update the same
// `acc`.
//
// Unrolling by 4 fixes both: four elements per iteration, into four
// separate accumulators that don't wait on each other. Whatever is left
// over (n not divisible by 4) goes through a small cleanup loop:
//
//     for i in 0, 4, 8, ...:  acc0 += x[i]; acc1 += x[i+1]; acc2 += ...; acc3 += ...
//     for the last n % 4:     acc0 += x[i]
//     return acc0 + acc1 + acc2 + acc3
//
// Even better: chips have SIMD instructions that add 4 (or 8, 16...)
// floats at once. In Zig that's @Vector(4, f32): `+` on two vectors adds
// lane by lane, and @reduce(.Add, v) adds up the lanes at the end.
//
// tinygrad calls this optimization UPCAST: it turns one loop dimension
// into a small fixed-size one that becomes vector types (like float4) in
// the rendered code.
//
// Zig note: `x[i..][0..4]` is a pointer to 4 elements starting at i, and
// `.*` loads them. An array of 4 floats coerces to @Vector(4, f32).
//
// YOUR TASK: finish sumUnrolled() and sumVector().
//
const std = @import("std");

fn sumPlain(x: []const f32) f32 {
    var acc: f32 = 0;
    for (x) |v| acc += v;
    return acc;
}

fn sumUnrolled(x: []const f32) f32 {
    var acc: [4]f32 = @splat(0);
    var i: usize = 0;
    while (i + 4 <= x.len) : (i += 4) {
        acc[0] += x[i];
//⟪
        acc[1] += x[i + 1];
        acc[2] += x[i + 2];
        acc[3] += x[i + 3];
//|||
        ???
//⟫
    }
    // the leftovers
    while (i < x.len) : (i += 1) {
        ⟪acc[0] += x[i];|||???⟫
    }
    return acc[0] + acc[1] + acc[2] + acc[3];
}

fn sumVector(x: []const f32) f32 {
    var acc: @Vector(4, f32) = @splat(0);
    var i: usize = 0;
    while (i + 4 <= x.len) : (i += 4) {
        const v: @Vector(4, f32) = x[i..][0..4].*;
        ⟪acc += v;|||???⟫
    }
    var total: f32 = ⟪@reduce(.Add, acc)|||???⟫;
    while (i < x.len) : (i += 1) total += x[i];
    return total;
}

/// How many loop iterations (both loops together) for n elements?
fn iterations(n: usize, unroll: usize) usize {
    return ⟪n / unroll + n % unroll|||???⟫;
}

test "all three agree, for every length" {
    var data: [37]f32 = undefined;
    for (&data, 0..) |*d, i| d.* = @as(f32, @floatFromInt(i % 5)) - 1.5;
    for (0..data.len + 1) |n| {
        const x = data[0..n];
        try std.testing.expectApproxEqAbs(sumPlain(x), sumUnrolled(x), 1e-4);
        try std.testing.expectApproxEqAbs(sumPlain(x), sumVector(x), 1e-4);
    }
}

test "fewer iterations" {
    try std.testing.expectEqual(1000, iterations(1000, 1));
    try std.testing.expectEqual(250, iterations(1000, 4));
    try std.testing.expectEqual(253, iterations(1003, 4));
}
