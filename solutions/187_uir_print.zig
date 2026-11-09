// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 187: printing UIR ───────────────────────────────────────
//
// The other direction: a UOp graph back to text (tinygrad: render_uir).
// You need it all the time: to write tests, to dump what your compiler did
// to a graph (tinygrad prints this with DEBUG=5), to diff two versions.
//
// The recipe:
//   1. toposort the graph (023), so every UOp comes after its srcs;
//   2. give each one a line, %0, %1, ..., in that order;
//   3. write srcs as %ids, then the args as key=value.
//
// Except that literals don't get lines. A CONST is written in place, and
// so is a STACK whose srcs are all CONSTs: `[0 1 2]`. That's what keeps
// UIR short enough to read. (A STACK of STACKs gets a line; its inner
// STACKs are inline.)
//
// A float must still look like a float when it comes back: 100.0 printed
// as "100" would be parsed as the int 100, a weakint (181). So a float
// that has no '.', 'e', "inf" or "nan" in its digits gets a ".0".
//
// Args, in tinygrad's order: a buffer's `slot=0 dtype=f32`, a range's
// `slot=0`, a reduce's `op=add`, plus ` pop=n` only when n isn't 0, and a
// cast's `dtype=i32`.
//
// Since UOps are hash-consed, parse(print(x)) is x itself: the very same
// pointer. That's the test.
//
// YOUR TASK: finish isInline(), the float rule, the reduce args, and the
// inline STACK in writeSrc().
//
const std = @import("std");

/// Literals are written in place: a CONST, or a STACK of CONSTs.
fn isInline(u: *const UOp) bool {
    if (u.op == .constant) return true;
    if (u.op != .stack) return false;
    for (u.src) |s| {
        if (s.op != .constant) return false;
    }
    return true;
}

fn writeLiteral(u: *const UOp, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (u.arg) {
        .int => |v| try w.print("{d}", .{v}),
        .boolean => |v| try w.writeAll(if (v) "true" else "false"),
        .float => |v| {
            if (std.math.isNan(v)) return w.writeAll("nan");
            if (std.math.isInf(v)) return w.writeAll(if (v > 0) "inf" else "-inf");
            var buf: [64]u8 = undefined;
            const digits = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
            try w.writeAll(digits);
            // 100.0 must not come back as the int 100
            if (std.mem.indexOfAny(u8, digits, ".e") == null) try w.writeAll(".0");
        },
        else => unreachable,
    }
}

const Ids = std.AutoHashMap(*const UOp, usize);

fn writeSrc(u: *const UOp, ids: *const Ids, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (ids.get(u)) |id| return w.print("%{d}", .{id});
    if (u.op == .constant) return writeLiteral(u, w);
    // an inline STACK: [a b c]
    try w.writeAll("[");
    for (u.src, 0..) |s, i| {
        if (i > 0) try w.writeAll(" ");
        try writeSrc(s, ids, w);
    }
    try w.writeAll("]");
}

fn writeArgs(u: *const UOp, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (u.op) {
        .buffer, .param, .alloc => try w.print(" slot={d} dtype={s}", .{ u.arg.param.slot, @tagName(u.arg.param.dtype) }),
        .range => try w.print(" slot={d}", .{u.arg.int}),
        .cast => try w.print(" dtype={s}", .{@tagName(u.arg.dtype)}),
        .reduce => {
            try w.print(" op={s}", .{@tagName(u.arg.reduce.op)});
            if (u.arg.reduce.pop != 0) try w.print(" pop={d}", .{u.arg.reduce.pop});
        },
        else => {},
    }
}

/// One line per UOp: %id = op srcs key=value. (tinygrad: render_uir)
fn printUir(g: *Graph, root: *const UOp, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var ids = Ids.init(g.alloc);
    for (toposort(g, root, true)) |u| {
        if (isInline(u)) continue;
        const id = ids.count();
        try w.print("%{d} = {s}", .{ id, @tagName(u.op) });
        for (u.src) |s| {
            try w.writeAll(" ");
            try writeSrc(s, &ids, w);
        }
        try writeArgs(u, w);
        try w.writeAll("\n");
        ids.put(u, id) catch @panic("out of memory");
    }
    // a root that is a literal has no line of its own: give it one
    if (isInline(root)) {
        try w.print("%{d} = ", .{ids.count()});
        try writeSrc(root, &ids, w);
        try w.writeAll("\n");
    }
}

const t = std.testing;

fn printed(g: *Graph, root: *const UOp) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(g.alloc);
    try printUir(g, root, &out.writer);
    return out.written();
}

