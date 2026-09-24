// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 015: exp2 and log2 ───────────────────────────────────────
//
// Chapter 3: tinygrad's big simplification. It has only a few dozen
// primitive ops, and EVERYTHING else (softmax, matmul, convolution...)
// is built by combining them. A new chip only has to learn the
// primitives, and it runs all of deep learning.
//
// Let's start with exponentials. Chips don't have e^x built in. They have
// 2^x ("exp2") and log2, because floats are stored in base 2, so 2^x is
// mostly "put x into the exponent bits". tinygrad's primitives are EXP2
// and LOG2, and e^x and ln(x) are built from them by changing the base:
//
//     e^x   = 2^(x * log2(e))       because e = 2^log2(e)
//     ln(x) = log2(x) * ln(2)       because x = 2^log2(x) = e^(log2(x) * ln 2)
//
// log2(e) ≈ 1.4427 and ln(2) ≈ 0.6931 live in std.math as `log2e` and
// `ln2`.
//
// YOUR TASK: build exp, log and pow using only @exp2, @log2, * and +.
// (Using @exp or @log would work, but that's cheating.)
//
const std = @import("std");

fn exp(x: f32) f32 {
    return @exp2(x * std.math.log2e);
}

fn log(x: f32) f32 {
    return @log2(x) * std.math.ln2;
}

/// x to the power y, for x > 0. Use the same trick: x = 2^log2(x), so
/// x^y = 2^(y * log2(x)).
fn pow(x: f32, y: f32) f32 {
    return @exp2(y * @log2(x));
}

const tol = 1e-4;

test "exp" {
    try std.testing.expectApproxEqAbs(1.0, exp(0), tol);
    try std.testing.expectApproxEqAbs(2.71828, exp(1), tol);
    try std.testing.expectApproxEqAbs(0.135335, exp(-2), tol);
}

test "log" {
    try std.testing.expectApproxEqAbs(0.0, log(1), tol);
    try std.testing.expectApproxEqAbs(1.0, log(2.71828), tol);
    try std.testing.expectApproxEqAbs(3.0, log(exp(3)), tol);
}

test "pow" {
    try std.testing.expectApproxEqAbs(3.0, pow(9, 0.5), tol);
    try std.testing.expectApproxEqAbs(1024.0, pow(2, 10), 0.01);
}
