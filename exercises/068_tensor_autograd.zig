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

const Op = enum { leaf, matmul, add_bias, relu, sum, mul };

/// A 2-D tensor [rows, cols] of f64, with its gradient.
const Tensor = struct {
    rows: usize,
    cols: usize,
    data: []f64,
    grad: []f64,
    op: Op = .leaf,
    a: ?*Tensor = null,
    b: ?*Tensor = null,

    fn at(t: *const Tensor, i: usize, j: usize) f64 {
        return t.data[i * t.cols + j];
    }
};

const Engine = struct {
    alloc: std.mem.Allocator,

    fn tensor(e: Engine, rows: usize, cols: usize, values: []const f64) *Tensor {
        const t = e.new(rows, cols, .leaf, null, null);
        @memcpy(t.data, values);
        return t;
    }

    fn new(e: Engine, rows: usize, cols: usize, op: Op, a: ?*Tensor, b: ?*Tensor) *Tensor {
        const t = e.alloc.create(Tensor) catch @panic("out of memory");
        t.* = .{
            .rows = rows,
            .cols = cols,
            .data = e.alloc.alloc(f64, rows * cols) catch @panic("out of memory"),
            .grad = e.alloc.alloc(f64, rows * cols) catch @panic("out of memory"),
            .op = op,
            .a = a,
            .b = b,
        };
        @memset(t.grad, 0);
        return t;
    }

    /// [m, k] · [k, n]
    fn matmul(e: Engine, a: *Tensor, b: *Tensor) *Tensor {
        std.debug.assert(a.cols == b.rows);
        const t = e.new(a.rows, b.cols, .matmul, a, b);
        for (0..a.rows) |i| {
            for (0..b.cols) |j| {
                var acc: f64 = 0;
                for (0..a.cols) |k| acc += a.at(i, k) * b.at(k, j);
                t.data[i * t.cols + j] = acc;
            }
        }
        return t;
    }

    /// x [r, c] + bias [1, c], the bias broadcast over rows.
    fn addBias(e: Engine, x: *Tensor, bias: *Tensor) *Tensor {
        std.debug.assert(bias.rows == 1 and bias.cols == x.cols);
        const t = e.new(x.rows, x.cols, .add_bias, x, bias);
        for (0..x.rows) |i| {
            for (0..x.cols) |j| t.data[i * t.cols + j] = x.at(i, j) + bias.data[j];
        }
        return t;
    }

    fn relu(e: Engine, x: *Tensor) *Tensor {
        const t = e.new(x.rows, x.cols, .relu, x, null);
        for (t.data, x.data) |*o, v| o.* = @max(v, 0);
        return t;
    }

    /// Everything added up, into a [1, 1] tensor.
    fn sum(e: Engine, x: *Tensor) *Tensor {
        const t = e.new(1, 1, .sum, x, null);
        var acc: f64 = 0;
        for (x.data) |v| acc += v;
        t.data[0] = acc;
        return t;
    }

    /// Elementwise, same shapes.
    fn mul(e: Engine, a: *Tensor, b: *Tensor) *Tensor {
        std.debug.assert(a.rows == b.rows and a.cols == b.cols);
        const t = e.new(a.rows, a.cols, .mul, a, b);
        for (t.data, a.data, b.data) |*o, x, y| o.* = x * y;
        return t;
    }

    fn backward(e: Engine, root: *Tensor) void {
        var visited = std.AutoHashMap(*Tensor, void).init(e.alloc);
        var order: std.ArrayList(*Tensor) = .empty;
        topo(e.alloc, root, &visited, &order);
        @memset(root.grad, 1);
        var i = order.items.len;
        while (i > 0) {
            i -= 1;
            passGrad(order.items[i]);
        }
    }
};

fn topo(alloc: std.mem.Allocator, t: *Tensor, visited: *std.AutoHashMap(*Tensor, void), order: *std.ArrayList(*Tensor)) void {
    if (visited.contains(t)) return;
    visited.put(t, {}) catch @panic("out of memory");
    if (t.a) |a| topo(alloc, a, visited, order);
    if (t.b) |b| topo(alloc, b, visited, order);
    order.append(alloc, t) catch @panic("out of memory");
}

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
                        a.grad[i * a.cols + k] += ???;
                        b.grad[k * b.cols + j] += ???;
                    }
                }
            }
        },
        .add_bias => {
            const x = t.a.?;
            const bias = t.b.?;
            for (0..t.rows) |i| {
                for (0..t.cols) |j| {
                    x.grad[i * t.cols + j] += ???;
                    bias.grad[???] += t.grad[i * t.cols + j];
                }
            }
        },
        .relu => {
            const x = t.a.?;
            for (x.grad, x.data, t.grad) |*g, v, dg| {
                ???;
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