test "week 3, printed the way tinygrad prints it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const root = try parseUir(&g,
        \\%buf = buffer 3 slot=0 dtype=i32
        \\%i = range 3 slot=0
        \\%write = store (index %buf %i) %i
        \\%done = end %write %i
        \\%test = assert (after %buf %done) [0 1 2]
    );
    try t.expectEqualStrings(
        \\%0 = buffer 3 slot=0 dtype=i32
        \\%1 = range 3 slot=0
        \\%2 = index %0 %1
        \\%3 = store %2 %1
        \\%4 = end %3 %1
        \\%5 = after %0 %4
        \\%6 = assert %5 [0 1 2]
        \\
    , try printed(&g, root));
}

test "args and literals" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = try g.reshape(g.buffer(1, .f32, 6), &.{ 2, 3 });
    try t.expectEqualStrings(
        \\%0 = buffer 6 slot=1 dtype=f32
        \\%1 = reshape %0 [2 3]
        \\%2 = reduce %1 op=max pop=1
        \\%3 = reduce %2 op=add
        \\
    , try printed(&g, try g.reduce(try g.reduce(x, .max, 1), .add, 0)));
    try t.expectEqualStrings("%0 = add 100.0 0.5\n", try printed(&g, try g.add(g.float(100), g.float(0.5))));
    try t.expectEqualStrings("%0 = add -inf 7\n", try printed(&g, try g.add(g.float(-std.math.inf(f64)), g.int(7))));
    try t.expectEqualStrings("%0 = cast true dtype=i32\n", try printed(&g, try g.cast(g.boolean(true), .i32)));
    try t.expectEqualStrings("%0 = [1 2 3]\n", try printed(&g, g.ints(&.{ 1, 2, 3 })));
    try t.expectEqualStrings("%0 = stack [1 2] [3 4]\n", try printed(&g, try g.stack(&.{ g.ints(&.{ 1, 2 }), g.ints(&.{ 3, 4 }) })));
}

test "parse(print(x)) is x" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const programs = [_][]const u8{
        "%sum = add 2 3\n%test = assert %sum 5",
        "%buf = buffer [] slot=0 dtype=i32\n%w = store %buf 7\n%r = after %buf %w\n%v = load %r\n%t = assert %v 7",
        "%values = add [1 2 3] (expand 1 3)\n%sum = reduce %values op=add pop=1\n%test = assert %sum 9",
        "%m = reshape [1 2 3 4] [2 2]\n%tr = permute %m [1 0]\n%test = assert (index %tr 1 0) 2",
        "%x = pad (shrink [1.5 2.5 3.5] [1] [2]) [1] [4]\n%y = where (cmplt %x (expand 2.0 4)) %x (expand 0.1 4)",
        "%b = buffer 8 slot=2 dtype=f32\n%c = cast (load (index %b 3)) dtype=i32\n%d = add %c 0x10",
    };
    for (programs) |text| {
        const root = try parseUir(&g, text);
        try t.expect(try parseUir(&g, try printed(&g, root)) == root);
    }
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

const DType = enum {
    void,
    bool,
    weakint,
    i32,
    weakfloat,
    f32,

    fn isInt(d: DType) bool {
        return d == .weakint or d == .i32;
    }
    fn isFloat(d: DType) bool {
        return d == .weakfloat or d == .f32;
    }
};

/// A literal as written in a program: a bool, an integer or a float.
const Literal = union(enum) { boolean: bool, int: i64, float: f64 };

/// The dtype of a bare literal. tinygrad: the CONST case of dtype_from_uop.
fn literalDType(lit: Literal) DType {
    return switch (lit) {
        .boolean => .bool,
        .int => .weakint,
        .float => .weakfloat,
    };
}

/// Where a type sits on the chain bool -> weakint -> i32 -> weakfloat -> f32.
fn rank(d: DType) u8 {
    return switch (d) {
        .void => unreachable, // void has no value, so it never meets anything
        .bool => 0,
        .weakint => 1,
        .i32 => 2,
        .weakfloat => 3,
        .f32 => 4,
    };
}

/// The least upper bound: the dtype of a + b. tinygrad: least_upper_dtype.
fn lub(a: DType, b: DType) DType {
    return if (rank(a) >= rank(b)) a else b;
}

/// The dtype a value gets when it has to be stored. tinygrad: strong_dtype.
fn commit(d: DType) DType {
    return switch (d) {
        .weakint => .i32,
        .weakfloat => .f32,
        else => d,
    };
}

/// Float-only ops (RECIP, EXP2, ...) need a float. tinygrad: least_upper_float.
fn leastUpperFloat(d: DType) DType {
    if (d == .weakint) return .weakfloat;
    if (d.isFloat()) return d;
    return lub(d, .f32);
}

