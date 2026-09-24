//
// ─── Exercise 021: the lazy graph ──────────────────────────────────────
//
// Chapter 4 is about *laziness*, tinygrad's defining feature.
//
// In tinygrad, `c = a + b` doesn't add anything. It creates a node that
// remembers "c is ADD of a and b" (tinygrad calls these nodes UOps,
// micro-ops). Your whole program becomes a graph of such nodes, and
// nothing runs until you ask for actual numbers with .realize(),
// .numpy() or .item().
//
//     (2 + 3) * 4    becomes     MUL
//                               /   \
//                             ADD    4
//                            /   \
//                           2     3
//
// Why wait? Because with the whole graph in view, tinygrad can merge ops
// into fewer kernels (chapter 8), skip useless work (exercise 025), and
// compute gradients by walking the graph backwards (chapter 5).
//
// Zig notes: Zig has no garbage collector, so every node needs memory
// from an *allocator*. The tests use an arena: it hands out memory and
// frees all of it at once in deinit(). That's perfect for graphs, which
// are built up and then thrown away as a whole.
//
// YOUR TASK: finish render() and countNodes(), then build the graph for
// (2 + 3) * 4 in the test.
//
const std = @import("std");

const Op = enum { constant, add, mul };

const Node = struct {
    op: Op,
    src: []const *const Node = &.{}, // the nodes this one is computed from
    value: f32 = 0, //                   only used by .constant
};

const Graph = struct {
    alloc: std.mem.Allocator,

    fn constant(g: Graph, value: f32) *const Node {
        const n = g.new(.constant, &.{});
        n.value = value;
        return n;
    }

    fn add(g: Graph, a: *const Node, b: *const Node) *const Node {
        return g.new(.add, &.{ a, b });
    }

    fn mul(g: Graph, a: *const Node, b: *const Node) *const Node {
        return g.new(.mul, &.{ a, b });
    }

    fn new(g: Graph, op: Op, src: []const *const Node) *Node {
        const n = g.alloc.create(Node) catch @panic("out of memory");
        n.* = .{ .op = op, .src = g.alloc.dupe(*const Node, src) catch @panic("out of memory") };
        return n;
    }
};

/// Write the graph as a formula, like "((2 + 3) * 4)".
fn render(n: *const Node, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (n.op) {
        .constant => try w.print("{d}", .{n.value}),
        .add, .mul => {
            try w.writeAll("(");
            try render(n.src[0], w);
            try w.writeAll(if (n.op == .add) " + " else " * ");
            ???
            try w.writeAll(")");
        },
    }
}

/// How many nodes does this graph have?
fn countNodes(n: *const Node) usize {
    var total: usize = 1; // this node
    for (n.src) |s| total += ???;
    return total;
}

test "build (2 + 3) * 4, without computing it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g: Graph = .{ .alloc = arena.allocator() };

    const expr = ???;

    try std.testing.expectEqual(.mul, expr.op);
    try std.testing.expectEqual(5, countNodes(expr));

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(expr, &w);
    try std.testing.expectEqualStrings("((2 + 3) * 4)", w.buffered());
}
