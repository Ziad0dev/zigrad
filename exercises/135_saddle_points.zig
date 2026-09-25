//
// ─── Exercise 135: saddle points ───────────────────────────────────────
//
// Where the gradient is zero, you're at a *critical point*. In 1D that's
// a minimum or a maximum. In more dimensions there's a third kind, a
// *saddle*: up in one direction, down in another, like f(x, y) = x² - y².
//
// The Hessian's eigenvalues (058) tell them apart:
//     all positive     minimum
//     all negative     maximum
//     mixed signs      saddle
//
// For a symmetric 2x2 Hessian | a b |, the eigenvalues have a closed form:
//                             | b c |
//     λ = (a + c)/2 ± sqrt( ((a - c)/2)^2 + b^2 )
//
// In high dimensions saddles vastly outnumber minima (every direction
// would have to curve up for a minimum). Plain gradient descent slows to
// a crawl near a saddle, but any tiny push along the downhill direction
// grows exponentially (1 + lr * |λ| per step, 113's maths in reverse), so
// noisy SGD escapes. That's partly why deep learning works despite
// non-convexity (131).
//
// YOUR TASK: write the eigenvalues and the classification.
//
const std = @import("std");

const Kind = enum { minimum, maximum, saddle };

fn eigenvalues(a: f64, b: f64, c: f64) [2]f64 {
    const mid = (a + c) / 2;
    const rad = ???;
    return .{ mid - rad, mid + rad };
}

fn classify(a: f64, b: f64, c: f64) Kind {
    const l = eigenvalues(a, b, c);
    if (???) return .minimum;
    if (???) return .maximum;
    return .saddle;
}

test "eigenvalues" {
    const l = eigenvalues(2, 1, 2);
    try std.testing.expectApproxEqAbs(1.0, l[0], 1e-12);
    try std.testing.expectApproxEqAbs(3.0, l[1], 1e-12);
}

test "classifying critical points" {
    try std.testing.expectEqual(.minimum, classify(2, 0, 2)); //    x² + y²
    try std.testing.expectEqual(.maximum, classify(-2, 0, -2)); //  -x² - y²
    try std.testing.expectEqual(.saddle, classify(2, 0, -2)); //    x² - y²
    try std.testing.expectEqual(.saddle, classify(0, 1, 0)); //     2xy, a rotated saddle
}

test "gradient descent escapes a saddle, slowly" {
    // f = x² - y², start almost exactly at the saddle
    var x: f64 = 1;
    var y: f64 = 1e-8;
    for (0..60) |_| {
        const gx = 2 * x;
        const gy = -2 * y;
        x -= 0.1 * gx;
        y -= 0.1 * gy;
    }
    try std.testing.expect(@abs(x) < 1e-5); // x settled...
    try std.testing.expect(@abs(y) > 1e-4); // ...y grew by 1.2^60, about 56,000x
}