const Op = enum {
    constant, // a literal; its value is the arg
    param, //    an input of a CALL. arg: slot and dtype. src[0]: its shape
    call, //     src[0] is the body, src[1..] are the arguments
    buffer, //   memory that outlives everything. arg: slot and dtype. src[0]: its shape
    alloc, //    memory that lives inside one call, like C's `float a[10]`
    range, //    a loop counter 0, 1, ..., src[0] - 1. arg: its slot (its name)
    end, //      closes the ranges src[1..] around src[0]
    after, //    src[0], once src[1..] have happened
    stack, //    a new leading axis, made of the srcs
    index, //    pops leading axes off src[0], one per index src
    load,
    store, //    writes src[1] into src[0]
    cast,
    recip,
    add,
    mul,
    max,
    xor,
    shl,
    div, //      floor division, like Python's //
    mod, //      floor modulo, like Python's %
    cmplt,
    cmpne,
    where,
    reshape,
    expand,
    permute,
    pad,
    shrink,
    reduce, //   arg: the op (add, mul or max) and how many leading axes to pop
    stage, //    materializes src[0] over the ranges src[1..]
    sink, //     groups its srcs: the root of a graph, or of a kernel
    assert, //   tests only: src[0] must equal src[1]

    fn isAlu(op: Op) bool {
        return switch (op) {
            .cast, .recip, .add, .mul, .max, .xor, .shl, .div, .mod, .cmplt, .cmpne, .where => true,
            else => false,
        };
    }
    fn isMovement(op: Op) bool {
        return switch (op) {
            .reshape, .expand, .permute, .pad, .shrink => true,
            else => false,
        };
    }
};

const Param = struct { slot: u32, dtype: DType };
const Reduce = struct { op: Op, pop: u32 };

const Arg = union(enum) {
    none,
    int: i64, //       a weakint CONST, or a RANGE's slot
    float: f64, //     a weakfloat CONST
    boolean: bool, //  a bool CONST
    dtype: DType, //   a CAST's target
    param: Param, //   PARAM, BUFFER, ALLOC
    reduce: Reduce, // REDUCE
};

const UOp = struct {
    op: Op,
    src: []const *const UOp,
    arg: Arg,
    dtype: DType,
    shape: []const usize,

    /// A CONST's value as an int (a RANGE's end, a shape argument, ...).
    fn intValue(u: *const UOp) ?i64 {
        if (u.op != .constant) return null;
        return switch (u.arg) {
            .int => |v| v,
            else => null,
        };
    }
};

const Error = error{Spec};

/// What makes two UOps "the same": op, srcs (as pointers) and arg.
const Key = struct { op: Op, src: []const *const UOp, arg: Arg };

fn argBits(a: Arg) u64 {
    return switch (a) {
        .none => 0,
        .int => |v| @bitCast(v),
        .float => |v| @bitCast(v), // by bits: -0.0 and 0.0 are different literals
        .boolean => |v| @intFromBool(v),
        .dtype => |d| @intFromEnum(d),
        .param => |p| @as(u64, p.slot) << 8 | @intFromEnum(p.dtype),
        .reduce => |r| @as(u64, r.pop) << 8 | @intFromEnum(r.op),
    };
}

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&k.op));
        h.update(std.mem.sliceAsBytes(k.src));
        h.update(std.mem.asBytes(&@intFromEnum(std.meta.activeTag(k.arg))));
        h.update(std.mem.asBytes(&argBits(k.arg)));
        return h.final();
    }
    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.op == b.op and std.mem.eql(*const UOp, a.src, b.src) and
            std.meta.activeTag(a.arg) == std.meta.activeTag(b.arg) and argBits(a.arg) == argBits(b.arg);
    }
};

