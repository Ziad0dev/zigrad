//
// ─── Exercise 104: a convolutional network ─────────────────────────────
//
// The MLP treats the 64 pixels as 64 unrelated numbers. It has to learn
// "a 1 at column 2" and "a 1 at column 3" separately, even though they're
// the same stroke, shifted. A *convolution* (085) slides the SAME small
// filters over every position: it learns a stroke detector once and uses
// it everywhere. That's weight sharing, and it's why CNNs dominate
// images.
//
// Our CNN, on 8x8 images:
//
//     3x3 conv, 8 filters, no padding    -> [8 channels, 6 x 6]
//     relu
//     flatten                            -> 288 numbers
//     linear 288 -> 10                   -> logits
//
// The conv layer has only 9 * 8 + 8 = 80 parameters.
//
// Implementing the conv with our engine: im2col (085) with one PATCH PER
// ROW. patches [B*36, 9] · W [9, 8] gives [B*36, 8]: every position's 8
// filter responses. Rows come image by image, so the rows for image b are
// contiguous, and reshaping to [B, 36*8] is free (010). The input patches
// don't need gradients, so im2col happens outside autograd.
//
// YOUR TASK: extract the patches, and flatten in forward().
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

const side = 6; //        output positions per row: 8 - 3 + 1
const positions = side * side;
const filters = 8;

/// Every 3x3 patch of every image, one per row: [batch * 36, 9].
fn patches(xs: []const f64, batch: usize, out: []f64) void {
    for (0..batch) |b| {
        for (0..side) |oy| {
            for (0..side) |ox| {
                const row = b * positions + oy * side + ox;
                for (0..3) |i| {
                    for (0..3) |j| out[row * 9 + i * 3 + j] = xs[???];
                }
            }
        }
    }
}

const Cnn = struct {
    wc: *Tensor,
    bc: *Tensor,
    wl: *Tensor,
    bl: *Tensor,

    fn init(e: Engine, rand: std.Random) Cnn {
        const bc = e.new(1, filters, .leaf, null, null);
        const bl = e.new(1, classes, .leaf, null, null);
        @memset(bc.data, 0);
        @memset(bl.data, 0);
        return .{
            .wc = e.param(rand, 9, filters, 9),
            .bc = bc,
            .wl = e.param(rand, positions * filters, classes, positions * filters),
            .bl = bl,
        };
    }

    fn params(m: Cnn) [4]*Tensor {
        return .{ m.wc, m.bc, m.wl, m.bl };
    }

    fn forward(m: Cnn, e: Engine, x_patches: *Tensor, batch: usize) *Tensor {
        const conv = e.relu(e.addBias(e.matmul(x_patches, m.wc), m.bc)); // [batch*36, 8]
        const flat = ???;
        return e.addBias(e.matmul(flat, m.wl), m.bl);
    }
};

fn accuracy(m: Cnn, xs: []const f64, ys: []const usize) !f64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const e: Engine = .{ .alloc = arena.allocator() };
    const p = try arena.allocator().alloc(f64, ys.len * positions * 9);
    patches(xs, ys.len, p);
    const logits = m.forward(e, e.input(ys.len * positions, 9, p), ys.len);
    var right: usize = 0;
    for (ys, 0..) |y, i| {
        if (argmax(logits.data[i * classes ..][0..classes]) == y) right += 1;
    }
    return @as(f64, @floatFromInt(right)) / @as(f64, @floatFromInt(ys.len));
}

fn train(m: Cnn, rand: std.Random, xs: []const f64, ys: []const usize, epochs: usize, batch: usize, lr: f64) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const n = ys.len;
    var idx: [4096]usize = undefined;
    for (idx[0..n], 0..) |*v, i| v.* = i;
    var bx: [64 * pixels]f64 = undefined;
    var by: [64]usize = undefined;
    var bp: [64 * positions * 9]f64 = undefined;

    for (0..epochs) |_| {
        rand.shuffle(usize, idx[0..n]);
        var start: usize = 0;
        while (start < n) : (start += batch) {
            const end = @min(start + batch, n);
            const b = end - start;
            for (idx[start..end], 0..) |src, k| {
                @memcpy(bx[k * pixels ..][0..pixels], xs[src * pixels ..][0..pixels]);
                by[k] = ys[src];
            }
            patches(bx[0 .. b * pixels], b, bp[0 .. b * positions * 9]);
            _ = arena.reset(.retain_capacity);
            const e: Engine = .{ .alloc = arena.allocator() };
            for (m.params()) |p| @memset(p.grad, 0);
            const logits = m.forward(e, e.input(b * positions, 9, bp[0 .. b * positions * 9]), b);
            e.backward(e.crossEntropy(logits, by[0..b]));
            for (m.params()) |p| {
                for (p.data, p.grad) |*w, g| w.* -= lr * g;
            }
        }
    }
}

test "train a CNN on noisy digits" {
    var prng = std.Random.DefaultPrng.init(104);
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
    const model = Cnn.init(.{ .alloc = weights.allocator() }, rand);
    try std.testing.expectEqual(80, model.wc.data.len + model.bc.data.len);

    train(model, rand, train_x, &train_y, 10, 16, 0.1);
    try std.testing.expect(try accuracy(model, test_x, &test_y) > 0.9);
}
