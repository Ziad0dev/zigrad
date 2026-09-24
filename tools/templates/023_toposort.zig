//
// ─── Exercise 023: topological order ───────────────────────────────────
//
// Recursion (exercise 022) is fine for small graphs, but tinygrad mostly
// works on a flat LIST of nodes, sorted so that every node comes AFTER
// the nodes it uses. That's a *topological order*.
//
// Getting dressed has one: socks before shoes, shirt before jacket.
// For  d = (a + 1) + (a * 2):
//
//     a, 1, a+1, 2, a*2, d       ✓ every node after its sources
//     d, a+1, a, 1, a*2, 2       ✗ d comes before what it needs
//
// How to find one: depth-first search. To place a node, first place all
// of its sources (recursively), THEN append the node itself. A `visited`
// set makes sure shared nodes are placed only once.
//
// tinygrad uses topological order everywhere: to run kernels in the
// right order, to turn a kernel into a list of instructions (chapter 8),
// and, walked BACKWARDS, to compute gradients (exercise 030).
//
// YOUR TASK: toposort() compiles, but its order is wrong. Fix it.
//
const std = @import("std");

const Op = enum { constant, add, mul };

const Node = struct {
    op: Op,
    src: []const *const Node = &.{},
    value: f32 = 0,
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

const Sorter = struct {
    alloc: std.mem.Allocator,
    visited: std.AutoHashMap(*const Node, void),
    order: std.ArrayList(*const Node) = .empty,

    fn visit(s: *Sorter, n: *const Node) error{OutOfMemory}!void {
        if (s.visited.contains(n)) return;
        try s.visited.put(n, {});
//⟪
        for (n.src) |src| try s.visit(src);
        try s.order.append(s.alloc, n);
//|||
        try s.order.append(s.alloc, n);
        for (n.src) |src| try s.visit(src);
//⟫
    }
};

fn toposort(alloc: std.mem.Allocator, root: *const Node) ![]const *const Node {
    var s: Sorter = .{ .alloc = alloc, .visited = .init(alloc) };
    try s.visit(root);
    return s.order.items;
}

/// Fails unless every node comes after all of its sources.
fn expectTopological(order: []const *const Node) !void {
    for (order, 0..) |n, i| {
        for (n.src) |src| {
            const j = std.mem.indexOfScalar(*const Node, order, src) orelse return error.MissingNode;
            if (j >= i) return error.SourceAfterUser;
        }
    }
}

test "d = (a + 1) + (a * 2)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g: Graph = .{ .alloc = arena.allocator() };

    const a = g.constant(5);
    const d = g.add(g.add(a, g.constant(1)), g.mul(a, g.constant(2)));

    const order = try toposort(arena.allocator(), d);
    try std.testing.expectEqual(6, order.len); // a appears only once
    try expectTopological(order);
    try std.testing.expectEqual(d, order[order.len - 1]);
}

test "a long shared chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g: Graph = .{ .alloc = arena.allocator() };

    var x = g.constant(1);
    for (0..20) |_| x = g.add(x, x);

    const order = try toposort(arena.allocator(), x);
    try std.testing.expectEqual(21, order.len);
    try expectTopological(order);
}
