//
// ─── Exercise 022: evaluating a graph, once ────────────────────────────
//
// To compute a graph, compute the sources first, then the node itself.
// Recursion does this naturally:
//
//     eval(ADD(a, b)) = eval(a) + eval(b)
//
// But graphs share nodes. Here x is used twice:
//
//     x2 = x + x,   x4 = x2 + x2,   x8 = x4 + x4,  ...
//
// Naive recursion evaluates x2 twice for x4, x4 twice for x8, and so on:
// the work DOUBLES with every level. Twenty levels means about 2 million
// evaluations for a graph of only 21 nodes.
//
// The fix: remember each answer (a *cache*, or *memo*). Before
// evaluating a node, check whether we already know its value. Every node
// is then computed exactly once.
//
// tinygrad does the same: once a tensor is realized, its buffer is kept
// with the graph node, so it's never computed again.
//
// Zig notes: std.AutoHashMap(K, V) is a hash map. `get(k)` returns an
// optional (null if missing), and `put(k, v)` stores a value. It can run
// out of memory, which we treat as a crash.
//
// YOUR TASK: finish eval(). Then run the tests: the Evaluator computes
// the right answer, but far too slowly. Why?
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

/// The simple recursive version.
fn eval(n: *const Node) f32 {
    return switch (n.op) {
        .constant => n.value,
        .add => eval(n.src[0]) + eval(n.src[1]),
        .mul => ???,
    };
}

/// The version with a memory.
const Evaluator = struct {
    cache: std.AutoHashMap(*const Node, f32),
    calls: usize = 0, // how many nodes we actually computed

    fn eval(e: *Evaluator, n: *const Node) f32 {
        if (e.cache.get(n)) |known| return known;
        e.calls += 1;
        const v: f32 = switch (n.op) {
            .constant => n.value,
            .add => e.eval(n.src[0]) + e.eval(n.src[1]),
            .mul => e.eval(n.src[0]) * e.eval(n.src[1]),
        };
        // ??? We just worked hard for v. Shouldn't we remember it?
        return v;
    }
};

test "eval" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g: Graph = .{ .alloc = arena.allocator() };

    const expr = g.mul(g.add(g.constant(2), g.constant(3)), g.constant(4));
    try std.testing.expectEqual(20, eval(expr));
}

test "each node is computed once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g: Graph = .{ .alloc = arena.allocator() };

    var x = g.constant(1);
    for (0..20) |_| x = g.add(x, x); // 21 nodes in total

    var e: Evaluator = .{ .cache = .init(arena.allocator()) };
    try std.testing.expectEqual(1048576, e.eval(x)); // 2^20
    try std.testing.expectEqual(21, e.calls);
}
