//
// ─── Exercise 150: computing log2 from scratch ─────────────────────────
//
// log2 is the other half of 015's pair. Range reduction goes through the
// float format again: every positive f64 is m * 2^e, with m in [1, 2):
//
//     log2(x) = e + log2(m)
//
//   * e is the exponent field minus 1023:  ((bits >> 52) & 0x7FF) - 1023
//   * m is the fraction bits with the exponent field set to 1023 (so the
//     value is 1.fraction):  (bits & fraction_mask) | (1023 << 52)
//
// For log(m) with m in [1, 2), a series that converges fast: with
// s = (m - 1)/(m + 1), which lies in [0, 1/3],
//
//     ln(m) = 2 (s + s³/3 + s⁵/5 + s⁷/7 + ...)
//
// and log2(m) = ln(m) / ln 2 (015).
//
// YOUR TASK: extract e and m, and sum the series.
//
const std = @import("std");

const fraction_mask: u64 = (1 << 52) - 1;

fn log2Approx(x: f64) f64 {
    const bits: u64 = @bitCast(x);
    const e: i64 = ???;
    const m: f64 = @bitCast(???);

    const s = (m - 1) / (m + 1);
    const s2 = s * s;
    var power = s;
    var sum: f64 = 0;
    var k: f64 = 1;
    while (k < 40) : (k += 2) {
        sum += ???;
        power *= s2;
    }
    return @as(f64, @floatFromInt(e)) + 2 * sum / std.math.ln2;
}

test "matches @log2" {
    var x: f64 = 1e-30;
    while (x < 1e30) : (x *= 1.9) {
        try std.testing.expectApproxEqAbs(@log2(x), log2Approx(x), 1e-12);
    }
    try std.testing.expectEqual(10, log2Approx(1024));
}
