//
// ─── Exercise 070: derivatives of derivatives ──────────────────────────
//
// Because a gradient is a graph (069), you can take ITS gradient: the
// second derivative f''. That unlocks *Newton's method*.
//
// Root finding (where is f(x) = 0?): stand at x, follow the tangent line
// down to where it hits zero, and jump there:
//
//     x_new = x - f(x) / f'(x)
//
// For f(x) = x^2 - 2, that finds sqrt(2), and the number of correct
// digits roughly DOUBLES every step ("quadratic convergence"):
//     1.5, 1.4167, 1.41421569, 1.41421356237469, ...
//
// Minimizing: a minimum is where f'(x) = 0, so run Newton on f':
//
//     x_new = x - f'(x) / f''(x)
//
// Compared with gradient descent (032) there's no learning rate to tune:
// f'' tells you how curved the bowl is, so the step size picks itself.
// On a quadratic bowl, Newton lands in ONE step. The catch in deep
// learning: with n weights, f'' is an n x n matrix (the Hessian, 058),
// far too big to build and invert. So deep learning uses cheaper tricks
// that play a similar role, like Adam's per-weight step sizes (038).
//
// Everything here uses the graph engine from 069, finished.
//
// YOUR TASK: write the two Newton updates and build the second
// derivative.
//
const std = @import("std");

//@include expr_graph

//@include expr_grad

/// Root of f, from `start`. Returns x after `steps` steps.
fn newtonRoot(g: *Graph, f: *const Node, x: *const Node, start: f64, steps: usize) !f64 {
    const df = try grad(g, f, x);
    var v = start;
    for (0..steps) |_| v = ⟪v - eval(f, v) / eval(df, v)|||???⟫;
    return v;
}

/// A minimum of f, from `start`.
fn newtonMin(g: *Graph, f: *const Node, x: *const Node, start: f64, steps: usize) !f64 {
    const df = try grad(g, f, x);
    const ddf = ⟪try grad(g, df, x)|||???⟫;
    var v = start;
    for (0..steps) |_| v = ⟪v - eval(df, v) / eval(ddf, v)|||???⟫;
    return v;
}

test "square root of 2, digits doubling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const x = g.variable("x");
    const f = g.add(g.mul(x, x), g.constant(-2));

    const exact = @sqrt(2.0);
    try std.testing.expect(@abs(try newtonRoot(&g, f, x, 1, 2) - exact) < 1e-2);
    try std.testing.expect(@abs(try newtonRoot(&g, f, x, 1, 3) - exact) < 1e-5);
    try std.testing.expect(@abs(try newtonRoot(&g, f, x, 1, 5) - exact) < 1e-15);
}

test "a quadratic bowl in one step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const x = g.variable("x");
    // (x - 3)^2 + 1 = x*x - 6x + 10
    const f = g.add(g.add(g.mul(x, x), g.mul(g.constant(-6), x)), g.constant(10));
    try std.testing.expectApproxEqAbs(3.0, try newtonMin(&g, f, x, -50, 1), 1e-12);
}

test "a wiggly function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const x = g.variable("x");
    // x^2 + 2 sin(x): its minimum is where 2x + 2cos(x) = 0
    const f = g.add(g.mul(x, x), g.mul(g.constant(2), g.sin(x)));
    const m = try newtonMin(&g, f, x, 0, 6);
    try std.testing.expectApproxEqAbs(0.0, 2 * m + 2 * @cos(m), 1e-12);
    try std.testing.expectApproxEqAbs(-0.739085, m, 1e-6);
}
