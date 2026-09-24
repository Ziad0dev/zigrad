//
// ─── Exercise 082: the linear layer, batched ───────────────────────────
//
// Chapter 16: the layers real networks are built from, each with its
// forward AND backward pass, each checked against measured slopes.
//
// First, the workhorse. A batch of B examples, each with `in` features, as
// the rows of X [B, in]:
//
//     Y = X · W + b          W [in, out], b [out] broadcast over rows
//
// Backward, given dY [B, out] (066's VJPs, 033's broadcast rule):
//
//     dX = dY · Wᵀ           [B, out] · [out, in]  = [B, in]
//     dW = Xᵀ · dY           [in, B]  · [B, out]   = [in, out]
//     db = dY summed over the batch (rows)
//
// Notice dW adds up contributions from every example in the batch: the
// gradient is the SUM over examples (divide by B if the loss is a mean).
//
// This is tinygrad's nn.Linear (it stores W as [out, in] and computes
// X · Wᵀ, the same maths).
//
// YOUR TASK: write the three backward loops.
//
const std = @import("std");

const Linear = struct {
    in: usize,
    out: usize,
    w: []f64, // [in, out]
    b: []f64, // [out]

    fn forward(l: Linear, x: []const f64, batch: usize, y: []f64) void {
        for (0..batch) |r| {
            for (0..l.out) |j| {
                var acc = l.b[j];
                for (0..l.in) |k| acc += x[r * l.in + k] * l.w[k * l.out + j];
                y[r * l.out + j] = acc;
            }
        }
    }

    fn backward(l: Linear, x: []const f64, batch: usize, dy: []const f64, dx: []f64, dw: []f64, db: []f64) void {
        @memset(dx, 0);
        @memset(dw, 0);
        @memset(db, 0);
        for (0..batch) |r| {
            for (0..l.out) |j| {
                const g = dy[r * l.out + j];
                ⟪db[j] += g;|||???⟫
                for (0..l.in) |k| {
                    dx[r * l.in + k] += ⟪g * l.w[k * l.out + j]|||???⟫;
                    dw[k * l.out + j] += ⟪x[r * l.in + k] * g|||???⟫;
                }
            }
        }
    }
};

//@include gradcheck

// loss = sum(Y ⊙ R), so dY = R
const Check = struct {
    l: Linear,
    x: []f64,
    r: []const f64,
    batch: usize,

    fn loss(c: Check) f64 {
        var y: [16]f64 = undefined;
        c.l.forward(c.x, c.batch, y[0 .. c.batch * c.l.out]);
        var total: f64 = 0;
        for (y[0 .. c.batch * c.l.out], c.r) |a, b| total += a * b;
        return total;
    }
};

test "linear layer gradients" {
    var w = [_]f64{ 0.5, -1, 0.3, 0.8, 1.2, 0.4 }; // [2, 3]
    var b = [_]f64{ 0.1, -0.2, 0.3 };
    var x = [_]f64{ 1, 2, -1, 0.5, 0.3, -2, 4, 1 }; // batch of 4, 2 features
    const r = [_]f64{ 1, 2, -1, 0.5, 0.25, -3, 1, 1, 1, -2, 0, 3 }; // [4, 3]
    const l: Linear = .{ .in = 2, .out = 3, .w = &w, .b = &b };
    const c: Check = .{ .l = l, .x = &x, .r = &r, .batch = 4 };

    var dx: [8]f64 = undefined;
    var dw: [6]f64 = undefined;
    var db: [3]f64 = undefined;
    l.backward(&x, 4, &r, &dx, &dw, &db);
    try gradCheck(c, &w, &dw);
    try gradCheck(c, &b, &db);
    try gradCheck(c, &x, &dx);
}
