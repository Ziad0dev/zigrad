//
// ─── Exercise 039: train a neural network ──────────────────────────────
//
// Time to put chapters 5 to 7 together and train a real (tiny) neural
// network on XOR, the classic problem a single straight line can't solve:
//
//     x0 x1 | target
//      0  0 |   0
//      0  1 |   1
//      1  0 |   1
//      1  1 |   0
//
// The network: 2 inputs -> 4 hidden neurons (tanh) -> 1 output.
//
//     hidden[i] = tanh(w1[i][0] * x0 + w1[i][1] * x1 + b1[i])
//     output    = w2[0] * hidden[0] + ... + w2[3] * hidden[3] + b2
//
// The training loop, the same shape in tinygrad and every other library:
//
//     1. zero the grads        (grads ADD UP with +=, exercise 030, so
//                               last step's grads must be cleared first!)
//     2. forward:  compute the loss (mean squared error over the 4 rows)
//     3. backward: loss.backward()
//     4. step:     w -= lr * w.grad, for every weight
//
// In tinygrad those are opt.zero_grad(), loss = ..., loss.backward() and
// opt.step().
//
// The weights live across steps, so they're allocated once, outside the
// loop. Each step's graph lives in an arena that's reset every step.
//
// YOUR TASK: finish forward() and the training loop.
//
const std = @import("std");

const Op = enum { leaf, add, mul, tanh };

const Value = struct {
    value: f64,
    grad: f64 = 0,
    op: Op = .leaf,
    src: [2]?*Value = .{ null, null },
};

const Engine = struct {
    alloc: std.mem.Allocator,

    fn leaf(e: Engine, v: f64) *Value {
        return e.new(.{ .value = v });
    }
    fn add(e: Engine, a: *Value, b: *Value) *Value {
        return e.new(.{ .value = a.value + b.value, .op = .add, .src = .{ a, b } });
    }
    fn mul(e: Engine, a: *Value, b: *Value) *Value {
        return e.new(.{ .value = a.value * b.value, .op = .mul, .src = .{ a, b } });
    }
    fn sub(e: Engine, a: *Value, b: *Value) *Value {
        return e.add(a, e.mul(b, e.leaf(-1)));
    }
    fn tanh(e: Engine, a: *Value) *Value {
        return e.new(.{ .value = std.math.tanh(a.value), .op = .tanh, .src = .{ a, null } });
    }
    fn new(e: Engine, v: Value) *Value {
        const p = e.alloc.create(Value) catch @panic("out of memory");
        p.* = v;
        return p;
    }
    fn backward(e: Engine, root: *Value) void {
        var visited = std.AutoHashMap(*Value, void).init(e.alloc);
        var order: std.ArrayList(*Value) = .empty;
        topo(e.alloc, root, &visited, &order);
        root.grad = 1;
        var i = order.items.len;
        while (i > 0) {
            i -= 1;
            const n = order.items[i];
            switch (n.op) {
                .leaf => {},
                .add => {
                    n.src[0].?.grad += n.grad;
                    n.src[1].?.grad += n.grad;
                },
                .mul => {
                    n.src[0].?.grad += n.grad * n.src[1].?.value;
                    n.src[1].?.grad += n.grad * n.src[0].?.value;
                },
                // tanh'(x) = 1 - tanh(x)^2
                .tanh => n.src[0].?.grad += n.grad * (1 - n.value * n.value),
            }
        }
    }
};

fn topo(alloc: std.mem.Allocator, n: *Value, visited: *std.AutoHashMap(*Value, void), order: *std.ArrayList(*Value)) void {
    if (visited.contains(n)) return;
    visited.put(n, {}) catch @panic("out of memory");
    for (n.src) |maybe_src| {
        if (maybe_src) |s| topo(alloc, s, visited, order);
    }
    order.append(alloc, n) catch @panic("out of memory");
}

const hidden = 4;

const Net = struct {
    w1: [hidden][2]*Value,
    b1: [hidden]*Value,
    w2: [hidden]*Value,
    b2: *Value,

    fn init(e: Engine, rand: std.Random) Net {
        var net: Net = undefined;
        for (&net.w1) |*row| {
            for (row) |*w| w.* = e.leaf(rand.float(f64) * 2 - 1);
        }
        for (&net.b1) |*b| b.* = e.leaf(0);
        for (&net.w2) |*w| w.* = e.leaf(rand.float(f64) * 2 - 1);
        net.b2 = e.leaf(0);
        return net;
    }

    /// Every trainable weight, in one list.
    fn params(net: *Net) [hidden * 2 + hidden + hidden + 1]*Value {
        var out: [hidden * 2 + hidden + hidden + 1]*Value = undefined;
        var i: usize = 0;
        for (net.w1) |row| {
            for (row) |w| {
                out[i] = w;
                i += 1;
            }
        }
        for (net.b1 ++ net.w2 ++ [_]*Value{net.b2}) |p| {
            out[i] = p;
            i += 1;
        }
        return out;
    }

    fn forward(net: Net, e: Engine, x: [2]f64) *Value {
        var out = net.b2;
        for (0..hidden) |i| {
            // z = w1[i][0] * x[0] + w1[i][1] * x[1] + b1[i]
            var z = net.b1[i];
            for (0..2) |j| {
                z = ???;
            }
            out = e.add(out, e.mul(net.w2[i], e.tanh(z)));
        }
        return out;
    }
};

const Example = struct { x: [2]f64, y: f64 };

const xor = [_]Example{
    .{ .x = .{ 0, 0 }, .y = 0 },
    .{ .x = .{ 0, 1 }, .y = 1 },
    .{ .x = .{ 1, 0 }, .y = 1 },
    .{ .x = .{ 1, 1 }, .y = 0 },
};

/// Train and return the final loss. Fills in `net`.
fn train(weights_alloc: std.mem.Allocator, seed: u64, steps: usize, lr: f64, net: *Net) f64 {
    var prng = std.Random.DefaultPrng.init(seed);
    net.* = .init(.{ .alloc = weights_alloc }, prng.random());
    var params = net.params();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var last_loss: f64 = 0;
    for (0..steps) |_| {
        _ = arena.reset(.retain_capacity);
        const e: Engine = .{ .alloc = arena.allocator() };

        // 1. zero the grads
        // ???

        // 2. forward: mean squared error over the four examples
        var loss = e.leaf(0);
        for (xor) |ex| {
            const err = e.sub(net.forward(e, ex.x), e.leaf(ex.y));
            loss = e.add(loss, e.mul(err, err));
        }
        loss = e.mul(loss, e.leaf(0.25)); // mean: divide by 4
        last_loss = loss.value;

        // 3. backward
        ???;

        // 4. step
        for (&params) |p| {
            ???;
        }
    }
    return last_loss;
}

test "learn XOR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var net: Net = undefined;
    const loss = train(arena.allocator(), 7, 500, 0.2, &net);
    try std.testing.expect(loss < 0.01);

    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const e: Engine = .{ .alloc = scratch.allocator() };
    for (xor) |ex| {
        const guess = net.forward(e, ex.x).value;
        try std.testing.expectApproxEqAbs(ex.y, guess, 0.2);
    }
}