const Graph = struct {
    alloc: std.mem.Allocator, // an arena: UOps live as long as their graph
    cache: std.HashMap(Key, *const UOp, KeyContext, 80),
    why: []const u8 = "", //    why the last UOp couldn't be made

    fn init(alloc: std.mem.Allocator) Graph {
        return .{ .alloc = alloc, .cache = .init(alloc) };
    }

    /// The one way to make a UOp: hash-consed, with dtype and shape worked out.
    fn new(g: *Graph, op: Op, src: []const *const UOp, arg: Arg) Error!*const UOp {
        if (g.cache.get(.{ .op = op, .src = src, .arg = arg })) |u| return u;
        const dtype = try dtypeOf(g, op, src, arg);
        const shape = try shapeOf(g, op, src, arg);
        const u = g.alloc.create(UOp) catch @panic("out of memory");
        u.* = .{ .op = op, .src = g.alloc.dupe(*const UOp, src) catch @panic("out of memory"), .arg = arg, .dtype = dtype, .shape = shape };
        g.cache.put(.{ .op = op, .src = u.src, .arg = arg }, u) catch @panic("out of memory");
        return u;
    }

    fn fail(g: *Graph, why: []const u8) Error {
        g.why = why;
        return error.Spec;
    }

    fn cat(g: *Graph, a: []const usize, b: []const usize) []const usize {
        return std.mem.concat(g.alloc, usize, &.{ a, b }) catch @panic("out of memory");
    }

    // ── literals ──
    fn int(g: *Graph, v: i64) *const UOp {
        return g.new(.constant, &.{}, .{ .int = v }) catch unreachable;
    }
    fn float(g: *Graph, v: f64) *const UOp {
        return g.new(.constant, &.{}, .{ .float = v }) catch unreachable;
    }
    fn boolean(g: *Graph, v: bool) *const UOp {
        return g.new(.constant, &.{}, .{ .boolean = v }) catch unreachable;
    }
    /// A list of ints the way tinygrad writes a shape: one int is a CONST,
    /// anything else a STACK of them. (tinygrad: shape_to_shape_arg)
    fn ints(g: *Graph, vs: []const usize) *const UOp {
        if (vs.len == 1) return g.int(@intCast(vs[0]));
        const c = g.alloc.alloc(*const UOp, vs.len) catch @panic("out of memory");
        for (vs, c) |v, *u| u.* = g.int(@intCast(v));
        return g.new(.stack, c, .none) catch unreachable;
    }
    /// Read a shape argument back.
    fn asInts(g: *Graph, u: *const UOp) Error![]const usize {
        if (u.intValue()) |v| {
            const out = g.alloc.alloc(usize, 1) catch @panic("out of memory");
            out[0] = std.math.cast(usize, v) orelse return g.fail("shape arguments can't be negative");
            return out;
        }
        if (u.op != .stack) return g.fail("a shape argument must be a CONST or a STACK of CONSTs");
        const out = g.alloc.alloc(usize, u.src.len) catch @panic("out of memory");
        for (u.src, out) |s, *o| {
            const v = s.intValue() orelse return g.fail("a shape argument must be a CONST or a STACK of CONSTs");
            o.* = std.math.cast(usize, v) orelse return g.fail("shape arguments can't be negative");
        }
        return out;
    }

    // ── memory and loops ──
    fn buffer(g: *Graph, slot: u32, dtype: DType, size: ?usize) *const UOp {
        const shape: []const usize = if (size) |n| &.{n} else &.{};
        return g.new(.buffer, &.{g.ints(shape)}, .{ .param = .{ .slot = slot, .dtype = dtype } }) catch unreachable;
    }
    fn param(g: *Graph, slot: u32, dtype: DType, size: ?usize) *const UOp {
        const shape: []const usize = if (size) |n| &.{n} else &.{};
        return g.new(.param, &.{g.ints(shape)}, .{ .param = .{ .slot = slot, .dtype = dtype } }) catch unreachable;
    }
    fn local(g: *Graph, slot: u32, dtype: DType, size: ?usize) *const UOp {
        const shape: []const usize = if (size) |n| &.{n} else &.{};
        return g.new(.alloc, &.{g.ints(shape)}, .{ .param = .{ .slot = slot, .dtype = dtype } }) catch unreachable;
    }
    fn range(g: *Graph, n: usize, slot: i64) *const UOp {
        return g.new(.range, &.{g.int(@intCast(n))}, .{ .int = slot }) catch unreachable;
    }
    fn index(g: *Graph, x: *const UOp, idx: []const *const UOp) Error!*const UOp {
        return g.new(.index, std.mem.concat(g.alloc, *const UOp, &.{ &.{x}, idx }) catch @panic("out of memory"), .none);
    }
    fn load(g: *Graph, x: *const UOp) Error!*const UOp {
        return g.new(.load, &.{x}, .none);
    }
    fn store(g: *Graph, target: *const UOp, value: *const UOp) Error!*const UOp {
        return g.new(.store, &.{ target, value }, .none);
    }
    fn after(g: *Graph, x: *const UOp, deps: []const *const UOp) Error!*const UOp {
        return g.new(.after, std.mem.concat(g.alloc, *const UOp, &.{ &.{x}, deps }) catch @panic("out of memory"), .none);
    }
    fn end(g: *Graph, x: *const UOp, ranges: []const *const UOp) Error!*const UOp {
        return g.new(.end, std.mem.concat(g.alloc, *const UOp, &.{ &.{x}, ranges }) catch @panic("out of memory"), .none);
    }
    fn stage(g: *Graph, x: *const UOp, ranges: []const *const UOp) Error!*const UOp {
        return g.new(.stage, std.mem.concat(g.alloc, *const UOp, &.{ &.{x}, ranges }) catch @panic("out of memory"), .none);
    }
    fn call(g: *Graph, body: *const UOp, args: []const *const UOp) Error!*const UOp {
        return g.new(.call, std.mem.concat(g.alloc, *const UOp, &.{ &.{body}, args }) catch @panic("out of memory"), .none);
    }
    fn sink(g: *Graph, srcs: []const *const UOp) Error!*const UOp {
        return g.new(.sink, srcs, .none);
    }
    fn assertEq(g: *Graph, a: *const UOp, b: *const UOp) Error!*const UOp {
        return g.new(.assert, &.{ a, b }, .none);
    }

    // ── ALU ──
    fn stack(g: *Graph, srcs: []const *const UOp) Error!*const UOp {
        return g.new(.stack, srcs, .none);
    }
    fn alu(g: *Graph, op: Op, srcs: []const *const UOp) Error!*const UOp {
        return g.new(op, srcs, .none);
    }
    fn add(g: *Graph, a: *const UOp, b: *const UOp) Error!*const UOp {
        return g.new(.add, &.{ a, b }, .none);
    }
    fn mul(g: *Graph, a: *const UOp, b: *const UOp) Error!*const UOp {
        return g.new(.mul, &.{ a, b }, .none);
    }
    fn cmplt(g: *Graph, a: *const UOp, b: *const UOp) Error!*const UOp {
        return g.new(.cmplt, &.{ a, b }, .none);
    }
    fn where(g: *Graph, c: *const UOp, a: *const UOp, b: *const UOp) Error!*const UOp {
        return g.new(.where, &.{ c, a, b }, .none);
    }
    fn cast(g: *Graph, x: *const UOp, dtype: DType) Error!*const UOp {
        return g.new(.cast, &.{x}, .{ .dtype = dtype });
    }

    // ── movement and reduce ──
    fn reshape(g: *Graph, x: *const UOp, shape: []const usize) Error!*const UOp {
        return g.new(.reshape, &.{ x, g.ints(shape) }, .none);
    }
    fn expand(g: *Graph, x: *const UOp, front: []const usize) Error!*const UOp {
        return g.new(.expand, &.{ x, g.ints(front) }, .none);
    }
    fn permute(g: *Graph, x: *const UOp, perm: []const usize) Error!*const UOp {
        return g.new(.permute, &.{ x, g.ints(perm) }, .none);
    }
    fn pad(g: *Graph, x: *const UOp, offsets: []const usize, sizes: []const usize) Error!*const UOp {
        return g.new(.pad, &.{ x, g.ints(offsets), g.ints(sizes) }, .none);
    }
    fn shrink(g: *Graph, x: *const UOp, offsets: []const usize, sizes: []const usize) Error!*const UOp {
        return g.new(.shrink, &.{ x, g.ints(offsets), g.ints(sizes) }, .none);
    }
    fn reduce(g: *Graph, x: *const UOp, op: Op, pop: u32) Error!*const UOp {
        return g.new(.reduce, &.{x}, .{ .reduce = .{ .op = op, .pop = pop } });
    }
};

