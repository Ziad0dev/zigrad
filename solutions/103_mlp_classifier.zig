// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 103: an MLP classifier ───────────────────────────────────
//
// A two-layer network (a "multi-layer perceptron"), trained with
// mini-batch SGD and cross-entropy. In tinygrad this is about ten lines:
//
//     class MLP:
//       def __init__(self): self.l1, self.l2 = nn.Linear(64, 32), nn.Linear(32, 10)
//       def __call__(self, x): return self.l2(self.l1(x).relu())
//
//     for x, y in batches:
//       loss = model(x).sparse_categorical_crossentropy(y)
//       opt.zero_grad(); loss.backward(); opt.step()
//
// Every piece of that is something you've built: Linear (082), relu
// (003), cross-entropy (036), backward (068), zero_grad (039), SGD (032),
// batches and normalization (102), init (037).
//
// The engine below is 068's, plus reshape (for 104) and a fused
// softmax-cross-entropy op with 036's gradient.
//
// Then: accuracy on a TEST set the model never trained on (101). The
// predicted class is the argmax of the logits.
//
// YOUR TASK: finish forward(), the training step, and accuracy().
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

const Mlp = struct {
    w1: *Tensor,
    b1: *Tensor,
    w2: *Tensor,
    b2: *Tensor,

    fn init(e: Engine, rand: std.Random) Mlp {
        const b1 = e.new(1, 32, .leaf, null, null);
        const b2 = e.new(1, classes, .leaf, null, null);
        @memset(b1.data, 0);
        @memset(b2.data, 0);
        return .{ .w1 = e.param(rand, pixels, 32, pixels), .b1 = b1, .w2 = e.param(rand, 32, classes, 32), .b2 = b2 };
    }

    fn params(m: Mlp) [4]*Tensor {
        return .{ m.w1, m.b1, m.w2, m.b2 };
    }

    /// logits = relu(x W1 + b1) W2 + b2
    fn forward(m: Mlp, e: Engine, x: *Tensor) *Tensor {
        const h = e.relu(e.addBias(e.matmul(x, m.w1), m.b1));
        return e.addBias(e.matmul(h, m.w2), m.b2);
    }
};

fn accuracy(m: Mlp, xs: []const f64, ys: []const usize) f64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const e: Engine = .{ .alloc = arena.allocator() };
    const logits = m.forward(e, e.input(ys.len, pixels, xs));
    var right: usize = 0;
    for (ys, 0..) |y, i| {
        if (argmax(logits.data[i * classes ..][0..classes]) == y) right += 1;
    }
    return @as(f64, @floatFromInt(right)) / @as(f64, @floatFromInt(ys.len));
}

fn train(m: Mlp, rand: std.Random, xs: []const f64, ys: []const usize, epochs: usize, batch: usize, lr: f64) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const n = ys.len;
    var idx: [4096]usize = undefined;
    for (idx[0..n], 0..) |*v, i| v.* = i;
    var bx: [64 * pixels]f64 = undefined; // room for batches up to 64
    var by: [64]usize = undefined;

    for (0..epochs) |_| {
        rand.shuffle(usize, idx[0..n]); // Fisher-Yates, like 102
        var start: usize = 0;
        while (start < n) : (start += batch) {
            const end = @min(start + batch, n);
            const b = end - start;
            for (idx[start..end], 0..) |src, k| {
                @memcpy(bx[k * pixels ..][0..pixels], xs[src * pixels ..][0..pixels]);
                by[k] = ys[src];
            }
            _ = arena.reset(.retain_capacity);
            const e: Engine = .{ .alloc = arena.allocator() };

            // zero_grad, forward, backward, step
            for (m.params()) |p| @memset(p.grad, 0);
            const loss = e.crossEntropy(m.forward(e, e.input(b, pixels, bx[0 .. b * pixels])), by[0..b]);
            e.backward(loss);
            for (m.params()) |p| {
                for (p.data, p.grad) |*w, g| w.* -= lr * g;
            }
        }
    }
}

test "train an MLP on noisy digits" {
    var prng = std.Random.DefaultPrng.init(103);
    const rand = prng.random();
    const n_train = 2000;
    const n_test = 500;
    const train_x = try std.testing.allocator.alloc(f64, n_train * pixels);
    defer std.testing.allocator.free(train_x);
    const test_x = try std.testing.allocator.alloc(f64, n_test * pixels);
    defer std.testing.allocator.free(test_x);
    var train_y: [n_train]usize = undefined;
    var test_y: [n_test]usize = undefined;
    makeDataset(rand, train_x, &train_y);
    makeDataset(rand, test_x, &test_y);

    var weights = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer weights.deinit();
    const model = Mlp.init(.{ .alloc = weights.allocator() }, rand);

    const before = accuracy(model, test_x, &test_y);
    train(model, rand, train_x, &train_y, 15, 16, 0.2);
    const after = accuracy(model, test_x, &test_y);
    try std.testing.expect(before < 0.3); //  random guessing: about 10%
    try std.testing.expect(after > 0.9); //   on examples it never saw
}
