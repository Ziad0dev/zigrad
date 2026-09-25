// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 070: derivatives of derivatives ──────────────────────────
//
// Because a gradient is a graph (069), you can take ITS gradient: the
// second derivative f''. That unlocks *Newton's method*.
//
// Root finding (where is f(x) = 0?): stand at x, follow the tangent line
// down to where it hits zero, and jump there:
//
//     x_new = x - f(x) / f'(x)
//
// For f(x) = x^2 - 2, that finds sqrt(2), and the number of correct
// digits roughly DOUBLES every step ("quadratic convergence"):
//     1.5, 1.4167, 1.41421569, 1.41421356237469, ...
//
// Minimizing: a minimum is where f'(x) = 0, so run Newton on f':
//
//     x_new = x - f'(x) / f''(x)
//
// Compared with gradient descent (032) there's no learning rate to tune:
// f'' tells you how curved the bowl is, so the step size picks itself.
// On a quadratic bowl, Newton lands in ONE step. The catch in deep
// learning: with n weights, f'' is an n x n matrix (the Hessian, 058),
// far too big to build and invert. So deep learning uses cheaper tricks
// that play a similar role, like Adam's per-weight step sizes (038).
//
// Everything here uses the graph engine from 069, finished.
//
// YOUR TASK: write the two Newton updates and build the second
// derivative.
//
const std = @import("std");

const Op = enum { constant, variable, add, mul, sin, cos };

const Node = struct {
    op: Op,
    src: []const *const Node = &.{},
    value: f64 = 0, //         .constant
    name: []const u8 = "", //  .variable
};

const Key = struct { op: Op, a: ?*const Node, b: ?*const Node, bits: u64 };

/// A deduplicating expression graph (exercises 024 and 025).
const Graph = struct {
    alloc: std.mem.Allocator,
    cache: std.AutoHashMap(Key, *const Node),
    vars: std.StringHashMap(*const Node),

    fn init(alloc: std.mem.Allocator) Graph {
        return .{ .alloc = alloc, .cache = .init(alloc), .vars = .init(alloc) };
    }

    fn new(g: *Graph, op: Op, src: []const *const Node, value: f64) *const Node {
        const key: Key = .{
            .op = op,
            .a = if (src.len > 0) src[0] else null,
            .b = if (src.len > 1) src[1] else null,
            .bits = @bitCast(value),
        };
        if (g.cache.get(key)) |existing| return existing;
        const n = g.alloc.create(Node) catch @panic("out of memory");
        n.* = .{ .op = op, .src = g.alloc.dupe(*const Node, src) catch @panic("out of memory"), .value = value };
        g.cache.put(key, n) catch @panic("out of memory");
        return n;
    }

    fn variable(g: *Graph, name: []const u8) *const Node {
        if (g.vars.get(name)) |v| return v;
        const n = g.alloc.create(Node) catch @panic("out of memory");
        n.* = .{ .op = .variable, .name = name };
        g.vars.put(name, n) catch @panic("out of memory");
        return n;
    }
    fn constant(g: *Graph, value: f64) *const Node {
        return g.new(.constant, &.{}, value);
    }
    fn add(g: *Graph, a: *const Node, b: *const Node) *const Node {
        return g.new(.add, &.{ a, b }, 0);
    }
    fn mul(g: *Graph, a: *const Node, b: *const Node) *const Node {
        return g.new(.mul, &.{ a, b }, 0);
    }
    fn sin(g: *Graph, a: *const Node) *const Node {
        return g.new(.sin, &.{a}, 0);
    }
    fn cos(g: *Graph, a: *const Node) *const Node {
        return g.new(.cos, &.{a}, 0);
    }
};

/// Evaluate with every variable set to `x`.
fn eval(n: *const Node, x: f64) f64 {
    return switch (n.op) {
        .constant => n.value,
        .variable => x,
        .add => eval(n.src[0], x) + eval(n.src[1], x),
        .mul => eval(n.src[0], x) * eval(n.src[1], x),
        .sin => @sin(eval(n.src[0], x)),
        .cos => @cos(eval(n.src[0], x)),
    };
}

fn render(n: *const Node, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (n.op) {
        .constant => try w.print("{d}", .{n.value}),
        .variable => try w.writeAll(n.name),
        .add, .mul => {
            try w.writeAll("(");
            try render(n.src[0], w);
            try w.writeAll(if (n.op == .add) " + " else " * ");
            try render(n.src[1], w);
            try w.writeAll(")");
        },
        .sin, .cos => {
            try w.writeAll(if (n.op == .sin) "sin(" else "cos(");
            try render(n.src[0], w);
            try w.writeAll(")");
        },
    }
}

// ─── Simplification (exercise 025) ───

fn isConst(n: *const Node, value: f64) bool {
    return n.op == .constant and n.value == value;
}

