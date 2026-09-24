// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 075: symbolic shapes ─────────────────────────────────────
//
// A language model generating text processes a sequence whose length n
// grows by one every step: 1, 2, 3, ... 2048. Compiling a fresh kernel
// for every length would be painfully slow.
//
// tinygrad's answer: let a shape contain a *Variable*, n in [1, 2048],
// and compile the kernel ONCE, with n as an argument. The index maths
// just carries n around symbolically:
//
//     a [4, n] tensor has strides [n, 1]    position = r * n + j
//     a [4, n, 2] tensor has strides [2n, 2, 1]
//
// At run time, you *bind* n to its current value and launch the same
// compiled kernel. (In tinygrad: Variable("n", 1, 2048).bind(17).)
//
// The kernel cache is keyed by the kernel's code, which says "n", not
// "17", so every length hits the same cache entry.
//
// YOUR TASK: finish symbolicStrides() and the binding in rowSums().
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

/// Contiguous strides for a shape whose sizes are expressions (006).
fn symbolicStrides(g: *Graph, shape: []const *const Node, out: []*const Node) void {
    var step = g.c(1);
    var i = shape.len;
    while (i > 0) {
        i -= 1;
        out[i] = step;
        step = simplify(g, g.mul(step, shape[i]));
    }
}

/// A "compiled kernel": the index expression, plus a cache of compiles.
const Kernels = struct {
    compiles: usize = 0,
    cached: ?*const Node = null,

    fn get(k: *Kernels, e: *const Node) *const Node {
        if (k.cached != e) { // dedup makes "same code" a pointer compare
            k.compiles += 1;
            k.cached = e;
        }
        return e;
    }
};

/// The kernel's loop variables. They belong to the kernel, so they're made
/// once: fresh variables would be different nodes, and a different kernel.
const Loops = struct { r: *const Node, j: *const Node };

/// Sum each row of a [4, n] contiguous tensor, for the current n.
fn rowSums(g: *Graph, kernels: *Kernels, loops: Loops, n_var: *const Node, n: i64, data: []const f32, out: *[4]f32) void {
    const r = loops.r;
    const j = loops.j;
    var strides: [2]*const Node = undefined;
    symbolicStrides(g, &.{ g.c(4), n_var }, &strides);
    const pos = kernels.get(simplify(g, g.add(g.mul(r, strides[0]), g.mul(j, strides[1]))));

    for (out, 0..) |*o, row| {
        o.* = 0;
        var col: i64 = 0;
        while (col < n) : (col += 1) {
            const env: Env = .{ .vars = &.{ r, j, n_var }, .values = &.{ @intCast(row), col, n } };
            o.* += data[@intCast(eval(pos, env))];
        }
    }
}

test "symbolic strides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const n = g.variable("n", 1, 16);
    var strides: [3]*const Node = undefined;
    symbolicStrides(&g, &.{ g.c(4), n, g.c(2) }, &strides);
    try expectRender("(2 * n)", strides[0]);
    try expectRender("2", strides[1]);
    try expectRender("1", strides[2]);
}

test "one kernel for every length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const n_var = g.variable("n", 1, 16);
    var kernels: Kernels = .{};
    const loops: Loops = .{ .r = g.variable("r", 0, 3), .j = g.variable("j", 0, 15) }; // j < n <= 16

    var data: [64]f32 = undefined;
    for (&data, 0..) |*d, i| d.* = @floatFromInt(i);
    for ([_]i64{ 3, 5, 7 }) |n| {
        var sums: [4]f32 = undefined;
        rowSums(&g, &kernels, loops, n_var, n, &data, &sums);
        const nf: f32 = @floatFromInt(n);
        for (sums, 0..) |s, row| {
            // row r holds r*n, r*n + 1, ..., r*n + n - 1
            const first = @as(f32, @floatFromInt(row)) * nf;
            try std.testing.expectEqual(nf * first + nf * (nf - 1) / 2, s);
        }
    }
    try std.testing.expectEqual(1, kernels.compiles);
}
