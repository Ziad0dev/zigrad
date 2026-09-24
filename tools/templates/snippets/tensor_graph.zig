const Op = enum { buffer, constant, add, mul, max, sum };

/// A lazy tensor op: `len` elements, computed from `src`.
const Node = struct {
    op: Op,
    src: []const *const Node = &.{},
    len: usize,
    value: f32 = 0, //         for .constant
    name: []const u8 = "", //  for .buffer
};

const Graph = struct {
    alloc: std.mem.Allocator,

    fn buffer(g: Graph, name: []const u8, len: usize) *const Node {
        return g.new(.{ .op = .buffer, .len = len, .name = name });
    }
    fn constant(g: Graph, value: f32, len: usize) *const Node {
        return g.new(.{ .op = .constant, .len = len, .value = value });
    }
    fn add(g: Graph, a: *const Node, b: *const Node) *const Node {
        return g.binary(.add, a, b);
    }
    fn mul(g: Graph, a: *const Node, b: *const Node) *const Node {
        return g.binary(.mul, a, b);
    }
    fn max(g: Graph, a: *const Node, b: *const Node) *const Node {
        return g.binary(.max, a, b);
    }
    fn relu(g: Graph, a: *const Node) *const Node {
        return g.max(a, g.constant(0, a.len));
    }
    fn sum(g: Graph, a: *const Node) *const Node {
        return g.new(.{ .op = .sum, .src = g.dupe(&.{a}), .len = 1 });
    }
    fn binary(g: Graph, op: Op, a: *const Node, b: *const Node) *const Node {
        std.debug.assert(a.len == b.len);
        return g.new(.{ .op = op, .src = g.dupe(&.{ a, b }), .len = a.len });
    }
    fn dupe(g: Graph, src: []const *const Node) []const *const Node {
        return g.alloc.dupe(*const Node, src) catch @panic("out of memory");
    }
    fn new(g: Graph, n: Node) *const Node {
        const p = g.alloc.create(Node) catch @panic("out of memory");
        p.* = n;
        return p;
    }
};
