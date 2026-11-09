// HARD MODE (zig build -Dhard): no blanks to fill in. Every function
// marked ??? has lost its whole body: write it, from its doc comment,
// its signature and the tests. The gentler version of this file is in
// exercises/, and the answer in solutions/.
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
    ???; // write this function's body
}

test "matches @log2" {
    var x: f64 = 1e-30;
    while (x < 1e30) : (x *= 1.9) {
        try std.testing.expectApproxEqAbs(@log2(x), log2Approx(x), 1e-12);
    }
    try std.testing.expectEqual(10, log2Approx(1024));
}
