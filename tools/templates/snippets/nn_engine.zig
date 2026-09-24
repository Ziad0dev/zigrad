// ─── A small tensor autograd engine (exercise 068, plus a few ops) ───

const Op = enum { leaf, matmul, add_bias, relu, reshape, cross_entropy };

const Tensor = struct {
    rows: usize,
    cols: usize,
    data: []f64,
    grad: []f64,
    op: Op = .leaf,
    a: ?*Tensor = null,
    b: ?*Tensor = null,
    labels: []const usize = &.{}, // .cross_entropy

    fn at(t: *const Tensor, i: usize, j: usize) f64 {
        return t.data[i * t.cols + j];
    }
};

const Engine = struct {
    alloc: std.mem.Allocator,

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

    fn input(e: Engine, rows: usize, cols: usize, values: []const f64) *Tensor {
        const t = e.new(rows, cols, .leaf, null, null);
        @memcpy(t.data, values);
        return t;
    }

    /// A weight matrix, uniform in [-1/sqrt(fan_in), 1/sqrt(fan_in)] (037).
    fn param(e: Engine, rand: std.Random, rows: usize, cols: usize, fan_in: usize) *Tensor {
        const t = e.new(rows, cols, .leaf, null, null);
        const bound = 1 / @sqrt(@as(f64, @floatFromInt(fan_in)));
        for (t.data) |*v| v.* = (rand.float(f64) * 2 - 1) * bound;
        return t;
    }

    fn matmul(e: Engine, a: *Tensor, b: *Tensor) *Tensor {
        std.debug.assert(a.cols == b.rows);
        const t = e.new(a.rows, b.cols, .matmul, a, b);
        @memset(t.data, 0);
        for (0..a.rows) |i| {
            for (0..a.cols) |k| {
                const x = a.at(i, k);
                for (0..b.cols) |j| t.data[i * t.cols + j] += x * b.at(k, j);
            }
        }
        return t;
    }

    fn addBias(e: Engine, x: *Tensor, bias: *Tensor) *Tensor {
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

    /// Same numbers, same order, new [rows, cols] (010): free for
    /// contiguous data.
    fn reshape(e: Engine, x: *Tensor, rows: usize, cols: usize) *Tensor {
        std.debug.assert(rows * cols == x.rows * x.cols);
        const t = e.new(rows, cols, .reshape, x, null);
        @memcpy(t.data, x.data);
        return t;
    }

    /// Mean cross-entropy (036) of logits [batch, classes].
    fn crossEntropy(e: Engine, logits: *Tensor, labels: []const usize) *Tensor {
        const t = e.new(1, 1, .cross_entropy, logits, null);
        t.labels = labels;
        var total: f64 = 0;
        for (0..logits.rows) |i| {
            const row = logits.data[i * logits.cols ..][0..logits.cols];
            total += logsumexp(row) - row[labels[i]];
        }
        t.data[0] = total / @as(f64, @floatFromInt(logits.rows));
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

fn logsumexp(row: []const f64) f64 {
    var m: f64 = -std.math.inf(f64);
    for (row) |v| m = @max(m, v);
    var s: f64 = 0;
    for (row) |v| s += @exp(v - m);
    return m + @log(s);
}

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
            for (0..a.rows) |i| {
                for (0..a.cols) |k| {
                    var ga: f64 = 0;
                    const x = a.at(i, k);
                    for (0..b.cols) |j| {
                        const g = t.grad[i * t.cols + j];
                        ga += g * b.at(k, j);
                        b.grad[k * b.cols + j] += x * g;
                    }
                    a.grad[i * a.cols + k] += ga;
                }
            }
        },
        .add_bias => {
            const x = t.a.?;
            const bias = t.b.?;
            for (0..t.rows) |i| {
                for (0..t.cols) |j| {
                    x.grad[i * t.cols + j] += t.grad[i * t.cols + j];
                    bias.grad[j] += t.grad[i * t.cols + j];
                }
            }
        },
        .relu => {
            const x = t.a.?;
            for (x.grad, x.data, t.grad) |*g, v, dg| {
                if (v > 0) g.* += dg;
            }
        },
        .reshape => {
            const x = t.a.?;
            for (x.grad, t.grad) |*g, dg| g.* += dg;
        },
        .cross_entropy => {
            const z = t.a.?;
            const batch: f64 = @floatFromInt(z.rows);
            for (0..z.rows) |i| {
                const row = z.data[i * z.cols ..][0..z.cols];
                const lse = logsumexp(row);
                for (0..z.cols) |c| {
                    const p = @exp(row[c] - lse);
                    const truth: f64 = if (c == t.labels[i]) 1 else 0;
                    z.grad[i * z.cols + c] += t.grad[0] * (p - truth) / batch;
                }
            }
        },
    }
}

fn argmax(row: []const f64) usize {
    var best: usize = 0;
    for (row, 0..) |v, i| {
        if (v > row[best]) best = i;
    }
    return best;
}
