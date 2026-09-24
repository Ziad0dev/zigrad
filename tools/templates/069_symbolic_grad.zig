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

//@include expr_graph

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
                try bp.acc(n.src[0], ⟪g.mul(out, n.src[1])|||???⟫);
                try bp.acc(n.src[1], ⟪g.mul(out, n.src[0])|||???⟫);
            },
            // sin' = cos
            .sin => try bp.acc(n.src[0], ⟪g.mul(out, g.cos(n.src[0]))|||???⟫),
            // cos' = -sin
            .cos => try bp.acc(n.src[0], ⟪g.mul(out, g.mul(g.constant(-1), g.sin(n.src[0])))|||???⟫),
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