fn prod(s: []const usize) usize {
    var p: usize = 1;
    for (s) |v| p *= v;
    return p;
}

fn sameShape(a: []const usize, b: []const usize) bool {
    return std.mem.eql(usize, a, b);
}

/// Every UOp that root depends on, and root, with srcs before their users
/// (023). Unless enter_calls, a CALL's body (its src[0]) isn't walked into:
/// the PARAMs in there belong to that call, not to us. (tinygrad: toposort)
fn toposort(g: *Graph, root: *const UOp, enter_calls: bool) []const *const UOp {
    var seen = std.AutoHashMap(*const UOp, void).init(g.alloc);
    var out: std.ArrayList(*const UOp) = .empty;
    visit(g, root, enter_calls, &seen, &out);
    return out.items;
}

fn visit(g: *Graph, u: *const UOp, enter_calls: bool, seen: *std.AutoHashMap(*const UOp, void), out: *std.ArrayList(*const UOp)) void {
    if (seen.contains(u)) return;
    seen.put(u, {}) catch @panic("out of memory");
    for (u.src, 0..) |s, i| {
        if (u.op == .call and i == 0 and !enter_calls) continue;
        visit(g, s, enter_calls, seen, out);
    }
    out.append(g.alloc, u) catch @panic("out of memory");
}

