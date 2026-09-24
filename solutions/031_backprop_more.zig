// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 031: more backward rules ─────────────────────────────────
//
// Let's teach the engine the rest of the primitives from exercise 027,
// written as backward rules. Each one: "grad in, times my local
// derivative, goes to my source".
//
//     y = 2^x       x.grad += y.grad * (2^x * ln 2)      note: 2^x IS y.value
//     y = log2(x)   x.grad += y.grad * 1/(x ln 2)
//     y = 1/x       x.grad += y.grad * (-1/x^2)          which is -(y.value)^2
//     y = relu(x)   x.grad += y.grad if x > 0, else nothing
//
// Reusing the output value (2^x, 1/x) saves recomputing it. tinygrad's
// gradient rules do the same thing.
//
// Then the payoff: sub, div, exp and log are built from primitives
// (exercises 015 and 016), so they get correct gradients without
// writing a single extra rule. The tests check your rules against
// measured slopes (exercise 026) on a messy formula.
//
// YOUR TASK: write the four backward rules.
//
const std = @import("std");

const Op = enum { leaf, add, mul, exp2, log2, recip, relu };

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
    fn exp2(e: Engine, a: *Value) *Value {
        return e.new(.{ .value = @exp2(a.value), .op = .exp2, .src = .{ a, null } });
    }
    fn log2(e: Engine, a: *Value) *Value {
        return e.new(.{ .value = @log2(a.value), .op = .log2, .src = .{ a, null } });
    }
    fn recip(e: Engine, a: *Value) *Value {
        return e.new(.{ .value = 1 / a.value, .op = .recip, .src = .{ a, null } });
    }
    fn relu(e: Engine, a: *Value) *Value {
        return e.new(.{ .value = @max(a.value, 0), .op = .relu, .src = .{ a, null } });
    }

    // Built from primitives: no backward rules needed!
    fn neg(e: Engine, a: *Value) *Value {
        return e.mul(a, e.leaf(-1));
    }
    fn sub(e: Engine, a: *Value, b: *Value) *Value {
        return e.add(a, e.neg(b));
    }
    fn div(e: Engine, a: *Value, b: *Value) *Value {
        return e.mul(a, e.recip(b));
    }
    fn exp(e: Engine, a: *Value) *Value {
        return e.exp2(e.mul(a, e.leaf(std.math.log2e)));
    }
    fn log(e: Engine, a: *Value) *Value {
        return e.mul(e.log2(a), e.leaf(std.math.ln2));
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

fn passGrad(n: *Value) void {
    const a = n.src[0] orelse return; // leaves have nothing to pass to
    switch (n.op) {
        .leaf => unreachable,
        .add => {
            a.grad += n.grad;
            n.src[1].?.grad += n.grad;
        },
        .mul => {
            const b = n.src[1].?;
            a.grad += n.grad * b.value;
            b.grad += n.grad * a.value;
        },
        .exp2 => a.grad += n.grad * n.value * std.math.ln2,
        .log2 => a.grad += n.grad * 1 / (a.value * std.math.ln2),
        .recip => a.grad += n.grad * -n.value * n.value,
        .relu => a.grad += if (a.value > 0) n.grad else 0,
    }
}

/// log(e^x + y^2) / (relu(x - y) + 1)
fn messy(e: Engine, x: *Value, y: *Value) *Value {
    const top = e.log(e.add(e.exp(x), e.mul(y, y)));
    const bottom = e.add(e.relu(e.sub(x, y)), e.leaf(1));
    return e.div(top, bottom);
}

/// Compare backward() with measured slopes (exercise 026).
fn gradCheck(x0: f64, y0: f64) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e: Engine = .{ .alloc = arena.allocator() };

    const x = e.leaf(x0);
    const y = e.leaf(y0);
    e.backward(messy(e, x, y));

    const h = 1e-6;
    const dx = (messy(e, e.leaf(x0 + h), e.leaf(y0)).value - messy(e, e.leaf(x0 - h), e.leaf(y0)).value) / (2 * h);
    const dy = (messy(e, e.leaf(x0), e.leaf(y0 + h)).value - messy(e, e.leaf(x0), e.leaf(y0 - h)).value) / (2 * h);
    try std.testing.expectApproxEqAbs(dx, x.grad, 1e-6);
    try std.testing.expectApproxEqAbs(dy, y.grad, 1e-6);
}

test "gradients match measured slopes" {
    try gradCheck(0.5, -1.2); // relu active
    try gradCheck(2.0, 0.3); //  relu active
    try gradCheck(-1.0, 0.5); // relu off: x - y < 0
}

test "relu passes grad only when on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e: Engine = .{ .alloc = arena.allocator() };

    const on = e.leaf(2);
    const off = e.leaf(-2);
    e.backward(e.add(e.relu(on), e.relu(off)));
    try std.testing.expectEqual(1, on.grad);
    try std.testing.expectEqual(0, off.grad);
}
