//
// ─── Exercise 068: a tensor autograd engine ────────────────────────────
//
// Time to put 066's VJPs into a real engine that works on whole matrices,
// like tinygrad's Tensor. Each op stores its inputs, and backward() walks
// the graph in reverse (023, 030), calling each op's VJP rule:
//
//   C = A · B          dA += dC · Bᵀ          dB += Aᵀ · dC          (035)
//   Y = X + bias       dX += dY               dbias += dY summed over rows (033)
//   Y = relu(X)        dX += dY where X > 0   (066)
//   s = sum(X)         dX += ds, everywhere
//   Y = A ⊙ B          dA += dY ⊙ B           dB += dY ⊙ A
//
// Everything is a [rows, cols] matrix of f64, row-major, so element (i, j)
// of t is t.data[i * t.cols + j].
//
// This engine comes back in the capstone (chapter 19), so make it right.
// The test is the strongest kind: a gradient check (026) of a whole
// two-layer network, every single weight.
//
// YOUR TASK: write the backward rules for matmul, add_bias and relu.
//
const std = @import("std");

//@include tensor_engine_core

fn passGrad(t: *Tensor) void {
    switch (t.op) {
        .leaf => {},
        .matmul => {
            const a = t.a.?;
            const b = t.b.?;
            // dA[i][k] += dC[i][j] * B[k][j]      dB[k][j] += A[i][k] * dC[i][j]
            for (0..a.rows) |i| {
                for (0..a.cols) |k| {
                    for (0..b.cols) |j| {
                        a.grad[i * a.cols + k] += ⟪t.grad[i * t.cols + j] * b.at(k, j)|||???⟫;
                        b.grad[k * b.cols + j] += ⟪a.at(i, k) * t.grad[i * t.cols + j]|||???⟫;
                    }
                }
            }
        },
        .add_bias => {
            const x = t.a.?;
            const bias = t.b.?;
            for (0..t.rows) |i| {
                for (0..t.cols) |j| {
                    x.grad[i * t.cols + j] += ⟪t.grad[i * t.cols + j]|||???⟫;
                    bias.grad[⟪j|||???⟫] += t.grad[i * t.cols + j];
                }
            }
        },
        .relu => {
            const x = t.a.?;
            for (x.grad, x.data, t.grad) |*g, v, dg| {
                ⟪if (v > 0) g.* += dg;|||???⟫
            }
        },
        .sum => {
            const x = t.a.?;
            for (x.grad) |*g| g.* += t.grad[0];
        },
        .mul => {
            const a = t.a.?;
            const b = t.b.?;
            for (a.grad, b.grad, a.data, b.data, t.grad) |*ga, *gb, x, y, dg| {
                ga.* += dg * y;
                gb.* += dg * x;
            }
        },
    }
}

const Net = struct { x: *Tensor, w1: *Tensor, b1: *Tensor, w2: *Tensor, r: *Tensor };

/// loss = sum( (relu(X W1 + b1) W2) ⊙ R )
fn loss(e: Engine, n: Net) *Tensor {
    const h = e.relu(e.addBias(e.matmul(n.x, n.w1), n.b1));
    return e.sum(e.mul(e.matmul(h, n.w2), n.r));
}

fn build(e: Engine) Net {
    return .{
        .x = e.tensor(3, 2, &.{ 1, 2, -1, 0.5, 0.3, -2 }),
        .w1 = e.tensor(2, 4, &.{ 0.5, -1, 0.3, 0.8, 1.2, 0.4, -0.7, 0.1 }),
        .b1 = e.tensor(1, 4, &.{ 0.1, -0.2, 0.3, 0 }),
        .w2 = e.tensor(4, 2, &.{ 1, -0.5, 0.2, 0.9, -1.1, 0.3, 0.6, 0.7 }),
        .r = e.tensor(3, 2, &.{ 1, 2, -1, 0.5, 0.25, -3 }),
    };
}

test "gradient check of a two-layer network" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e: Engine = .{ .alloc = arena.allocator() };

    const net = build(e);
    e.backward(loss(e, net));

    const h = 1e-6;
    for ([_]*Tensor{ net.w1, net.b1, net.w2, net.x }) |param| {
        for (param.data, param.grad) |*w, g| {
            const orig = w.*;
            w.* = orig + h;
            const up = loss(e, net).data[0];
            w.* = orig - h;
            const down = loss(e, net).data[0];
            w.* = orig;
            try std.testing.expectApproxEqAbs((up - down) / (2 * h), g, 1e-6);
        }
    }
}
