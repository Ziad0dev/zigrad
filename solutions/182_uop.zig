// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 182: the UOp ────────────────────────────────────────────
//
// Everything in tinygrad, from a whole network down to one add in one
// kernel, is a graph of UOps (tinygrad/uop/ops.py), and 10-411's spec
// starts from the same line:
//
//     UOp(op, src: tuple[UOp, ...], arg)
//
// Three ideas make it work.
//
// 1. Hash-consing (024): making a UOp with an op, srcs and arg that
//    already exist gives back the SAME object. "Is this the same graph?"
//    is a pointer compare, and a rewrite that changes nothing is free.
//
// 2. Recursive properties: dtype and shape are never set by hand. They're
//    computed from the srcs when a UOp is made (tinygrad's
//    @recursive_property). An op whose srcs don't fit fails right there,
//    not three passes later.
//
// 3. Shapes act at the FRONT. Several ops add or remove LEADING axes:
//
//     STACK(a, b, c)       a new leading axis    (3,) ++ a.shape
//     INDEX(x, i, j)       pops 2 leading axes   x.shape[2..]
//     EXPAND(x, [4 5])     new leading axes      (4, 5) ++ x.shape
//     REDUCE(x, pop=1)     reduces the leading axis away: x.shape[1..]
//
//    To sum axis 2, PERMUTE it to the front first; that's what tinygrad's
//    _rop does for Tensor.sum(axis=2). EXPAND is no longer "stretch a
//    size-1 axis" as in 012: it ADDS axes. (An INDEX whose indexes are
//    themselves tensors gathers: their shapes come first, then the rest
//    of x's. Scalar indexes have shape (), so they just pop.)
//
// Movement ops take their shape arguments as srcs, a CONST or a STACK of
// CONSTs, exactly like tinygrad today: RESHAPE(x, [2 2]) has two srcs, x
// and the STACK [2 2]. PAD and SHRINK take two: offsets and sizes, one
// per axis. PAD puts x at `offset` inside a new axis of `size`; SHRINK
// takes `size` elements starting at `offset`.
//
// Buffers are flat: a BUFFER's shape is () or (n,). More axes come from a
// RESHAPE of one.
//
// ALU ops need equal shapes. (tinygrad itself also accepts numpy-style
// broadcasting unless DISALLOW_BROADCAST=1. 10-411 makes you write the
// EXPAND, so we do too.) Their dtype is the least upper bound of their
// srcs' (181), except that comparisons give bool.
//
// YOUR TASK: finish shapeOf() and dtypeOf(). The UOp struct, the
// constructors and the hash-consing are done.
//
const std = @import("std");

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
        try g.checkSrcs(op, src);
        const dtype = try dtypeOf(g, op, src, arg);
        const shape = try shapeOf(g, op, src, arg);
        const u = g.alloc.create(UOp) catch @panic("out of memory");
        u.* = .{ .op = op, .src = g.alloc.dupe(*const UOp, src) catch @panic("out of memory"), .arg = arg, .dtype = dtype, .shape = shape };
        g.cache.put(.{ .op = op, .src = u.src, .arg = arg }, u) catch @panic("out of memory");
        return u;
    }

    /// The right number of srcs, and no void where a value is needed.
    fn checkSrcs(g: *Graph, op: Op, src: []const *const UOp) Error!void {
        const ok = switch (op) {
            .constant => src.len == 0,
            .param, .buffer, .alloc, .range, .cast, .recip, .load => src.len == 1,
            .add, .mul, .max, .xor, .shl, .div, .mod, .cmplt, .cmpne, .store, .assert, .reshape, .expand, .permute => src.len == 2,
            .where, .pad, .shrink => src.len == 3,
            .index, .after, .end, .stage, .call, .reduce => src.len >= 1,
            .stack, .sink => true,
        };
        if (!ok) return g.fail("wrong number of srcs for this op");
        if (op == .range and (src[0].intValue() orelse -1) < 0) return g.fail("a RANGE's end must be an int literal");
        if (op.isAlu() or (op == .stack and src.len > 0)) {
            for (src) |s| if (s.dtype == .void) return g.fail("a void value can't be used here");
        }
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
            if (arg.reduce.op != .add and arg.reduce.op != .mul and arg.reduce.op != .max) return g.fail("REDUCE's op must be add, mul or max");
            const pop = arg.reduce.pop;
            if (pop > src[0].shape.len) return g.fail("REDUCE pops more axes than there are");
            return src[0].shape[pop..];
        },
        .stage => {
            for (src[1..]) |r| if (r.op != .range) return g.fail("STAGE's axes are RANGEs");
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

const t = std.testing;

fn expectShape(expected: []const usize, u: *const UOp) !void {
    try t.expectEqualSlices(usize, expected, u.shape);
}

test "hash-consing: the same UOp is the same object" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .f32, null); // a scalar, so it can meet a literal
    try t.expect(try g.add(x, g.float(1)) == try g.add(x, g.float(1)));
    try t.expect(try g.add(x, g.float(1)) != try g.add(x, g.float(2)));
    try t.expect(g.int(1) != g.float(1)); // 1 and 1.0 are different literals
    try t.expect(g.buffer(0, .f32, 4) != g.buffer(1, .f32, 4)); // different slots
}

