// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 030: backpropagation ─────────────────────────────────────
//
// Reverse mode flips the direction of exercise 029. Run the formula
// forward once and remember the graph (a lazy graph, like chapter 4!).
// Then walk it BACKWARDS from the output, working out for every node:
// "how much does the output change if this node changes?" That number is
// the node's *gradient*, or grad.
//
//   1. The output's grad is 1: it changes exactly as much as itself.
//   2. Each node hands its grad to its sources, multiplied by its local
//      derivative (the chain rule):
//
//        c = a + b:   a.grad += c.grad               b.grad += c.grad
//        c = a * b:   a.grad += c.grad * b.value     b.grad += c.grad * a.value
//
//   3. Visit nodes in reverse topological order (exercise 023), so a node
//      has collected ALL of its grad before passing it on.
//
// Why +=? When a value is used twice, both uses affect the output, and
// their effects add up. In x * x, x gets c.grad * x from EACH side: 2x
// total, which is exactly the derivative of x^2.
//
// One backward pass gives the grad of EVERY input at once. That's why
// every deep learning library, tinygrad included, uses reverse mode.
//
// (Unlike tinygrad, this little engine computes each value immediately
// when you build a node. It keeps the graph only for the backward pass.)
//
// YOUR TASK: backward() starts from the wrong grad, and the rule for mul
// is missing.
//
const std = @import("std");

const Op = enum { leaf, add, mul };

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

    fn new(e: Engine, v: Value) *Value {
        const p = e.alloc.create(Value) catch @panic("out of memory");
        p.* = v;
        return p;
    }

    fn backward(e: Engine, root: *Value) void {
        // 1. topological order (exercise 023)
        var visited = std.AutoHashMap(*Value, void).init(e.alloc);
        var order: std.ArrayList(*Value) = .empty;
        topo(e.alloc, root, &visited, &order);

        // 2. d(root)/d(root)
        root.grad = 1;

        // 3. walk backwards
        var i = order.items.len;
        while (i > 0) {
            i -= 1;
            passGrad(order.items[i]);
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

/// The chain rule for one node: hand this node's grad to its sources.
fn passGrad(n: *Value) void {
    switch (n.op) {
        .leaf => {},
        .add => {
            n.src[0].?.grad += n.grad;
            n.src[1].?.grad += n.grad;
        },
        .mul => {
            const a = n.src[0].?;
            const b = n.src[1].?;
            a.grad += n.grad * b.value;
            b.grad += n.grad * a.value;
        },
    }
}

test "f = a*b + a" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e: Engine = .{ .alloc = arena.allocator() };

    const a = e.leaf(2);
    const b = e.leaf(3);
    const f = e.add(e.mul(a, b), a);
    try std.testing.expectEqual(8, f.value);

    e.backward(f);
    try std.testing.expectEqual(4, a.grad); // df/da = b + 1
    try std.testing.expectEqual(2, b.grad); // df/db = a
}

test "x * x: one value used twice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e: Engine = .{ .alloc = arena.allocator() };

    const x = e.leaf(3);
    e.backward(e.mul(x, x));
    try std.testing.expectEqual(6, x.grad); // (x^2)' = 2x
}

test "f = (a*b + c) * a" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e: Engine = .{ .alloc = arena.allocator() };

    const a = e.leaf(2);
    const b = e.leaf(-3);
    const c = e.leaf(10);
    e.backward(e.mul(e.add(e.mul(a, b), c), a));
    // f = a^2 b + a c
    try std.testing.expectEqual(-2, a.grad); // 2ab + c
    try std.testing.expectEqual(4, b.grad); //  a^2
    try std.testing.expectEqual(2, c.grad); //  a
}
