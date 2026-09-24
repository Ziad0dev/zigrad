// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 071: index expressions and their ranges ──────────────────
//
// Chapter 14 is about the maths tinygrad's compiler does on INDEXES.
//
// Every view in chapter 2 boiled down to an index formula. For a [2, 3]
// tensor read by a kernel with one flat loop variable g in [0, 6):
//
//     row = g // 3,  col = g % 3,  position = row * 3 + col
//
// tinygrad builds these formulas as graphs (of UOps) and simplifies them
// before generating code. Here, position = (g // 3) * 3 + g % 3 is just g!
// Simplified indexes mean faster kernels, and they're how tinygrad proves
// things like "this read is always in bounds".
//
// The key tool: knowing the RANGE of every subexpression. tinygrad calls
// these vmin and vmax. Work them out bottom-up ("interval arithmetic"):
//
//     g in [0, 5]
//     g + 1        in [1, 6]         add the mins, add the maxes
//     g * 3        in [0, 15]        multiply: the min and max of the
//                                    four corner products (signs flip!)
//     g // 3       in [0, 1]         floor-divide both ends (positive divisor)
//     g % 3        in [0, 2]         any x % c lands in [0, c - 1]...
//     g % 8        in [0, 5]         ...unless x already fits in [0, c - 1]
//
// Why corner products for *? Try [-2, 3] * [-4, 1]: the corners are 8,
// -2, -12, 3, so the answer is [-12, 8]. Neither end alone gives it.
//
// YOUR TASK: finish bounds() for add, mul and mod.
//
const std = @import("std");

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

fn bounds(n: *const Node) [2]i64 {
    switch (n.op) {
        .constant => return .{ n.value, n.value },
        .variable => return .{ n.lo, n.hi },
        .add => {
            const a = bounds(n.src[0]);
            const b = bounds(n.src[1]);
            return .{ a[0] + b[0], a[1] + b[1] };
        },
        .mul => {
            const a = bounds(n.src[0]);
            const b = bounds(n.src[1]);
            const p = [_]i64{ a[0] * b[0], a[0] * b[1], a[1] * b[0], a[1] * b[1] };
            return .{ @min(@min(p[0], p[1]), @min(p[2], p[3])), @max(@max(p[0], p[1]), @max(p[2], p[3])) };
        },
        .idiv => {
            const a = bounds(n.src[0]);
            const d = n.src[1].value; // a positive constant
            return .{ @divFloor(a[0], d), @divFloor(a[1], d) };
        },
        .mod => {
            const a = bounds(n.src[0]);
            const d = n.src[1].value;
            if (a[0] >= 0 and a[1] < d) return a;
            return .{ 0, d - 1 };
        },
    }
}

fn expectBounds(lo: i64, hi: i64, n: *const Node) !void {
    try std.testing.expectEqual([2]i64{ lo, hi }, bounds(n));
}

test "ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const x = g.variable("g", 0, 5);

    try expectBounds(1, 6, g.add(x, g.c(1)));
    try expectBounds(0, 15, g.mul(x, g.c(3)));
    try expectBounds(0, 1, g.idiv(x, g.c(3)));
    try expectBounds(0, 2, g.mod(x, g.c(3)));
    try expectBounds(0, 5, g.mod(x, g.c(8)));
    try expectBounds(0, 18, g.add(g.mul(g.idiv(x, g.c(3)), g.c(3)), g.mul(x, g.c(3)))); // (g // 3) * 3 + g * 3
}

test "signs flip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const a = g.variable("a", -2, 3);
    const b = g.variable("b", -4, 1);
    try expectBounds(-12, 8, g.mul(a, b));
}

test "bounds really bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const i = g.variable("i", 0, 11);
    const e = g.add(g.mul(g.mod(i, g.c(4)), g.c(3)), g.idiv(i, g.c(4)));
    const b = bounds(e);
    for (0..12) |v| {
        const x = eval(e, .{ .vars = &.{i}, .values = &.{@intCast(v)} });
        try std.testing.expect(x >= b[0] and x <= b[1]);
    }
}
