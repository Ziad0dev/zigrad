// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 073: a view is an index expression ───────────────────────
//
// Chapter 2's views, and 071-072's expressions, are the same thing. A
// kernel loops over a flat g, and a view turns g into a memory position:
//
//     for each dimension k, from the last:
//         i_k = (g // inner) % shape[k]        (unravel, 008)
//         pos += i_k * strides[k]              (position, 007)
//         inner *= shape[k]
//
// Build that as a graph, simplify it (072), and the movement ops turn
// into strikingly simple maths:
//
//     contiguous [2, 3]:            g
//     row 1 (offset 3):             3 + g
//     transposed [3, 2]:            (g % 2) * 3 + g // 2
//     broadcast [3] to [2, 3]:      g % 3             <- expand is modulo!
//
// This is what tinygrad actually generates code from. (Newer tinygrad
// versions go further and build these index graphs directly, instead of
// storing View objects at all.) Masks (014) work the same way, as a
// "valid" condition expression, like 1 <= i && i < 4, next to the index.
//
// YOUR TASK: finish viewIndex().
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

/// The smallest and largest value n can take (exercise 071).
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

// Simplification rules (exercise 072).
fn constOf(n: *const Node) ?i64 {
    return if (n.op == .constant) n.value else null;
}

/// If n is x * d, returns x.
fn timesConst(n: *const Node, d: i64) ?*const Node {
    if (n.op == .mul and constOf(n.src[1]) == d) return n.src[0];
    return null;
}

const Rule = *const fn (g: *Graph, n: *const Node) ?*const Node;

/// Do the arithmetic when every source is a constant.
fn fold(g: *Graph, n: *const Node) ?*const Node {
    if (n.src.len != 2) return null;
    const a = constOf(n.src[0]) orelse return null;
    const b = constOf(n.src[1]) orelse return null;
    return g.c(switch (n.op) {
        .add => a + b,
        .mul => a * b,
        .idiv => @divFloor(a, b),
        .mod => @mod(a, b),
        else => unreachable,
    });
}

/// x + 0, x * 1, x * 0, x // 1, x % 1
fn identities(g: *Graph, n: *const Node) ?*const Node {
    if (n.src.len != 2) return null;
    const a = n.src[0];
    const b = n.src[1];
    switch (n.op) {
        .add => {
            if (constOf(b) == 0) return a;
            if (constOf(a) == 0) return b;
        },
        .mul => {
            if (constOf(b) == 1) return a;
            if (constOf(a) == 1) return b;
            if (constOf(a) == 0 or constOf(b) == 0) return g.c(0);
        },
        .idiv => if (constOf(b) == 1) return a,
        .mod => if (constOf(b) == 1) return g.c(0),
        else => {},
    }
    return null;
}

/// x % d -> x, when x is already in [0, d)
fn modInRange(g: *Graph, n: *const Node) ?*const Node {
    _ = g;
    if (n.op != .mod) return null;
    const d = constOf(n.src[1]) orelse return null;
    const b = bounds(n.src[0]);
    if (b[0] >= 0 and b[1] < d) return n.src[0];
    return null;
}

/// x // d -> 0, when x is in [0, d)
fn divInRange(g: *Graph, n: *const Node) ?*const Node {
    if (n.op != .idiv) return null;
    const d = constOf(n.src[1]) orelse return null;
    const b = bounds(n.src[0]);
    if (b[0] >= 0 and b[1] < d) return g.c(0);
    return null;
}

/// (x * d) // d -> x,   (x * d + y) // d -> x + y // d
fn divOfMulAdd(g: *Graph, n: *const Node) ?*const Node {
    if (n.op != .idiv) return null;
    const d = constOf(n.src[1]) orelse return null;
    const a = n.src[0];
    if (timesConst(a, d)) |x| return x;
    if (a.op != .add) return null;
    if (timesConst(a.src[0], d)) |x| return g.add(x, g.idiv(a.src[1], n.src[1]));
    if (timesConst(a.src[1], d)) |x| return g.add(x, g.idiv(a.src[0], n.src[1]));
    return null;
}

