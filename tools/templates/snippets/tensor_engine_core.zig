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
