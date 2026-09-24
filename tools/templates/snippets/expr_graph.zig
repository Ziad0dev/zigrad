const Op = enum { constant, variable, add, mul, sin, cos };

const Node = struct {
    op: Op,
    src: []const *const Node = &.{},
    value: f64 = 0, //         .constant
    name: []const u8 = "", //  .variable
};

const Key = struct { op: Op, a: ?*const Node, b: ?*const Node, bits: u64 };

/// A deduplicating expression graph (exercises 024 and 025).
const Graph = struct {
    alloc: std.mem.Allocator,
    cache: std.AutoHashMap(Key, *const Node),
    vars: std.StringHashMap(*const Node),

    fn init(alloc: std.mem.Allocator) Graph {
        return .{ .alloc = alloc, .cache = .init(alloc), .vars = .init(alloc) };
    }

    fn new(g: *Graph, op: Op, src: []const *const Node, value: f64) *const Node {
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
        if (g.vars.get(name)) |v| return v;
        const n = g.alloc.create(Node) catch @panic("out of memory");
        n.* = .{ .op = .variable, .name = name };
        g.vars.put(name, n) catch @panic("out of memory");
        return n;
    }
    fn constant(g: *Graph, value: f64) *const Node {
        return g.new(.constant, &.{}, value);
    }
    fn add(g: *Graph, a: *const Node, b: *const Node) *const Node {
        return g.new(.add, &.{ a, b }, 0);
    }
    fn mul(g: *Graph, a: *const Node, b: *const Node) *const Node {
        return g.new(.mul, &.{ a, b }, 0);
    }
    fn sin(g: *Graph, a: *const Node) *const Node {
        return g.new(.sin, &.{a}, 0);
    }
    fn cos(g: *Graph, a: *const Node) *const Node {
        return g.new(.cos, &.{a}, 0);
    }
};

/// Evaluate with every variable set to `x`.
fn eval(n: *const Node, x: f64) f64 {
    return switch (n.op) {
        .constant => n.value,
        .variable => x,
        .add => eval(n.src[0], x) + eval(n.src[1], x),
        .mul => eval(n.src[0], x) * eval(n.src[1], x),
        .sin => @sin(eval(n.src[0], x)),
        .cos => @cos(eval(n.src[0], x)),
    };
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
        .sin, .cos => {
            try w.writeAll(if (n.op == .sin) "sin(" else "cos(");
            try render(n.src[0], w);
            try w.writeAll(")");
        },
    }
}

// ─── Simplification (exercise 025) ───

fn isConst(n: *const Node, value: f64) bool {
    return n.op == .constant and n.value == value;
}

fn simplifyOnce(g: *Graph, n: *const Node) ?*const Node {
    switch (n.op) {
        .add => {
            if (isConst(n.src[1], 0)) return n.src[0];
            if (isConst(n.src[0], 0)) return n.src[1];
        },
        .mul => {
            if (isConst(n.src[1], 1)) return n.src[0];
            if (isConst(n.src[0], 1)) return n.src[1];
            if (isConst(n.src[0], 0) or isConst(n.src[1], 0)) return g.constant(0);
        },
        else => {},
    }
    if ((n.op == .add or n.op == .mul) and n.src[0].op == .constant and n.src[1].op == .constant) {
        const a = n.src[0].value;
        const b = n.src[1].value;
        return g.constant(if (n.op == .add) a + b else a * b);
    }
    return null;
}

fn simplify(g: *Graph, n: *const Node) *const Node {
    var cur = n;
    switch (n.op) {
        .add, .mul => cur = g.new(n.op, &.{ simplify(g, n.src[0]), simplify(g, n.src[1]) }, 0),
        .sin, .cos => cur = g.new(n.op, &.{simplify(g, n.src[0])}, 0),
        else => {},
    }
    while (simplifyOnce(g, cur)) |next| cur = next;
    return cur;
}

fn toposort(alloc: std.mem.Allocator, n: *const Node, visited: *std.AutoHashMap(*const Node, void), order: *std.ArrayList(*const Node)) error{OutOfMemory}!void {
    if (visited.contains(n)) return;
    try visited.put(n, {});
    for (n.src) |s| try toposort(alloc, s, visited, order);
    try order.append(alloc, n);
}