fn simplifyOnce(g: *Graph, n: *const Node) ?*const Node {
    switch (n.op) {
        .add => {
            if (isConst(n.src[1], 0)) return n.src[0];
            if (isConst(n.src[0], 0)) return n.src[1];
        },
        .mul => {
            if (isConst(n.src[1], 1)) return n.src[0];
            if (isConst(n.src[0], 1)) return n.src[1];
            if (isConst(n.src[0], 0) or isConst(n.src[1], 0)) return g.constant(0);
        },
        else => {},
    }
    if ((n.op == .add or n.op == .mul) and n.src[0].op == .constant and n.src[1].op == .constant) {
        const a = n.src[0].value;
        const b = n.src[1].value;
        return g.constant(if (n.op == .add) a + b else a * b);
    }
    return null;
}

fn simplify(g: *Graph, n: *const Node) *const Node {
    var cur = n;
    switch (n.op) {
        .add, .mul => cur = g.new(n.op, &.{ simplify(g, n.src[0]), simplify(g, n.src[1]) }, 0),
        .sin, .cos => cur = g.new(n.op, &.{simplify(g, n.src[0])}, 0),
        else => {},
    }
    while (simplifyOnce(g, cur)) |next| cur = next;
    return cur;
}

fn toposort(alloc: std.mem.Allocator, n: *const Node, visited: *std.AutoHashMap(*const Node, void), order: *std.ArrayList(*const Node)) error{OutOfMemory}!void {
    if (visited.contains(n)) return;
    try visited.put(n, {});
    for (n.src) |s| try toposort(alloc, s, visited, order);
    try order.append(alloc, n);
}

/// d(root)/d(wrt), as a new graph (exercise 069).
fn grad(g: *Graph, root: *const Node, wrt: *const Node) !*const Node {
    var visited = std.AutoHashMap(*const Node, void).init(g.alloc);
    var order: std.ArrayList(*const Node) = .empty;
    try toposort(g.alloc, root, &visited, &order);

    var bp: Backprop = .{ .g = g, .grads = .init(g.alloc) };
    try bp.grads.put(root, g.constant(1));
    var i = order.items.len;
    while (i > 0) {
        i -= 1;
        const n = order.items[i];
        const out = bp.grads.get(n) orelse continue;
        switch (n.op) {
            .constant, .variable => {},
            .add => {
                try bp.acc(n.src[0], out);
                try bp.acc(n.src[1], out);
            },
            .mul => {
                try bp.acc(n.src[0], g.mul(out, n.src[1]));
                try bp.acc(n.src[1], g.mul(out, n.src[0]));
            },
            .sin => try bp.acc(n.src[0], g.mul(out, g.cos(n.src[0]))),
            .cos => try bp.acc(n.src[0], g.mul(out, g.mul(g.constant(-1), g.sin(n.src[0])))),
        }
    }
    return simplify(g, bp.grads.get(wrt) orelse g.constant(0));
}

const Backprop = struct {
    g: *Graph,
    grads: std.AutoHashMap(*const Node, *const Node),

    /// grads[n] += more  (as graph nodes)
    fn acc(bp: *Backprop, n: *const Node, more: *const Node) !void {
        const sum = if (bp.grads.get(n)) |existing| bp.g.add(existing, more) else more;
        try bp.grads.put(n, sum);
    }
};

/// Root of f, from `start`. Returns x after `steps` steps.
fn newtonRoot(g: *Graph, f: *const Node, x: *const Node, start: f64, steps: usize) !f64 {
    const df = try grad(g, f, x);
    var v = start;
    for (0..steps) |_| v = v - eval(f, v) / eval(df, v);
    return v;
}

/// A minimum of f, from `start`.
fn newtonMin(g: *Graph, f: *const Node, x: *const Node, start: f64, steps: usize) !f64 {
    const df = try grad(g, f, x);
    const ddf = try grad(g, df, x);
    var v = start;
    for (0..steps) |_| v = v - eval(df, v) / eval(ddf, v);
    return v;
}

test "square root of 2, digits doubling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const x = g.variable("x");
    const f = g.add(g.mul(x, x), g.constant(-2));

    const exact = @sqrt(2.0);
    try std.testing.expect(@abs(try newtonRoot(&g, f, x, 1, 2) - exact) < 1e-2);
    try std.testing.expect(@abs(try newtonRoot(&g, f, x, 1, 3) - exact) < 1e-5);
    try std.testing.expect(@abs(try newtonRoot(&g, f, x, 1, 5) - exact) < 1e-15);
}

test "a quadratic bowl in one step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const x = g.variable("x");
    // (x - 3)^2 + 1 = x*x - 6x + 10
    const f = g.add(g.add(g.mul(x, x), g.mul(g.constant(-6), x)), g.constant(10));
    try std.testing.expectApproxEqAbs(3.0, try newtonMin(&g, f, x, -50, 1), 1e-12);
}

test "a wiggly function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const x = g.variable("x");
    // x^2 + 2 sin(x): its minimum is where 2x + 2cos(x) = 0
    const f = g.add(g.mul(x, x), g.mul(g.constant(2), g.sin(x)));
    const m = try newtonMin(&g, f, x, 0, 6);
    try std.testing.expectApproxEqAbs(0.0, 2 * m + 2 * @cos(m), 1e-12);
    try std.testing.expectApproxEqAbs(-0.739085, m, 1e-6);
}
