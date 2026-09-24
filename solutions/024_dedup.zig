// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 024: build each node only once ───────────────────────────
//
// If you build 2 + 3 twice, should you get two nodes, or the same one?
//
// tinygrad says: the same one. When you create a UOp, tinygrad first
// checks a cache for an existing UOp with the same op, sources and
// argument. If there is one, you get that object back. (This trick is
// called *hash-consing*.) It's surprisingly powerful:
//
//   * "Are these two graphs the same?" becomes a pointer comparison.
//   * Repeated work merges automatically. In (x + y) * (x + y), the two
//     x + y ARE the same node, so it's only ever computed once.
//   * The graph stays small.
//
// Our cache key is (op, first source, second source, value). Source
// pointers are unique because the sources were deduplicated too.
//
// Why store the value's raw bits instead of the f32? Hash maps need
// "equal" to be simple, and floats aren't: nan != nan, but 0.0 == -0.0.
// @bitCast reinterprets the 32 bits of an f32 as a u32, without changing
// them.
//
// YOUR TASK: finish Graph.new().
//
const std = @import("std");

const Op = enum { constant, add, mul };

const Node = struct {
    op: Op,
    src: []const *const Node = &.{},
    value: f32 = 0,
};

const Key = struct {
    op: Op,
    a: ?*const Node,
    b: ?*const Node,
    bits: u32,
};

const Graph = struct {
    alloc: std.mem.Allocator,
    cache: std.AutoHashMap(Key, *const Node),
    created: usize = 0,

    fn new(g: *Graph, op: Op, src: []const *const Node, value: f32) *const Node {
        const key: Key = .{
            .op = op,
            .a = if (src.len > 0) src[0] else null,
            .b = if (src.len > 1) src[1] else null,
            .bits = @bitCast(value),
        };
        // Seen this exact node before? Hand back the one we already have.
        if (g.cache.get(key)) |existing| return existing;

        const n = g.alloc.create(Node) catch @panic("out of memory");
        n.* = .{
            .op = op,
            .src = g.alloc.dupe(*const Node, src) catch @panic("out of memory"),
            .value = value,
        };
        g.cache.put(key, n) catch @panic("out of memory");
        g.created += 1;
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

test "same recipe, same node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .{ .alloc = arena.allocator(), .cache = .init(arena.allocator()) };

    try std.testing.expect(g.constant(2) == g.constant(2));
    try std.testing.expect(g.constant(2) != g.constant(3));

    const x = g.constant(2);
    const y = g.constant(3);
    try std.testing.expect(g.add(x, y) == g.add(x, y));
    try std.testing.expect(g.add(x, y) != g.mul(x, y));
}

test "(x + y) * (x + y) has just 4 nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .{ .alloc = arena.allocator(), .cache = .init(arena.allocator()) };

    const x = g.constant(2);
    const y = g.constant(3);
    const out = g.mul(g.add(x, y), g.add(x, y));
    try std.testing.expect(out.src[0] == out.src[1]);
    try std.testing.expectEqual(4, g.created);
}
