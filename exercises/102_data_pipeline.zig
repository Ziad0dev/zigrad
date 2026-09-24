//
// ═══ Chapter 19: the capstone ══════════════════════════════════════════
//
// Four exercises, one project: train a real classifier end to end, the
// way you would with tinygrad. The data is a stand-in for MNIST, the
// classic handwritten-digit dataset: noisy 8x8 images of the digits 0-9,
// shifted around randomly.
//
// ─── Exercise 102: the data pipeline ───────────────────────────────────
//
// Before any model: getting data into it well.
//
// SHUFFLE every epoch. If the data came sorted (all the 0s, then all the
// 1s...), each batch would pull the model toward one class. The correct
// algorithm is *Fisher-Yates*: walk from the end, swapping each position
// i with a random position j in [0, i]. Every ordering comes out equally
// likely. (Swapping with ANY position, j in [0, n), sounds similar but
// is subtly biased.)
//
// BATCH: cut the shuffled indices into groups of `batch` examples. The
// last batch may be smaller.
//
// NORMALIZE: shift and scale each input feature (pixel) to mean 0 and
// standard deviation 1, using statistics of the TRAINING set only (the
// test set must stay unseen, 101). Inputs of wildly different sizes make
// training slow and unstable (037, 058).
//
// YOUR TASK: finish shuffle(), pixelStats(), normalize() and the batches.
//
const std = @import("std");

// ─── The dataset: noisy 8x8 digits ───
//
// Ten 5x7 digit shapes, placed at a random position on an 8x8 canvas,
// with Gaussian noise (060) on every pixel. A tiny stand-in for MNIST.

const glyph_rows = [10][7]*const [5]u8{
    .{ " ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### " },
    .{ "  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### " },
    .{ " ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####" },
    .{ "#####", "   # ", "  #  ", "   # ", "    #", "#   #", " ### " },
    .{ "   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # " },
    .{ "#####", "#    ", "#### ", "    #", "    #", "#   #", " ### " },
    .{ "  ## ", " #   ", "#    ", "#### ", "#   #", "#   #", " ### " },
    .{ "#####", "    #", "   # ", "  #  ", " #   ", " #   ", " #   " },
    .{ " ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### " },
    .{ " ### ", "#   #", "#   #", " ####", "    #", "   # ", " ##  " },
};

const pixels = 64; // 8 x 8
const classes = 10;

fn makeExample(rand: std.Random, class: usize, out: []f64) void {
    const dx = rand.uintLessThan(usize, 4); // 8 - 5 + 1 positions
    const dy = rand.uintLessThan(usize, 2); // 8 - 7 + 1 positions
    for (0..8) |y| {
        for (0..8) |x| {
            var on = false;
            if (y >= dy and y < dy + 7 and x >= dx and x < dx + 5) on = glyph_rows[class][y - dy][x - dx] == '#';
            out[y * 8 + x] = (if (on) @as(f64, 1) else 0) + 0.25 * rand.floatNorm(f64);
        }
    }
}

/// n examples with random classes. xs is [n, 64], ys is [n].
fn makeDataset(rand: std.Random, xs: []f64, ys: []usize) void {
    for (ys, 0..) |*y, i| {
        y.* = rand.uintLessThan(usize, classes);
        makeExample(rand, y.*, xs[i * pixels ..][0..pixels]);
    }
}

fn shuffle(rand: std.Random, idx: []usize) void {
    var i = idx.len;
    while (i > 1) {
        i -= 1;
        const j = rand.uintLessThan(usize, ???);
        ???
    }
}

/// Per-pixel mean and standard deviation over n examples.
fn pixelStats(xs: []const f64, n: usize, mean: []f64, sd: []f64) void {
    const nf: f64 = @floatFromInt(n);
    for (0..pixels) |p| {
        var m: f64 = 0;
        for (0..n) |i| m += xs[i * pixels + p];
        m /= nf;
        var v: f64 = 0;
        for (0..n) |i| v += ???;
        mean[p] = m;
        sd[p] = ???;
    }
}

fn normalize(xs: []f64, n: usize, mean: []const f64, sd: []const f64) void {
    for (0..n) |i| {
        for (0..pixels) |p| xs[i * pixels + p] = ???;
    }
}

/// The [start, end) of batch number b.
fn batchRange(n: usize, batch: usize, b: usize) [2]usize {
    const start = b * batch;
    return .{ start, ??? };
}

test "shuffle is a fair permutation" {
    var prng = std.Random.DefaultPrng.init(102);
    var first_lands: [4]f64 = @splat(0);
    for (0..40_000) |_| {
        var idx = [_]usize{ 0, 1, 2, 3 };
        shuffle(prng.random(), &idx);
        var sorted = idx;
        std.mem.sort(usize, &sorted, {}, std.sort.asc(usize));
        try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, &sorted);
        const where = std.mem.indexOfScalar(usize, &idx, 0).?;
        first_lands[where] += 1.0 / 40_000.0;
    }
    for (first_lands) |f| try std.testing.expectApproxEqAbs(0.25, f, 0.01);
}

test "batches cover every example once" {
    try std.testing.expectEqual([2]usize{ 0, 4 }, batchRange(10, 4, 0));
    try std.testing.expectEqual([2]usize{ 4, 8 }, batchRange(10, 4, 1));
    try std.testing.expectEqual([2]usize{ 8, 10 }, batchRange(10, 4, 2));
}

test "normalized pixels have mean 0 and deviation 1" {
    var prng = std.Random.DefaultPrng.init(7);
    const n = 500;
    var xs: [n * pixels]f64 = undefined;
    var ys: [n]usize = undefined;
    makeDataset(prng.random(), &xs, &ys);
    var mean: [pixels]f64 = undefined;
    var sd: [pixels]f64 = undefined;
    pixelStats(&xs, n, &mean, &sd);
    normalize(&xs, n, &mean, &sd);
    pixelStats(&xs, n, &mean, &sd);
    for (mean, sd) |m, s| {
        try std.testing.expectApproxEqAbs(0.0, m, 1e-9);
        try std.testing.expectApproxEqAbs(1.0, s, 1e-9);
    }
}
