// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 016: everything from primitives ──────────────────────────
//
// Below, `P` holds a small set of primitive ops like tinygrad's, working
// on single numbers.
// Your job: build the rest using ONLY things from P (and constants).
//
// The ones you'll build:
//
//   sub(a, b)  = a + (-b)
//   div(a, b)  = a * (1 / b)
//   relu(x)    = max(x, 0)
//   abs(x)     = -x if x < 0, else x          (P.where picks one of two)
//
//   sigmoid(x) = 1 / (1 + e^(-x))
//       Squashes any number into (0, 1). Big positive -> ~1, big
//       negative -> ~0, sigmoid(0) = 0.5. Handy for probabilities.
//
//   tanh(x)    = 2 * sigmoid(2x) - 1
//       Squashes into (-1, 1). Why does that identity hold? Put sigmoid's
//       formula in and multiply top and bottom by e^x:
//           2 / (1 + e^(-2x)) - 1 = (1 - e^(-2x)) / (1 + e^(-2x))
//                                 = (e^x - e^(-x)) / (e^x + e^(-x))
//       which is the textbook definition of tanh.
//
// Why bother? Every op built from primitives gets gradients (chapter 5)
// and GPU support (chapter 8) for free.
//
// YOUR TASK: replace each ???. Only use P, exp, and functions you've
// already written in this file.
//
const std = @import("std");

/// A small set of primitive ops, tinygrad style.
const P = struct {
    fn add(a: f32, b: f32) f32 {
        return a + b;
    }
    fn mul(a: f32, b: f32) f32 {
        return a * b;
    }
    fn neg(a: f32) f32 {
        return -a;
    }
    fn recip(a: f32) f32 {
        return 1 / a;
    }
    fn exp2(a: f32) f32 {
        return @exp2(a);
    }
    fn max(a: f32, b: f32) f32 {
        return @max(a, b);
    }
    fn cmplt(a: f32, b: f32) bool {
        return a < b;
    }
    fn where(cond: bool, a: f32, b: f32) f32 {
        return if (cond) a else b;
    }
};

// Exercise 015's exp, written with P.
fn exp(x: f32) f32 {
    return P.exp2(P.mul(x, std.math.log2e));
}

fn sub(a: f32, b: f32) f32 {
    return P.add(a, P.neg(b));
}

fn div(a: f32, b: f32) f32 {
    return P.mul(a, P.recip(b));
}

fn relu(x: f32) f32 {
    return P.max(x, 0);
}

fn abs(x: f32) f32 {
    return P.where(P.cmplt(x, 0), P.neg(x), x);
}

fn sigmoid(x: f32) f32 {
    return P.recip(P.add(1, exp(P.neg(x))));
}

fn tanh(x: f32) f32 {
    return sub(P.mul(2, sigmoid(P.mul(2, x))), 1);
}

const tol = 1e-5;

test "the easy ones" {
    try std.testing.expectApproxEqAbs(-1.0, sub(2, 3), tol);
    try std.testing.expectApproxEqAbs(2.5, div(5, 2), tol);
    try std.testing.expectEqual(0, relu(-4));
    try std.testing.expectEqual(4, relu(4));
    try std.testing.expectEqual(3, abs(-3));
    try std.testing.expectEqual(3, abs(3));
}

test "sigmoid and tanh" {
    for ([_]f32{ -5, -1, 0, 0.5, 3 }) |x| {
        try std.testing.expectApproxEqAbs(1 / (1 + @exp(-x)), sigmoid(x), tol);
        try std.testing.expectApproxEqAbs(std.math.tanh(x), tanh(x), tol);
    }
    try std.testing.expectApproxEqAbs(0.5, sigmoid(0), tol);
}
