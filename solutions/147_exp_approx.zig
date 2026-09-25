// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 147: computing exp2 from scratch ─────────────────────────
//
// We've used @exp2 as a primitive since 015. But on some chips, or in
// some backends, there's no such instruction, and the kernel must
// compute it from + and *. tinygrad has exactly this code (in its
// "transcendental" functions) for backends that lack them.
//
// The standard recipe, *range reduction* then a *polynomial*:
//
//   1. split x = n + f, with n = round(x) an integer and f in [-0.5, 0.5]
//   2. 2^x = 2^n * 2^f
//   3. 2^n is free: it's just the float's exponent field (049). An f64
//      with exponent bits (n + 1023) and zero fraction IS 2^n:
//          bits = (n + 1023) << 52
//   4. 2^f = e^(f ln 2), and on such a small range a short Taylor series
//      is extremely accurate:
//          e^y = 1 + y + y²/2! + y³/3! + ...     (each term = previous * y / k)
//
// Range reduction is the key idea: every hard function is made easy on a
// small interval, and some identity maps the whole input range onto it.
//
// YOUR TASK: split x, build 2^n from bits, and sum the series.
//
const std = @import("std");

fn exp2Approx(x: f64) f64 {
    const n = @round(x);
    const f = x - n;

    // 2^f = e^(f ln 2), Taylor series
    const y = f * std.math.ln2;
    var term: f64 = 1;
    var sum: f64 = 1;
    for (1..16) |k| {
        term *= y / @as(f64, @floatFromInt(k));
        sum += term;
    }

    // 2^n straight from the exponent bits
    const e: u64 = @intCast(@as(i64, @intFromFloat(n)) + 1023);
    const two_n: f64 = @bitCast(e << 52);
    return sum * two_n;
}

test "matches @exp2 to 12+ digits" {
    var x: f64 = -60;
    while (x < 60) : (x += 0.37) {
        try std.testing.expectApproxEqRel(@exp2(x), exp2Approx(x), 1e-13);
    }
    try std.testing.expectEqual(1024, exp2Approx(10));
}