fn shapeOf(g: *Graph, op: Op, src: []const *const UOp, arg: Arg) Error![]const usize {
    switch (op) {
        .constant, .range, .sink, .assert => return &.{},
        .param, .buffer, .alloc => {
            const s = try g.asInts(src[0]);
            if (s.len > 1) return g.fail("buffers are flat: their shape is () or (n,)");
            return s;
        },
        .stack => {
            if (src.len == 0) return &.{};
            for (src[1..]) |s| {
                if (!sameShape(s.shape, src[0].shape)) return g.fail("a STACK's srcs must have the same shape");
            }
            return g.cat(&.{src.len}, src[0].shape);
        },
        .index => {
            const idx = src[1..];
            if (idx.len > src[0].shape.len) return g.fail("INDEX pops more axes than there are");
            var front: []const usize = &.{};
            for (idx) |i| {
                if (!i.dtype.isInt()) return g.fail("indexes must be ints");
                front = g.cat(front, i.shape);
            }
            return g.cat(front, src[0].shape[idx.len..]);
        },
        .add, .mul, .max, .xor, .shl, .div, .mod, .cmplt, .cmpne, .where => {
            for (src[1..]) |s| {
                if (!sameShape(s.shape, src[0].shape)) return g.fail("ALU srcs must have the same shape (EXPAND first)");
            }
            return src[0].shape;
        },
        .cast, .recip, .load, .store, .after, .end, .call => return src[0].shape,
        .reshape => {
            const s = try g.asInts(src[1]);
            if (prod(s) != prod(src[0].shape)) return g.fail("RESHAPE can't change the number of elements");
            return s;
        },
        .expand => return g.cat(try g.asInts(src[1]), src[0].shape),
        .permute => {
            const p = try g.asInts(src[1]);
            const old = src[0].shape;
            if (p.len != old.len) return g.fail("PERMUTE needs one entry per axis");
            const out = g.alloc.alloc(usize, p.len) catch @panic("out of memory");
            for (p, out, 0..) |axis, *o, i| {
                if (axis >= old.len or std.mem.indexOfScalar(usize, p[0..i], axis) != null)
                    return g.fail("PERMUTE needs each axis exactly once");
                o.* = old[axis];
            }
            return out;
        },
        .pad, .shrink => {
            const offsets = try g.asInts(src[1]);
            const sizes = try g.asInts(src[2]);
            const old = src[0].shape;
            if (offsets.len != old.len or sizes.len != old.len) return g.fail("PAD and SHRINK need one offset and size per axis");
            for (old, offsets, sizes) |s, off, size| {
                // PAD puts s elements at off inside size; SHRINK takes size elements from off out of s
                const ok = if (op == .pad) off + s <= size else off + size <= s;
                if (!ok) return g.fail("PAD or SHRINK out of range");
            }
            return sizes;
        },
        .reduce => {
            const pop = arg.reduce.pop;
            if (pop > src[0].shape.len) return g.fail("REDUCE pops more axes than there are");
            return src[0].shape[pop..];
        },
        .stage => {
            var front: []const usize = &.{};
            for (src[1..]) |r| front = g.cat(front, &.{@intCast(r.src[0].intValue().?)});
            return g.cat(front, src[0].shape);
        },
    }
}

fn dtypeOf(g: *Graph, op: Op, src: []const *const UOp, arg: Arg) Error!DType {
    switch (op) {
        .constant => return switch (arg) {
            .int => .weakint,
            .float => .weakfloat,
            .boolean => .bool,
            else => unreachable,
        },
        .param, .buffer, .alloc => return arg.param.dtype,
        .range => return .weakint,
        .cast => return arg.dtype,
        .cmplt, .cmpne => return .bool,
        .where => {
            if (src[0].dtype != .bool) return g.fail("WHERE's condition must be a bool");
            return lub(src[1].dtype, src[2].dtype);
        },
        .shl, .div, .mod => {
            if (!src[0].dtype.isInt() or !src[1].dtype.isInt()) return g.fail("SHL, DIV and MOD are for ints");
            return lub(src[0].dtype, src[1].dtype);
        },
        .xor => {
            if (src[0].dtype.isFloat() or src[1].dtype.isFloat()) return g.fail("XOR is for ints and bools");
            return lub(src[0].dtype, src[1].dtype);
        },
        .add, .mul, .max => return lub(src[0].dtype, src[1].dtype),
        .recip => return leastUpperFloat(src[0].dtype),
        .stack => {
            if (src.len == 0) return .void;
            var d = src[0].dtype;
            for (src[1..]) |x| d = lub(d, x.dtype);
            return d;
        },
        .store, .sink, .assert => return .void,
        .index, .load, .after, .end, .call, .reshape, .expand, .permute, .pad, .shrink, .reduce, .stage => return src[0].dtype,
    }
}

const TokenKind = enum { assign, key, ref, lparen, rparen, lbracket, rbracket, lbrace, rbrace, word };
const Token = struct { kind: TokenKind, text: []const u8 };

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Split UIR text into tokens. Comments are dropped.
fn tokenize(alloc: std.mem.Allocator, text: []const u8) []const Token {
    var out: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (c == '#') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        if (std.mem.indexOfScalar(u8, "()[]{}", c)) |k| {
            const kinds = [_]TokenKind{ .lparen, .rparen, .lbracket, .rbracket, .lbrace, .rbrace };
            out.append(alloc, .{ .kind = kinds[k], .text = text[i .. i + 1] }) catch @panic("out of memory");
            i += 1;
            continue;
        }
        var j = i + 1;
        if (c == '%') {
            while (j < text.len and isWordChar(text[j])) j += 1;
            // "%x =" defines x (spaces before the = are fine); "%x" uses it
            var k = j;
            while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
            if (k < text.len and text[k] == '=') {
                out.append(alloc, .{ .kind = .assign, .text = text[i..j] }) catch @panic("out of memory");
                i = k + 1;
            } else {
                out.append(alloc, .{ .kind = .ref, .text = text[i..j] }) catch @panic("out of memory");
                i = j;
            }
            continue;
        }
        if (isWordChar(c)) {
            while (j < text.len and isWordChar(text[j])) j += 1;
            // "slot=0" is the key "slot", then the word "0"
            if (j < text.len and text[j] == '=') {
                out.append(alloc, .{ .kind = .key, .text = text[i..j] }) catch @panic("out of memory");
                i = j + 1;
                continue;
            }
        }
        // any other word: up to a space, a bracket or a comment (-inf, 1.5e+3, ...)
        while (j < text.len and !std.ascii.isWhitespace(text[j]) and std.mem.indexOfScalar(u8, "()[]{}#", text[j]) == null) j += 1;
        out.append(alloc, .{ .kind = .word, .text = text[i..j] }) catch @panic("out of memory");
        i = j;
    }
    return out.items;
}

