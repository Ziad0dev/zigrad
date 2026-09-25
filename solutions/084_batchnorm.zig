// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 084: BatchNorm, and train vs eval ────────────────────────
//
// BatchNorm is LayerNorm's older sibling, still the standard in CNNs. It
// normalizes each FEATURE (column) across the batch, instead of each
// example across its features:
//
//     LayerNorm:  mean/variance of each ROW      (one example)
//     BatchNorm:  mean/variance of each COLUMN   (one feature, all examples)
//
// That creates a problem at inference time, when you might have ONE
// example (a batch of 1 has variance 0!). So BatchNorm behaves
// differently in the two modes:
//
//   training:  use this batch's statistics, and update running averages
//                  running = (1 - momentum) * running + momentum * batch_stat
//   eval:      use the running averages, so each output depends only on
//              its own input
//
// Forgetting to switch modes is a classic bug, and it's why tinygrad (like
// PyTorch) has Tensor.training, a flag layers like BatchNorm and Dropout
// (089) check.
//
// (The backward pass is LayerNorm's, applied down columns instead of along
// rows.)
//
// YOUR TASK: finish the batch statistics, the running update and eval mode.
//
const std = @import("std");

const eps = 1e-5;

const BatchNorm = struct {
    n: usize, // features
    momentum: f64 = 0.1,
    running_mean: []f64,
    running_var: []f64,

    fn forward(bn: BatchNorm, x: []const f64, batch: usize, y: []f64, training: bool) void {
        const bf: f64 = @floatFromInt(batch);
        for (0..bn.n) |j| {
            var mu: f64 = undefined;
            var v2: f64 = undefined;
            if (training) {
                mu = 0;
                for (0..batch) |r| mu += x[r * bn.n + j] / bf;
                v2 = 0;
                for (0..batch) |r| v2 += (x[r * bn.n + j] - mu) * (x[r * bn.n + j] - mu) / bf;
                bn.running_mean[j] = (1 - bn.momentum) * bn.running_mean[j] + bn.momentum * mu;
                bn.running_var[j] = (1 - bn.momentum) * bn.running_var[j] + bn.momentum * v2;
            } else {
                mu = bn.running_mean[j];
                v2 = bn.running_var[j];
            }
            for (0..batch) |r| y[r * bn.n + j] = (x[r * bn.n + j] - mu) / @sqrt(v2 + eps);
        }
    }
};

test "training mode normalizes each feature over the batch" {
    var rm = [_]f64{ 0, 0 };
    var rv = [_]f64{ 1, 1 };
    const bn: BatchNorm = .{ .n = 2, .running_mean = &rm, .running_var = &rv };
    const x = [_]f64{ 1, 100, 2, 200, 3, 300, 4, 400 }; // 4 examples, 2 features
    var y: [8]f64 = undefined;
    bn.forward(&x, 4, &y, true);
    for (0..2) |j| {
        var m: f64 = 0;
        for (0..4) |r| m += y[r * 2 + j] / 4;
        try std.testing.expectApproxEqAbs(0.0, m, 1e-9);
    }
}

test "running averages learn the data's statistics" {
    var rm = [_]f64{0};
    var rv = [_]f64{1};
    const bn: BatchNorm = .{ .n = 1, .running_mean = &rm, .running_var = &rv };
    var prng = std.Random.DefaultPrng.init(84);
    var x: [64]f64 = undefined;
    var y: [64]f64 = undefined;
    for (0..300) |_| {
        for (&x) |*v| v.* = 5 + 2 * prng.random().floatNorm(f64); // mean 5, variance 4
        bn.forward(&x, 64, &y, true);
    }
    try std.testing.expectApproxEqAbs(5.0, rm[0], 0.2);
    try std.testing.expectApproxEqAbs(4.0, rv[0], 0.5);
}

test "eval mode: a batch of one works, and doesn't change the stats" {
    var rm = [_]f64{5};
    var rv = [_]f64{4};
    const bn: BatchNorm = .{ .n = 1, .running_mean = &rm, .running_var = &rv };
    var y: [1]f64 = undefined;
    bn.forward(&.{7}, 1, &y, false);
    try std.testing.expectApproxEqAbs(1.0, y[0], 1e-5); // (7 - 5) / 2
    try std.testing.expectEqual(5, rm[0]);
}
