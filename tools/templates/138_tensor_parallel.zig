//
// ─── Exercise 138: tensor parallelism ──────────────────────────────────
//
// Data parallelism (053) copies the whole model onto every device. When
// ONE layer's weights don't fit on a device, split the matrices
// themselves. For y = x W, with W [in, out], there are two ways:
//
//   column split: device d holds columns [d*out/N .. (d+1)*out/N) of W.
//     It computes those columns of y. Concatenate the pieces: no adding.
//
//   row split: device d holds rows [d*in/N ..) of W, and the matching
//     slice of x. Each device computes a PARTIAL y over the full width,
//     and the partials must be SUMMED: an all-reduce (109).
//
// Megatron-LM's trick for a transformer MLP, y = relu(x A) B: split A by
// columns and B by rows. Each device computes relu(x A_d) B_d on its own
// (relu is elementwise, so it works on column slices), and a single
// all-reduce at the end gives y. One communication per MLP.
//
// YOUR TASK: compute a device's share for both splits.
//
const std = @import("std");

const n_dev = 2;

fn matmul(x: []const f64, w: []const f64, m: usize, k: usize, n: usize, out: []f64) void {
    for (0..m) |i| {
        for (0..n) |j| {
            var acc: f64 = 0;
            for (0..k) |kk| acc += x[i * k + kk] * w[kk * n + j];
            out[i * n + j] = acc;
        }
    }
}

/// Device d's columns of y = x W (x [m, k], W [k, n]); out is [m, n/N].
fn columnShard(x: []const f64, w: []const f64, m: usize, k: usize, n: usize, d: usize, out: []f64) void {
    const cols = n / n_dev;
    for (0..m) |i| {
        for (0..cols) |j| {
            var acc: f64 = 0;
            for (0..k) |kk| acc += x[i * k + kk] * w[kk * n + ⟪d * cols + j|||???⟫];
            out[i * cols + j] = acc;
        }
    }
}

/// Device d's partial y from its rows of W and its slice of x; out is [m, n].
fn rowShard(x: []const f64, w: []const f64, m: usize, k: usize, n: usize, d: usize, out: []f64) void {
    const rows = k / n_dev;
    for (0..m) |i| {
        for (0..n) |j| {
            var acc: f64 = 0;
            for (d * rows..(d + 1) * rows) |kk| acc += ⟪x[i * k + kk] * w[kk * n + j]|||???⟫;
            out[i * n + j] = acc;
        }
    }
}

const xs = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8 }; //                  [2, 4]
const ws = [_]f64{ 1, 0, 2, -1, 0.5, 1, 1, 1, -2, 3, 0, 1, 1, 2, 2, 0 }; // [4, 4]

test "column split: concatenate" {
    var full: [8]f64 = undefined;
    matmul(&xs, &ws, 2, 4, 4, &full);
    for (0..n_dev) |d| {
        var part: [4]f64 = undefined;
        columnShard(&xs, &ws, 2, 4, 4, d, &part);
        for (0..2) |i| {
            for (0..2) |j| try std.testing.expectEqual(full[i * 4 + d * 2 + j], part[i * 2 + j]);
        }
    }
}

test "row split: sum (the all-reduce)" {
    var full: [8]f64 = undefined;
    matmul(&xs, &ws, 2, 4, 4, &full);
    var total: [8]f64 = @splat(0);
    for (0..n_dev) |d| {
        var part: [8]f64 = undefined;
        rowShard(&xs, &ws, 2, 4, 4, d, &part);
        for (&total, part) |*t, p| t.* += p;
    }
    try std.testing.expectEqualSlices(f64, &full, &total);
}
