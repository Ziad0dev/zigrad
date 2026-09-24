//
// ─── Exercise 069: gradients are graphs too ────────────────────────────
//
// Our engines so far computed gradients as NUMBERS. tinygrad does
// something smarter: backward() builds MORE LAZY GRAPH. Each backward
// rule, instead of doing arithmetic, creates new nodes:
//
//     y = a * b    ->   grad(a) += grad(y) * b     (a new mul node)
//
// The gradient ends up as an ordinary graph of ordinary ops. So it gets
// everything forward code gets for free: rewrite simplification (025),
// kernel fusion (040), codegen (041-042), the JIT (051). And since it's a
// graph, you can differentiate it AGAIN (next exercise).
//
// Raw backprop output is full of junk like (1 * x) and (0 + ...). The
// rewrite rules from 025 clean it up. For f = x*x + 3*x:
//
//     raw:        ((1 * 3) + ((1 * x) + (1 * x))) or similar
//     simplified: 2x + 3, in some shape
//
// Accumulating: when a node is used twice, its gradient is the SUM of the
// two contributions (030), so acc() builds an add node.
//
// YOUR TASK: write the backward rules for mul, sin and cos, as graph
// nodes.
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
                try bp.acc(n.src[0], ???);
                try bp.acc(n.src[1], ???);
            },
            // sin' = cos
            .sin => try bp.acc(n.src[0], ???),
            // cos' = -sin
            .cos => try bp.acc(n.src[0], ???),
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

fn expectRender(expected: []const u8, n: *const Node) !void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(n, &w);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "d/dx (x*x + 3*x) = 2x + 3" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const x = g.variable("x");

    const f = g.add(g.mul(x, x), g.mul(g.constant(3), x));
    const df = try grad(&g, f, x);
    for ([_]f64{ -2, 0, 1.5, 10 }) |v| try std.testing.expectApproxEqAbs(2 * v + 3, eval(df, v), 1e-12);
    // the simplified graph has no (1 * ...) left in it
    try expectRender("((3 + x) + x)", df);
}

test "d/dx sin(x) * x = cos(x) * x + sin(x)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const x = g.variable("x");

    const df = try grad(&g, g.mul(g.sin(x), x), x);
    for ([_]f64{ -2, 0, 1.5, 10 }) |v| {
        try std.testing.expectApproxEqAbs(@cos(v) * v + @sin(v), eval(df, v), 1e-12);
    }
}

test "d/dx cos(x * x) = -sin(x^2) * 2x" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const x = g.variable("x");

    const df = try grad(&g, g.cos(g.mul(x, x)), x);
    for ([_]f64{ -2, 0, 1.5, 3 }) |v| {
        try std.testing.expectApproxEqAbs(-@sin(v * v) * 2 * v, eval(df, v), 1e-12);
    }
}
