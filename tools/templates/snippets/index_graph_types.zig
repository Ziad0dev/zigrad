const Op = enum { constant, variable, add, mul, idiv, mod };

/// An integer index expression. Variables have a range [lo, hi], inclusive.
const Node = struct {
    op: Op,
    src: []const *const Node = &.{},
    value: i64 = 0, //         .constant
    name: []const u8 = "", //  .variable
    lo: i64 = 0, //            .variable
    hi: i64 = 0, //            .variable
};

const Key = struct { op: Op, a: ?*const Node, b: ?*const Node, value: i64 };

const Graph = struct {
    alloc: std.mem.Allocator,
    cache: std.AutoHashMap(Key, *const Node),

    fn init(alloc: std.mem.Allocator) Graph {
        return .{ .alloc = alloc, .cache = .init(alloc) };
    }

    fn new(g: *Graph, op: Op, src: []const *const Node, value: i64) *const Node {
        const key: Key = .{
            .op = op,
            .a = if (src.len > 0) src[0] else null,
            .b = if (src.len > 1) src[1] else null,
            .value = value,
        };
        if (g.cache.get(key)) |existing| return existing;
        const n = g.alloc.create(Node) catch @panic("out of memory");
        n.* = .{ .op = op, .src = g.alloc.dupe(*const Node, src) catch @panic("out of memory"), .value = value };
        g.cache.put(key, n) catch @panic("out of memory");
        return n;
    }

    /// A loop variable that takes every value in [lo, hi].
    fn variable(g: *Graph, name: []const u8, lo: i64, hi: i64) *const Node {
        const n = g.alloc.create(Node) catch @panic("out of memory");
        n.* = .{ .op = .variable, .name = name, .lo = lo, .hi = hi };
        return n;
    }
    fn constant(g: *Graph, v: i64) *const Node {
        return g.new(.constant, &.{}, v);
    }
    fn add(g: *Graph, a: *const Node, b: *const Node) *const Node {
        return g.new(.add, &.{ a, b }, 0);
    }
    fn mul(g: *Graph, a: *const Node, b: *const Node) *const Node {
        return g.new(.mul, &.{ a, b }, 0);
    }
    fn idiv(g: *Graph, a: *const Node, b: *const Node) *const Node {
        return g.new(.idiv, &.{ a, b }, 0);
    }
    fn mod(g: *Graph, a: *const Node, b: *const Node) *const Node {
        return g.new(.mod, &.{ a, b }, 0);
    }
    fn c(g: *Graph, v: i64) *const Node {
        return g.constant(v);
    }
};

/// Values for variables, by pointer.
const Env = struct {
    vars: []const *const Node,
    values: []const i64,

    fn get(env: Env, n: *const Node) i64 {
        for (env.vars, env.values) |v, x| {
            if (v == n) return x;
        }
        @panic("unbound variable");
    }
};

fn eval(n: *const Node, env: Env) i64 {
    return switch (n.op) {
        .constant => n.value,
        .variable => env.get(n),
        .add => eval(n.src[0], env) + eval(n.src[1], env),
        .mul => eval(n.src[0], env) * eval(n.src[1], env),
        .idiv => @divFloor(eval(n.src[0], env), eval(n.src[1], env)),
        .mod => @mod(eval(n.src[0], env), eval(n.src[1], env)),
    };
}

fn render(n: *const Node, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (n.op) {
        .constant => try w.print("{d}", .{n.value}),
        .variable => try w.writeAll(n.name),
        .add, .mul, .idiv, .mod => {
            try w.writeAll("(");
            try render(n.src[0], w);
            try w.writeAll(switch (n.op) {
                .add => " + ",
                .mul => " * ",
                .idiv => " // ",
                else => " % ",
            });
            try render(n.src[1], w);
            try w.writeAll(")");
        },
    }
}

fn expectRender(expected: []const u8, n: *const Node) !void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(n, &w);
    try std.testing.expectEqualStrings(expected, w.buffered());
}
