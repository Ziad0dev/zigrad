// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 133: line search ─────────────────────────────────────────
//
// Choosing a learning rate is annoying (032, 058). Classic optimization
// avoids it: at each step, TRY a step size, and shrink it until the step
// actually helps enough.
//
// Backtracking with the *Armijo condition*: start with t = 1 and halve t
// until
//
//     f(x - t g) <= f(x) - c t |g|²          (c small, like 0.5)
//
// i.e. the loss dropped by at least a fraction c of what the slope
// promised. Too big a step overshoots and fails the test, and gets halved.
//
// Deep learning rarely uses line search: evaluating the loss on a whole
// dataset twice per step is too expensive, and with mini-batches (102)
// the loss is noisy anyway. But it's why classic optimizers "just work",
// and it's used inside L-BFGS, a popular optimizer for small problems.
//
// YOUR TASK: write the backtracking loop.
//
const std = @import("std");

fn f(x: [2]f64) f64 {
    return 10 * x[0] * x[0] + 0.5 * x[1] * x[1]; // a narrow valley
}

fn grad(x: [2]f64) [2]f64 {
    return .{ 20 * x[0], x[1] };
}

fn backtrack(x: [2]f64, g: [2]f64, c: f64) f64 {
    const g2 = g[0] * g[0] + g[1] * g[1];
    var t: f64 = 1;
    while (f(.{ x[0] - t * g[0], x[1] - t * g[1] }) > f(x) - c * t * g2) {
        t /= 2;
    }
    return t;
}

fn descend(start: [2]f64, steps: usize, fixed_lr: ?f64) f64 {
    var x = start;
    for (0..steps) |_| {
        const g = grad(x);
        const t = fixed_lr orelse backtrack(x, g, 0.5);
        x = .{ x[0] - t * g[0], x[1] - t * g[1] };
    }
    return f(x);
}

test "no learning rate to tune" {
    try std.testing.expect(descend(.{ 1, 1 }, 200, null) < 1e-6);
}

test "the fixed learning rate a line search avoids" {
    // λmax = 20, so lr must stay below 2/20 = 0.1 (058)
    try std.testing.expect(descend(.{ 1, 1 }, 100, 0.12) > 1e6);
}