test "10-411's examples, weeks 1 to 5" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    // week 1: add 2 3
    try expectShape(&.{}, try g.add(g.int(2), g.int(3)));
    // week 2: buffer [] is a scalar, buffer 3 has 3 elements
    try expectShape(&.{}, g.buffer(0, .i32, null));
    try expectShape(&.{3}, g.buffer(0, .i32, 3));
    // week 4: add [1 2 3] (expand 1 3), then reduce op=add pop=1
    const values = try g.add(g.ints(&.{ 1, 2, 3 }), try g.expand(g.int(1), &.{3}));
    try expectShape(&.{3}, values);
    try expectShape(&.{}, try g.reduce(values, .add, 1));
    // week 5: reshape [1 2 3 4] [2 2], permute [1 0], index 1 0
    const m = try g.reshape(g.ints(&.{ 1, 2, 3, 4 }), &.{ 2, 2 });
    const tr = try g.permute(m, &.{ 1, 0 });
    try expectShape(&.{ 2, 2 }, tr);
    try expectShape(&.{}, try g.index(tr, &.{ g.int(1), g.int(0) }));
}

test "the gist's matmul: reshape, reshape, mul, reduce" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const a = try g.reshape(g.buffer(0, .f32, 65536), &.{ 256, 256, 1 });
    const b = try g.reshape(g.buffer(1, .f32, 65536), &.{ 256, 1, 256 });
    // the 1s don't broadcast by themselves: EXPAND them first
    try t.expectError(error.Spec, g.mul(a, b));
    const a3 = try g.permute(try g.expand(try g.reshape(a, &.{ 256, 256 }), &.{256}), &.{ 1, 2, 0 });
    const b3 = try g.permute(try g.expand(try g.reshape(b, &.{ 256, 256 }), &.{256}), &.{ 1, 0, 2 });
    try expectShape(&.{ 256, 256, 256 }, a3);
    try expectShape(&.{ 256, 256, 256 }, b3);
    try expectShape(&.{ 256, 256 }, try g.reduce(try g.mul(a3, b3), .add, 1));
}

test "more shapes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = try g.reshape(g.buffer(0, .f32, 60), &.{ 3, 4, 5 });
    try expectShape(&.{ 2, 3, 4, 5 }, try g.stack(&.{ x, x }));
    try expectShape(&.{ 1, 3, 4, 5 }, try g.stack(&.{x}));
    try expectShape(&.{5}, try g.index(x, &.{ g.int(0), g.int(1) }));
    try expectShape(&.{ 6, 7, 3, 4, 5 }, try g.expand(x, &.{ 6, 7 }));
    try expectShape(&.{ 5, 3, 4 }, try g.permute(x, &.{ 2, 0, 1 }));
    try expectShape(&.{5}, try g.reduce(x, .max, 2));
    try expectShape(&.{ 3, 6, 5 }, try g.pad(x, &.{ 0, 1, 0 }, &.{ 3, 6, 5 }));
    try expectShape(&.{ 2, 4, 1 }, try g.shrink(x, &.{ 1, 0, 4 }, &.{ 2, 4, 1 }));
    // an index that is itself a tensor gathers: its shape comes first
    const which = g.ints(&.{ 2, 0, 2, 1 });
    try expectShape(&.{ 4, 4, 5 }, try g.index(x, &.{which}));
}

test "dtypes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const i = try g.cast(g.int(7), .i32);
    try t.expectEqual(.i32, (try g.add(i, g.int(1))).dtype);
    try t.expectEqual(.weakint, (try g.add(g.int(2), g.int(3))).dtype);
    try t.expectEqual(.weakfloat, (try g.add(i, g.float(0.5))).dtype);
    try t.expectEqual(.bool, (try g.cmplt(i, g.int(3))).dtype);
    try t.expectEqual(.weakfloat, (try g.where(g.boolean(true), g.int(1), g.float(2.5))).dtype);
    try t.expectEqual(.weakfloat, (try g.where(g.boolean(true), g.float(2.5), g.int(1))).dtype);
    try t.expectEqual(.weakfloat, (try g.alu(.recip, &.{g.int(4)})).dtype);
    try t.expectEqual(.f32, (try g.alu(.recip, &.{i})).dtype);
    try t.expectEqual(.weakint, g.range(10, 0).dtype);
    try t.expectEqual(.void, (try g.store(g.buffer(0, .i32, null), g.int(7))).dtype);
}

test "what the spec rejects" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = try g.reshape(g.buffer(0, .f32, 6), &.{ 2, 3 });
    try t.expectError(error.Spec, g.add(x, g.ints(&.{ 1, 2, 3 }))); // (2, 3) + (3,)
    try t.expectError(error.Spec, g.permute(x, &.{ 0, 0 }));
    try t.expectError(error.Spec, g.reduce(x, .add, 3));
    try t.expectError(error.Spec, g.reduce(x, .xor, 1)); // only add, mul and max reduce
    try t.expectError(error.Spec, g.stage(x, &.{g.int(2)})); // a STAGE's axes are RANGEs
    try t.expectError(error.Spec, g.reshape(x, &.{ 4, 2 }));
    try t.expectError(error.Spec, g.index(x, &.{ g.int(0), g.int(0), g.int(0) }));
    try t.expectError(error.Spec, g.index(x, &.{g.float(1)}));
    try t.expectError(error.Spec, g.where(g.int(1), g.int(2), g.int(3)));
    try t.expectError(error.Spec, g.alu(.div, &.{ g.float(1), g.int(2) }));
    try t.expectError(error.Spec, g.new(.buffer, &.{g.ints(&.{ 2, 3 })}, .{ .param = .{ .slot = 0, .dtype = .f32 } }));
    try t.expectEqualStrings("buffers are flat: their shape is () or (n,)", g.why);
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
