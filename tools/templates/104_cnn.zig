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

//@include glyphs

//@include nn_engine

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
                    for (0..3) |j| out[row * 9 + i * 3 + j] = xs[⟪b * pixels + (oy + i) * 8 + (ox + j)|||???⟫];
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
        const flat = ⟪e.reshape(conv, batch, positions * filters)|||???⟫;
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
