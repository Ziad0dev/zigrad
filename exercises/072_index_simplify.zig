//
// ─── Exercise 072: simplifying indexes ─────────────────────────────────
//
// With ranges (071) in hand, the compiler can simplify index maths using
// rules that are only true for certain ranges:
//
//     x % d   -> x     when 0 <= x < d       (already small enough)
//     x // d  -> 0     when 0 <= x < d
//
// and some that are always true for integers:
//
//     (x * d) // d        -> x
//     (x * d + y) // d    -> x + y // d      (floor division of integers)
//     (x * d + y) % d     -> y % d
//     (x // d) * d + x % d -> x              (split a number into
//                                             quotient and remainder,
//                                             then glue it back)
//
// Together they undo the unravel/position dance of chapter 2. For a
// [2, 3] tensor read contiguously by g in [0, 5]:
//
//     (g // 3) * 3 + g % 3   ->   g
//
// These are real tinygrad rewrite rules (in its symbolic simplifier),
// applied with the same bottom-up fixed-point loop as 025.
//
// YOUR TASK: finish modInRange, divInRange, divOfMulAdd and recombine.
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
    if (???) return n.src[0];
    return null;
}

/// x // d -> 0, when x is in [0, d)
fn divInRange(g: *Graph, n: *const Node) ?*const Node {
    if (n.op != .idiv) return null;
    const d = constOf(n.src[1]) orelse return null;
    const b = bounds(n.src[0]);
    if (b[0] >= 0 and b[1] < d) return ???;
    return null;
}

/// (x * d) // d -> x,   (x * d + y) // d -> x + y // d
fn divOfMulAdd(g: *Graph, n: *const Node) ?*const Node {
    if (n.op != .idiv) return null;
    const d = constOf(n.src[1]) orelse return null;
    const a = n.src[0];
    if (timesConst(a, d)) |x| return x;
    if (a.op != .add) return null;
    if (timesConst(a.src[0], d)) |x| return ???;
    if (timesConst(a.src[1], d)) |x| return ???;
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
        if (???) return x;
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
/// Simplify, and check (by brute force) that nothing changed its value.
fn check(g: *Graph, expected: []const u8, e: *const Node, vars: []const *const Node) !void {
    const s = simplify(g, e);
    try expectRender(expected, s);
    // every combination of variable values
    var values: [4]i64 = undefined;
    for (vars, 0..) |v, i| values[i] = v.lo;
    while (true) {
        const env: Env = .{ .vars = vars, .values = values[0..vars.len] };
        try std.testing.expectEqual(eval(e, env), eval(s, env));
        var k: usize = 0;
        while (k < vars.len) : (k += 1) {
            if (values[k] < vars[k].hi) {
                values[k] += 1;
                break;
            }
            values[k] = vars[k].lo;
        }
        if (k == vars.len) break;
    }
}

test "glue quotient and remainder back together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const x = g.variable("g", 0, 5);
    try check(&g, "g", g.add(g.mul(g.idiv(x, g.c(3)), g.c(3)), g.mod(x, g.c(3))), &.{x});
    try check(&g, "g", g.add(g.mod(x, g.c(3)), g.mul(g.idiv(x, g.c(3)), g.c(3))), &.{x});
}

test "split an index apart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const a = g.variable("a", 0, 2);
    const b = g.variable("b", 0, 3);
    const flat = g.add(g.mul(a, g.c(4)), b); // a * 4 + b
    try check(&g, "a", g.idiv(flat, g.c(4)), &.{ a, b });
    try check(&g, "b", g.mod(flat, g.c(4)), &.{ a, b });
}

test "ranges make things vanish" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const b = g.variable("b", 0, 3);
    try check(&g, "b", g.mod(b, g.c(8)), &.{b});
    try check(&g, "0", g.idiv(b, g.c(8)), &.{b});
    try check(&g, "(b % 3)", g.add(g.mul(g.mod(b, g.c(3)), g.c(1)), g.c(0)), &.{b});
    // not simplifiable: b % 3 really can wrap
    try check(&g, "((b + 2) % 3)", g.mod(g.add(b, g.c(2)), g.c(3)), &.{b});
}
