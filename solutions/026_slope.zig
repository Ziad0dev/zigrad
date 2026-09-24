// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 026: a derivative is a slope ─────────────────────────────
//
// Chapter 5 is the maths behind training: derivatives.
//
// The derivative f'(x) answers: "if I nudge x a tiny bit, how much does
// f(x) move, per unit of nudge?" Graphically, it's the slope of the curve
// at x. You can measure it:
//
//     f'(x) ≈ (f(x + h) - f(x)) / h           for a tiny h
//
// For f(x) = x^2 at x = 3, with h = 0.001:
//     (3.001^2 - 3^2) / 0.001 = (9.006001 - 9) / 0.001 = 6.001
// The true answer is 6 (you'll see why in the next exercise).
//
// Nudging both ways, the *central difference*, is far more accurate:
//
//     f'(x) ≈ (f(x + h) - f(x - h)) / (2h)
//
// Its error shrinks like h^2 instead of like h, because the leftover
// error terms of the two sides cancel. With h = 0.001: an error of about
// 0.000001 instead of 0.001.
//
// But h can't be TOO small. Remember exercise 002: x + h rounds, and you
// end up dividing a rounding error by a tiny number.
//
// Autograd won't measure slopes like this. It computes them exactly
// (exercise 030). But measuring is how we'll CHECK that autograd is
// right, and for that we use f64, which keeps about 16 digits.
//
// Zig note: `*const fn (f64) f64` is a pointer to a function that takes
// an f64 and returns one. `&square` makes one.
//
// YOUR TASK: write both formulas.
//
const std = @import("std");

fn forwardDiff(f: *const fn (f64) f64, x: f64, h: f64) f64 {
    return (f(x + h) - f(x)) / h;
}

fn centralDiff(f: *const fn (f64) f64, x: f64, h: f64) f64 {
    return (f(x + h) - f(x - h)) / (2 * h);
}

fn square(x: f64) f64 {
    return x * x;
}

fn cube(x: f64) f64 {
    return x * x * x;
}

test "the slope of x^2 at 3 is 6" {
    try std.testing.expectApproxEqAbs(6.0, forwardDiff(&square, 3, 1e-3), 1e-2);
    try std.testing.expectApproxEqAbs(6.0, centralDiff(&square, 3, 1e-3), 1e-6);
}

test "central difference is much more accurate" {
    const exact = 12.0; // the slope of x^3 at 2
    const forward_error = @abs(forwardDiff(&cube, 2, 1e-3) - exact);
    const central_error = @abs(centralDiff(&cube, 2, 1e-3) - exact);
    try std.testing.expect(central_error < forward_error / 100);
}

test "a too-small h in f32 gives garbage" {
    const x: f32 = 1;
    const h: f32 = 1e-7;
    const slope = ((x + h) * (x + h) - x * x) / h; // should be 2
    try std.testing.expect(@abs(slope - 2) > 0.1);
}
