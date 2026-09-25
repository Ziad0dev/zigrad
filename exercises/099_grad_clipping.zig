//
// ─── Exercise 099: gradient clipping ───────────────────────────────────
//
// Every so often a batch produces a gigantic gradient: a weird example, a
// cliff in the loss surface. One step with it can undo hours of training.
// *Gradient clipping* caps the step size:
//
//     norm = sqrt(sum of g^2 over EVERY parameter of the model)
//     if norm > max_norm:  multiply every gradient by max_norm / norm
//
// It's the length of the whole gradient vector, treating all parameters
// as one giant vector (054), hence "global norm". Scaling everything by
// the same factor keeps the DIRECTION of the step and only shortens it.
// Clipping each number separately would change the direction.
//
// Most LLM training runs clip to a max norm of 1.0 (GPT-3 and LLaMA did).
//
// YOUR TASK: write globalNorm() and clip().
//
const std = @import("std");

fn globalNorm(grads: []const []const f64) f64 {
    var sq: f64 = 0;
    for (grads) |g| {
        for (g) |x| sq += ???;
    }
    return ???;
}

/// Returns the norm before clipping.
fn clip(grads: []const []f64, max_norm: f64) f64 {
    var views: [8][]const f64 = undefined;
    for (grads, 0..) |g, i| views[i] = g;
    const norm = globalNorm(views[0..grads.len]);
    if (norm > max_norm) {
        const factor = ???;
        for (grads) |g| {
            for (g) |*x| x.* *= factor;
        }
    }
    return norm;
}

test "a huge gradient gets shortened to max_norm" {
    var w1 = [_]f64{ 30, 40 }; //  one layer's grads
    var w2 = [_]f64{ 0, 0, 120 }; // another's
    const before = clip(&.{ &w1, &w2 }, 1.0);
    try std.testing.expectApproxEqAbs(130.0, before, 1e-12); // sqrt(900 + 1600 + 14400)
    try std.testing.expectApproxEqAbs(1.0, globalNorm(&.{ &w1, &w2 }), 1e-12);
    // same direction: every entry scaled by the same factor
    try std.testing.expectApproxEqAbs(30.0 / 130.0, w1[0], 1e-12);
    try std.testing.expectApproxEqAbs(120.0 / 130.0, w2[2], 1e-12);
}

test "a normal gradient is left alone" {
    var w = [_]f64{ 0.3, -0.4 };
    _ = clip(&.{&w}, 1.0);
    try std.testing.expectEqualSlices(f64, &.{ 0.3, -0.4 }, &w);
}
