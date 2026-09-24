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

//@include glyphs

//@include nn_engine

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
        const h = ⟪e.relu(e.addBias(e.matmul(x, m.w1), m.b1))|||???⟫;
        return ⟪e.addBias(e.matmul(h, m.w2), m.b2)|||???⟫;
    }
};

fn accuracy(m: Mlp, xs: []const f64, ys: []const usize) f64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const e: Engine = .{ .alloc = arena.allocator() };
    const logits = m.forward(e, e.input(ys.len, pixels, xs));
    var right: usize = 0;
    for (ys, 0..) |y, i| {
        if (⟪argmax(logits.data[i * classes ..][0..classes]) == y|||???⟫) right += 1;
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
            for (m.params()) |p| ⟪@memset(p.grad, 0)|||???⟫;
            const loss = e.crossEntropy(m.forward(e, e.input(b, pixels, bx[0 .. b * pixels])), by[0..b]);
            ⟪e.backward(loss);|||???⟫
            for (m.params()) |p| {
                for (p.data, p.grad) |*w, g| ⟪w.* -= lr * g|||???⟫;
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