/// (x * d) % d -> 0,   (x * d + y) % d -> y % d
fn modOfMulAdd(g: *Graph, n: *const Node) ?*const Node {
    if (n.op != .mod) return null;
    const d = constOf(n.src[1]) orelse return null;
    const a = n.src[0];
    if (timesConst(a, d) != null) return g.c(0);
    if (a.op != .add) return null;
    if (timesConst(a.src[0], d) != null) return g.mod(a.src[1], n.src[1]);
    if (timesConst(a.src[1], d) != null) return g.mod(a.src[0], n.src[1]);
    return null;
}

/// (x // d) * d + x % d -> x   (in either order)
fn recombine(g: *Graph, n: *const Node) ?*const Node {
    _ = g;
    if (n.op != .add) return null;
    for ([_][2]*const Node{ .{ n.src[0], n.src[1] }, .{ n.src[1], n.src[0] } }) |pair| {
        const div_part = pair[0]; // (x // d) * d ?
        const mod_part = pair[1]; // x % d ?
        if (mod_part.op != .mod) continue;
        const x = mod_part.src[0];
        const d = constOf(mod_part.src[1]) orelse continue;
        const q = timesConst(div_part, d) orelse continue; // q should be x // d
        if (q.op == .idiv and q.src[0] == x and constOf(q.src[1]) == d) return x;
    }
    return null;
}

const rules = [_]Rule{ &fold, &identities, &modInRange, &divInRange, &divOfMulAdd, &modOfMulAdd, &recombine };

fn simplify(g: *Graph, n: *const Node) *const Node {
    var cur = n;
    if (n.src.len == 2) cur = g.new(n.op, &.{ simplify(g, n.src[0]), simplify(g, n.src[1]) }, 0);
    search: while (true) {
        for (rules) |rule| {
            if (rule(g, cur)) |next| {
                cur = simplify(g, next);
                continue :search;
            }
        }
        return cur;
    }
}

/// The memory position that loop variable `gv` reads, through a view.
fn viewIndex(g: *Graph, gv: *const Node, shape: []const i64, strides: []const i64, offset: i64) *const Node {
    var pos = g.c(offset);
    var inner: i64 = 1;
    var k = shape.len;
    while (k > 0) {
        k -= 1;
        const i_k = g.mod(g.idiv(gv, g.c(inner)), g.c(shape[k]));
        pos = g.add(pos, g.mul(i_k, g.c(strides[k])));
        inner *= shape[k];
    }
    return simplify(g, pos);
}

fn positions(e: *const Node, gv: *const Node, out: []i64) void {
    for (out, 0..) |*o, i| o.* = eval(e, .{ .vars = &.{gv}, .values = &.{@intCast(i)} });
}

test "contiguous is just g" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const gv = g.variable("g", 0, 5);
    try expectRender("g", viewIndex(&g, gv, &.{ 2, 3 }, &.{ 3, 1 }, 0));
    try expectRender("(3 + g)", viewIndex(&g, g.variable("g", 0, 2), &.{3}, &.{1}, 3));
}

test "transpose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const gv = g.variable("g", 0, 5);
    const e = viewIndex(&g, gv, &.{ 3, 2 }, &.{ 1, 3 }, 0);
    try expectRender("(((g % 2) * 3) + (g // 2))", e);
    var pos: [6]i64 = undefined;
    positions(e, gv, &pos);
    try std.testing.expectEqualSlices(i64, &.{ 0, 3, 1, 4, 2, 5 }, &pos); // exercise 011's order
}

test "expand is modulo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const gv = g.variable("g", 0, 5);
    try expectRender("(g % 3)", viewIndex(&g, gv, &.{ 2, 3 }, &.{ 0, 1 }, 0));
}

test "3D contiguous still reads in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const gv = g.variable("g", 0, 23);
    var pos: [24]i64 = undefined;
    positions(viewIndex(&g, gv, &.{ 2, 3, 4 }, &.{ 12, 4, 1 }, 0), gv, &pos);
    for (pos, 0..) |p, i| try std.testing.expectEqual(@as(i64, @intCast(i)), p);
}
