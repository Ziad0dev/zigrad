//
// ─── Exercise 032: gradient descent ────────────────────────────────────
//
// Now we can *train*. To make f smaller, step x against its slope:
//
//     x_new = x - lr * f'(x)          lr: the "learning rate", or step size
//
// Slope positive -> f goes up to the right -> step left. And vice versa.
//
// How big should lr be? Try f(x) = (x - 3)^2 + 1, lowest at x = 3.
// Here f'(x) = 2(x - 3), so one step does:
//
//     x_new - 3 = (x - 3) - lr * 2(x - 3) = (1 - 2 lr) * (x - 3)
//
// Every step multiplies the distance to the minimum by (1 - 2 lr):
//
//     lr = 0.1:  x 0.8 per step      steady progress
//     lr = 0.9:  x -0.8 per step     jumps over the minimum each time, but
//                                    still gets closer
//     lr = 1.1:  x -1.2 per step     every step makes it WORSE: diverges
//
// Picking the learning rate is a big part of training real networks.
//
// Then something more useful: find the line w*x + b through some points,
// by minimizing the *mean squared error*, the average of
// (prediction - truth)^2. That's the intro lesson's training loop.
//
// Zig note: an arena can be reset() between steps. It keeps its memory,
// so each new graph reuses it instead of asking the OS again.
//
// YOUR TASK: write the update steps and the error term.
//
const std = @import("std");

const Op = enum { leaf, add, mul };

const Value = struct {
    value: f64,
    grad: f64 = 0,
    op: Op = .leaf,
    src: [2]?*Value = .{ null, null },
};

// The engine from exercise 030.
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

/// Minimize (x - 3)^2 + 1, starting from `start`.
fn minimize(start: f64, lr: f64, steps: usize) f64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var x = start;
    for (0..steps) |_| {
        _ = arena.reset(.retain_capacity);
        const e: Engine = .{ .alloc = arena.allocator() };

        const xv = e.leaf(x);
        const d = e.sub(xv, e.leaf(3));
        e.backward(e.add(e.mul(d, d), e.leaf(1)));

        x = ⟪x - lr * xv.grad|||???⟫;
    }
    return x;
}

/// Find w and b so that w*x + b fits the points (xs, ys).
fn fitLine(xs: []const f64, ys: []const f64, lr: f64, steps: usize) [2]f64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var w: f64 = 0;
    var b: f64 = 0;
    for (0..steps) |_| {
        _ = arena.reset(.retain_capacity);
        const e: Engine = .{ .alloc = arena.allocator() };
        const wv = e.leaf(w);
        const bv = e.leaf(b);

        // loss = mean of (w*x + b - y)^2 over the points
        var loss = e.leaf(0);
        for (xs, ys) |x, y| {
            const err = ⟪e.sub(e.add(e.mul(wv, e.leaf(x)), bv), e.leaf(y))|||???⟫;
            loss = e.add(loss, e.mul(err, err));
        }
        loss = e.mul(loss, e.leaf(1 / @as(f64, @floatFromInt(xs.len))));
        e.backward(loss);

        ⟪w -= lr * wv.grad;|||???;⟫
        ⟪b -= lr * bv.grad;|||???;⟫
    }
    return .{ w, b };
}

test "a good learning rate" {
    try std.testing.expectApproxEqAbs(3.0, minimize(0, 0.1, 100), 1e-6);
}

test "too big, but still converging" {
    try std.testing.expectApproxEqAbs(3.0, minimize(0, 0.9, 100), 1e-6);
}

test "way too big: diverges" {
    try std.testing.expect(@abs(minimize(0, 1.1, 50) - 3) > 1000);
}

test "fit y = 2x + 1" {
    const wb = fitLine(&.{ 1, 2, 3, 4 }, &.{ 3, 5, 7, 9 }, 0.05, 1000);
    try std.testing.expectApproxEqAbs(2.0, wb[0], 1e-3);
    try std.testing.expectApproxEqAbs(1.0, wb[1], 1e-3);
}
