//
// ─── Exercise 088: embeddings ──────────────────────────────────────────
//
// Words (or tokens) are integers: "cat" might be token 3. A network needs
// vectors. An *embedding* is a learned table E [vocab, dim]: token t
// becomes row t.
//
//     forward:   out[i] = E[ids[i]]                 (a lookup, a "gather")
//     backward:  dE[ids[i]] += dout[i]              (a "scatter-add")
//
// The += matters: if the same token appears twice in a sentence, its row
// gets both gradients. Rows of tokens that didn't appear get nothing.
//
// Here's the trick tinygrad uses, since it has no "gather" primitive: a
// lookup IS a matmul with a *one-hot* matrix:
//
//     onehot [n, vocab]:  onehot[i][v] = 1 if v == ids[i], else 0
//     onehot · E = the looked-up rows
//
// And the one-hot matrix comes from a comparison with a broadcast arange:
// (arange(vocab) == ids[:, None]). All primitives: nothing new needed,
// and autograd gives the scatter-add for free as matmul's backward (035).
//
// YOUR TASK: finish lookup, its backward, and the one-hot matrix.
//
const std = @import("std");

fn lookup(e: []const f64, dim: usize, ids: []const usize, out: []f64) void {
    for (ids, 0..) |id, i| {
        @memcpy(out[i * dim ..][0..dim], ⟪e[id * dim ..][0..dim]|||???⟫);
    }
}

fn lookupBackward(dim: usize, ids: []const usize, dout: []const f64, de: []f64) void {
    @memset(de, 0);
    for (ids, 0..) |id, i| {
        for (0..dim) |k| ⟪de[id * dim + k] += dout[i * dim + k]|||???⟫;
    }
}

fn oneHot(ids: []const usize, vocab: usize, out: []f64) void {
    for (ids, 0..) |id, i| {
        for (0..vocab) |v| out[i * vocab + v] = ⟪if (v == id) 1 else 0|||???⟫;
    }
}

fn matmul(a: []const f64, b: []const f64, m: usize, k: usize, n: usize, out: []f64) void {
    for (0..m) |i| {
        for (0..n) |j| {
            var acc: f64 = 0;
            for (0..k) |kk| acc += a[i * k + kk] * b[kk * n + j];
            out[i * n + j] = acc;
        }
    }
}

// 5 tokens, 3 dimensions
const table = [_]f64{ 0, 0, 0, 1, 1, 1, 2, 4, 8, -1, 0, 1, 5, 5, 5 };

test "lookup = one-hot matmul" {
    const ids = [_]usize{ 2, 0, 2, 4 };
    var fast: [12]f64 = undefined;
    lookup(&table, 3, &ids, &fast);
    try std.testing.expectEqualSlices(f64, &.{ 2, 4, 8, 0, 0, 0, 2, 4, 8, 5, 5, 5 }, &fast);

    var hot: [4 * 5]f64 = undefined;
    var slow: [12]f64 = undefined;
    oneHot(&ids, 5, &hot);
    matmul(&hot, &table, 4, 5, 3, &slow);
    try std.testing.expectEqualSlices(f64, &fast, &slow);
}

test "backward: repeated tokens add up, missing tokens get 0" {
    const ids = [_]usize{ 2, 0, 2 };
    const dout = [_]f64{ 1, 1, 1, 5, 5, 5, 0.5, 0, -1 };
    var de: [15]f64 = undefined;
    lookupBackward(3, &ids, &dout, &de);
    try std.testing.expectEqualSlices(f64, &.{ 5, 5, 5, 0, 0, 0, 1.5, 1, 0, 0, 0, 0, 0, 0, 0 }, &de);
}
