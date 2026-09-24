//
// ─── Exercise 105: measuring a classifier properly ─────────────────────
//
// "95% accuracy" can hide a lot. If 95% of emails aren't spam, a model
// that ALWAYS says "not spam" is 95% accurate and completely useless.
// Better tools:
//
// The *confusion matrix* C[truth][predicted] counts every combination. The
// diagonal is correct answers; everything off it is a specific mistake
// ("7s get read as 1s").
//
// Per class c:
//   precision = C[c][c] / (column c's total)    "when I say c, am I right?"
//   recall    = C[c][c] / (row c's total)       "of the real c's, how many did I find?"
//   F1        = 2 * precision * recall / (precision + recall)
//               (their harmonic mean: high only if BOTH are high)
//
// The always-"not spam" model: recall for spam = 0, so F1 = 0. Caught.
//
// YOUR TASK: build the confusion matrix, and compute precision, recall
// and F1.
//
const std = @import("std");

const n_classes = 3;

fn confusion(truth: []const usize, predicted: []const usize) [n_classes][n_classes]usize {
    var c: [n_classes][n_classes]usize = @splat(@splat(0));
    for (truth, predicted) |t, p| ???;
    return c;
}

fn precision(c: [n_classes][n_classes]usize, class: usize) f64 {
    var said: usize = 0;
    for (0..n_classes) |t| said += ???;
    if (said == 0) return 0;
    return @as(f64, @floatFromInt(c[class][class])) / @as(f64, @floatFromInt(said));
}

fn recall(c: [n_classes][n_classes]usize, class: usize) f64 {
    var real: usize = 0;
    for (0..n_classes) |p| real += ???;
    if (real == 0) return 0;
    return @as(f64, @floatFromInt(c[class][class])) / @as(f64, @floatFromInt(real));
}

fn f1(p: f64, r: f64) f64 {
    if (p + r == 0) return 0;
    return ???;
}

fn accuracy(c: [n_classes][n_classes]usize) f64 {
    var right: usize = 0;
    var total: usize = 0;
    for (0..n_classes) |i| {
        for (0..n_classes) |j| {
            total += c[i][j];
            if (i == j) right += c[i][j];
        }
    }
    return @as(f64, @floatFromInt(right)) / @as(f64, @floatFromInt(total));
}

test "the confusion matrix" {
    const truth = [_]usize{ 0, 0, 0, 1, 1, 2, 2, 2, 2 };
    const guess = [_]usize{ 0, 0, 1, 1, 1, 2, 2, 0, 2 };
    const c = confusion(&truth, &guess);
    try std.testing.expectEqual([n_classes][n_classes]usize{ .{ 2, 1, 0 }, .{ 0, 2, 0 }, .{ 1, 0, 3 } }, c);

    try std.testing.expectApproxEqAbs(2.0 / 3.0, precision(c, 0), 1e-12); // said "0" 3 times, right twice
    try std.testing.expectApproxEqAbs(2.0 / 3.0, recall(c, 0), 1e-12); //    3 real 0s, found 2
    try std.testing.expectApproxEqAbs(2.0 / 3.0, precision(c, 1), 1e-12);
    try std.testing.expectApproxEqAbs(1.0, recall(c, 1), 1e-12);
    try std.testing.expectApproxEqAbs(0.8, f1(2.0 / 3.0, 1.0), 1e-12);
    try std.testing.expectApproxEqAbs(7.0 / 9.0, accuracy(c), 1e-12);
}

test "accuracy lies, F1 doesn't" {
    // 19 "not spam" (0) and 1 "spam" (1); the model always says 0
    var truth: [20]usize = @splat(0);
    truth[7] = 1;
    const lazy: [20]usize = @splat(0);
    const c = confusion(&truth, &lazy);
    try std.testing.expectApproxEqAbs(0.95, accuracy(c), 1e-12);
    try std.testing.expectEqual(0, f1(precision(c, 1), recall(c, 1)));
}
