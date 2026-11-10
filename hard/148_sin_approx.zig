// HARD MODE (zig build -Dhard): no blanks to fill in. Every function
// marked ??? has lost its whole body: write it, from its doc comment,
// its signature and the tests. The gentler version of this file is in
// exercises/, and the answer in solutions/.
//
// ─── Exercise 148: computing sin from scratch ──────────────────────────
//
// Same recipe for sin (tinygrad's SIN is a primitive too, with the same
// kind of fallback):
//
//   1. sin repeats every 2π, so subtract the nearest multiple of 2π:
//          r = x - k * 2π,   k = round(x / 2π),   r in [-π, π]
//   2. sin(π - r) = sin(r) folds [π/2, π] onto [0, π/2] (and the same on
//      the negative side), so r ends up in [-π/2, π/2]
//   3. Taylor series, odd powers only:
//          sin r = r - r³/3! + r⁵/5! - ...
//      each term = previous * (-r²) / ((2k)(2k + 1))
//
// (Huge x is a real problem: k * 2π rounds, and the reduced r can be
// garbage. Serious libraries use extra-precise tricks for that: tinygrad's
// xsin switches to the Payne-Hanek reduction for big inputs. We stay
// with moderate inputs.)
//
// YOUR TASK: the two reductions and the series step.
//
const std = @import("std");

fn sinApprox(x: f64) f64 {
    ???; // write this function's body
}

test "matches @sin" {
    var x: f64 = -50;
    while (x < 50) : (x += 0.113) {
        try std.testing.expectApproxEqAbs(@sin(x), sinApprox(x), 1e-12);
    }
}