/// A literal, or null if `text` isn't one. (tinygrad: _lit)
fn literal(g: *Graph, text: []const u8) ?*const UOp {
    if (std.mem.eql(u8, text, "true")) return g.boolean(true);
    if (std.mem.eql(u8, text, "false")) return g.boolean(false);
    if (std.mem.eql(u8, text, "inf")) return g.float(std.math.inf(f64));
    if (std.mem.eql(u8, text, "-inf")) return g.float(-std.math.inf(f64));
    if (std.mem.eql(u8, text, "nan")) return g.float(std.math.nan(f64));
    if (std.mem.startsWith(u8, text, "0x")) {
        return g.int(std.fmt.parseInt(i64, text[2..], 16) catch return null);
    }
    if (std.fmt.parseInt(i64, text, 10)) |v| return g.int(v) else |_| {}
    const digits_first = text.len > 0 and (std.ascii.isDigit(text[0]) or (text[0] == '-' and text.len > 1 and std.ascii.isDigit(text[1])));
    if (!digits_first) return null;
    return g.float(std.fmt.parseFloat(f64, text) catch return null);
}

/// key=value args. tinygrad has more (name, addrspace, device, ...).
const Args = struct { slot: ?i64 = null, dtype: ?DType = null, op: ?Op = null, pop: ?i64 = null };

const Names = std.StringHashMap(?*const UOp);

