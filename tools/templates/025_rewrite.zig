//
// ─── Exercise 025: rewrite rules ───────────────────────────────────────
//
// Here's the secret of tinygrad's compiler: almost all of it is ONE
// mechanism, graph rewriting. You write a list of rules, each saying
// "if a node looks like THIS, replace it with THAT", and
// `graph_rewrite(graph, PatternMatcher([...rules]))` applies them until
// nothing matches any more. Simplifying maths, turning tensor ops into
// index maths, lowering to GPU instructions: all just lists of rules.
//
// Some simple, always-true rules:
//
//     x + 0  ->  x
//     x * 1  ->  x
//     x * 0  ->  0
//     2 + 3  ->  5          ("constant folding": do the maths right now)
//
// And the procedure:
//   1. rewrite the sources first (bottom-up)
//   2. rebuild the node with the new sources. Thanks to deduplication
//      (exercise 024), that's free when nothing changed.
//   3. try every rule on it. If one fires, take the replacement and try
//      the rules again. Stop when no rule matches.
//
//     (x * 1 + 0) * (2 + 3)   ->   (x + 0) * 5   ->   x * 5
//
// YOUR TASK: write mulOne(), mulZero() and the heart of fold().
//
const std = @import("std");

const Op = enum { constant, variable, add, mul };

const Node = struct {
    op: Op,
    src: []const *const Node = &.{},
    value: f32 = 0, //         for .constant
    name: []const u8 = "", //  for .variable
};

const Key = struct { op: Op, a: ?*const Node, b: ?*const Node, bits: u32 };

/// A deduplicating graph, from exercise 024.
const Graph = struct {
    alloc: std.mem.Allocator,
    cache: std.AutoHashMap(Key, *const Node),

    fn new(g: *Graph, op: Op, src: []const *const Node, value: f32) *const Node {
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
        const n = g.alloc.create(Node) catch @panic("out of memory");
        n.* = .{ .op = .variable, .name = name };
        return n;
    }
    fn constant(g: *Graph, value: f32) *const Node {
        return g.new(.constant, &.{}, value);
    }
    fn add(g: *Graph, a: *const Node, b: *const Node) *const Node {
        return g.new(.add, &.{ a, b }, 0);
    }
    fn mul(g: *Graph, a: *const Node, b: *const Node) *const Node {
        return g.new(.mul, &.{ a, b }, 0);
    }
};

fn isConst(n: *const Node, value: f32) bool {
    return n.op == .constant and n.value == value;
}

/// A rule returns the replacement node, or null if it doesn't match.
const Rule = *const fn (g: *Graph, n: *const Node) ?*const Node;

/// x + 0 -> x, and 0 + x -> x
fn addZero(g: *Graph, n: *const Node) ?*const Node {
    _ = g;
    if (n.op != .add) return null;
    if (isConst(n.src[1], 0)) return n.src[0];
    if (isConst(n.src[0], 0)) return n.src[1];
    return null;
}

/// x * 1 -> x, and 1 * x -> x
fn mulOne(g: *Graph, n: *const Node) ?*const Node {
    _ = g;
//⟪
    if (n.op != .mul) return null;
    if (isConst(n.src[1], 1)) return n.src[0];
    if (isConst(n.src[0], 1)) return n.src[1];
    return null;
//|||
    ???
//⟫
}

/// x * 0 -> 0, and 0 * x -> 0
fn mulZero(g: *Graph, n: *const Node) ?*const Node {
//⟪
    if (n.op != .mul) return null;
    if (isConst(n.src[0], 0) or isConst(n.src[1], 0)) return g.constant(0);
    return null;
//|||
    ???
//⟫
}

/// Constant folding: when both sources are constants, do the maths now.
fn fold(g: *Graph, n: *const Node) ?*const Node {
    if (n.op != .add and n.op != .mul) return null;
    const x = n.src[0];
    const y = n.src[1];
    if (x.op != .constant or y.op != .constant) return null;
    return g.constant(⟪if (n.op == .add) x.value + y.value else x.value * y.value|||???⟫);
}

const rules = [_]Rule{ &addZero, &mulOne, &mulZero, &fold };

fn rewrite(g: *Graph, n: *const Node) *const Node {
    // 1 + 2. rewrite the sources, then rebuild this node on top of them
    var cur = n;
    if (n.op == .add or n.op == .mul) {
        cur = g.new(n.op, &.{ rewrite(g, n.src[0]), rewrite(g, n.src[1]) }, 0);
    }
    // 3. apply rules until none match
    search: while (true) {
        for (rules) |rule| {
            if (rule(g, cur)) |replacement| {
                cur = replacement;
                continue :search;
            }
        }
        return cur;
    }
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
    }
}

fn expectRewrite(expected: []const u8, g: *Graph, n: *const Node) !void {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(rewrite(g, n), &w);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "simplify" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .{ .alloc = arena.allocator(), .cache = .init(arena.allocator()) };
    const x = g.variable("x");
    const y = g.variable("y");

    // (x * 1 + 0) * (2 + 3)
    try expectRewrite("(x * 5)", &g, g.mul(g.add(g.mul(x, g.constant(1)), g.constant(0)), g.add(g.constant(2), g.constant(3))));
    // x * (y * 0) + 7
    try expectRewrite("7", &g, g.add(g.mul(x, g.mul(y, g.constant(0))), g.constant(7)));
    // ((2 * 3) + x) * 1
    try expectRewrite("(6 + x)", &g, g.mul(g.add(g.mul(g.constant(2), g.constant(3)), x), g.constant(1)));
    // nothing to do
    try expectRewrite("(x + y)", &g, g.add(x, y));
}

test "x + 0 gives back x itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .{ .alloc = arena.allocator(), .cache = .init(arena.allocator()) };
    const x = g.variable("x");
    try std.testing.expect(rewrite(&g, g.add(x, g.constant(0))) == x);
}