const Parser = struct {
    g: *Graph,
    toks: []const Token,
    pos: usize = 0,
    lines: std.ArrayList(*const UOp) = .empty, // the top-level values, in order

    fn peek(p: *Parser) ?Token {
        return if (p.pos < p.toks.len) p.toks[p.pos] else null;
    }
    fn next(p: *Parser, what: []const u8) Error!Token {
        const tok = p.peek() orelse return p.g.fail(what);
        p.pos += 1;
        return tok;
    }
    /// The end of one value's srcs and args.
    fn atEnd(p: *Parser) bool {
        const tok = p.peek() orelse return true;
        return switch (tok.kind) {
            .rparen, .rbracket, .rbrace, .assign => true,
            else => false,
        };
    }

    /// `%name = value` lines, up to `close` or the end of the input. Its
    /// value is the last line's.
    fn scope(p: *Parser, names: *Names, close: ?TokenKind) Error!*const UOp {
        var last: ?*const UOp = null;
        while (p.peek()) |tok| {
            if (close != null and tok.kind == close.?) break;
            if (tok.kind != .assign) return p.g.fail("expected '%name ='");
            p.pos += 1;
            if (names.contains(tok.text)) return p.g.fail("a name can only be defined once");
            names.put(tok.text, null) catch @panic("out of memory"); // can't be used in its own value
            const v = try p.value(names, true);
            names.put(tok.text, v) catch @panic("out of memory");
            last = v;
            if (close == null) p.lines.append(p.g.alloc, v) catch @panic("out of memory");
        }
        if (close) |c| {
            const tok = try p.next("expected '}'");
            if (tok.kind != c) return p.g.fail("expected '}'");
        } else if (p.peek() != null) return p.g.fail("unexpected closing bracket");
        return last orelse p.g.fail("expected an assignment");
    }

    /// One value. Right after a `=` (bare), it can be an op without parentheses.
    fn value(p: *Parser, names: *Names, bare: bool) Error!*const UOp {
        const tok = try p.next("expected a value");
        switch (tok.kind) {
            .lbrace => {
                var inner = names.clone() catch @panic("out of memory");
                return p.scope(&inner, .rbrace);
            },
            .lparen => {
                const op = try p.next("expected an op");
                if (op.kind != .word) return p.g.fail("expected an op");
                return p.expr(names, op.text, .rparen);
            },
            .lbracket => {
                var srcs: std.ArrayList(*const UOp) = .empty;
                while (p.peek()) |next_tok| {
                    if (next_tok.kind == .rbracket) break;
                    srcs.append(p.g.alloc, try p.value(names, false)) catch @panic("out of memory");
                }
                const close = try p.next("expected ']'");
                if (close.kind != .rbracket) return p.g.fail("expected ']'");
                return p.g.stack(srcs.items);
            },
            .ref => {
                const v = names.get(tok.text) orelse return p.g.fail("that %name is not defined");
                return v orelse p.g.fail("that %name is not defined yet");
            },
            .word => {
                if (literal(p.g, tok.text)) |lit| return lit;
                if (bare) return p.expr(names, tok.text, null);
                if (std.meta.stringToEnum(Op, tok.text) != null) return p.g.fail("an op inside a line needs parentheses: (op ...)");
                return p.g.fail("not a %name or a literal");
            },
            else => return p.g.fail("expected a value"),
        }
    }

    /// `op srcs key=value`, ended by `close` (or by the end of the line).
    fn expr(p: *Parser, names: *Names, name: []const u8, close: ?TokenKind) Error!*const UOp {
        const op = std.meta.stringToEnum(Op, name) orelse return p.g.fail("unknown op");
        if (op == .constant) return p.g.fail("write a literal instead");
        var srcs: std.ArrayList(*const UOp) = .empty;
        while (!p.atEnd() and p.peek().?.kind != .key) {
            srcs.append(p.g.alloc, try p.value(names, false)) catch @panic("out of memory");
        }
        var args: Args = .{};
        while (!p.atEnd()) {
            const key = try p.next("expected key=");
            if (key.kind != .key) return p.g.fail("srcs must come before key=value args");
            const v = try p.next("expected a value after key=");
            try p.setArg(&args, key.text, v.text);
        }
        if (close) |c| {
            const tok = try p.next("expected ')'");
            if (tok.kind != c) return p.g.fail("expected ')'");
        }
        return p.build(op, srcs.items, args);
    }

    fn setArg(p: *Parser, args: *Args, key: []const u8, v: []const u8) Error!void {
        if (std.mem.eql(u8, key, "slot") or std.mem.eql(u8, key, "pop")) {
            const n = std.fmt.parseInt(i64, v, 10) catch return p.g.fail("expected an int");
            const field = if (key[0] == 's') &args.slot else &args.pop;
            if (field.* != null) return p.g.fail("an arg was given twice");
            field.* = n;
        } else if (std.mem.eql(u8, key, "dtype")) {
            if (args.dtype != null) return p.g.fail("an arg was given twice");
            args.dtype = std.meta.stringToEnum(DType, v) orelse return p.g.fail("unknown dtype");
        } else if (std.mem.eql(u8, key, "op")) {
            if (args.op != null) return p.g.fail("an arg was given twice");
            args.op = std.meta.stringToEnum(Op, v) orelse return p.g.fail("unknown op");
        } else return p.g.fail("unknown arg");
    }

    fn build(p: *Parser, op: Op, srcs: []const *const UOp, args: Args) Error!*const UOp {
        const g = p.g;
        const arg: Arg = switch (op) {
            .buffer, .param, .alloc => blk: {
                if (srcs.len != 1) return g.fail("a buffer has one src: its shape");
                const slot = args.slot orelse return g.fail("a buffer needs slot=");
                const dtype = args.dtype orelse return g.fail("a buffer needs dtype=");
                if (args.op != null or args.pop != null) return g.fail("unknown arg");
                break :blk .{ .param = .{ .slot = @intCast(slot), .dtype = dtype } };
            },
            .range => blk: {
                const slot = args.slot orelse return g.fail("a range needs slot=");
                if (args.dtype != null or args.op != null or args.pop != null) return g.fail("unknown arg");
                break :blk .{ .int = slot };
            },
            .reduce => blk: {
                const rop = args.op orelse return g.fail("a reduce needs op=");
                if (args.slot != null or args.dtype != null) return g.fail("unknown arg");
                break :blk .{ .reduce = .{ .op = rop, .pop = @intCast(args.pop orelse 0) } };
            },
            .cast => blk: {
                const dtype = args.dtype orelse return g.fail("a cast needs dtype=");
                if (args.slot != null or args.op != null or args.pop != null) return g.fail("unknown arg");
                break :blk .{ .dtype = dtype };
            },
            else => blk: {
                if (args.slot != null or args.dtype != null or args.op != null or args.pop != null) return g.fail("unknown arg");
                break :blk .none;
            },
        };
        return g.new(op, srcs, arg);
    }
};

/// A whole program: its value is the last line's.
fn parseUir(g: *Graph, text: []const u8) Error!*const UOp {
    var p: Parser = .{ .g = g, .toks = tokenize(g.alloc, text) };
    var names = Names.init(g.alloc);
    return p.scope(&names, null);
}

/// Every top-level line's value, in order (to run all of a file's asserts).
fn parseLines(g: *Graph, text: []const u8) Error![]const *const UOp {
    var p: Parser = .{ .g = g, .toks = tokenize(g.alloc, text) };
    var names = Names.init(g.alloc);
    _ = try p.scope(&names, null);
    return p.lines.items;
}
