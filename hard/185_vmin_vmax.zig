// HARD MODE (zig build -Dhard): no blanks to fill in. Every function
// marked ??? has lost its whole body: write it, from its doc comment,
// its signature and the tests. The gentler version of this file is in
// exercises/, and the answer in solutions/.
//
// ─── Exercise 185: what values can this be? ───────────────────────────
//
// 071 bounded index expressions with intervals. tinygrad keeps the same
// thing on every UOp, as u.vmin and u.vmax (_min_max in
// tinygrad/uop/ops.py), and leans on it everywhere:
//
//   * A RANGE with end n is in [0, n - 1]. Everything starts there.
//   * Simplification: x < n is true for sure when x's vmax < n's vmin, so
//     a bounds check the compiler can prove simply disappears. A padded
//     read, WHERE(valid, load, 0), loses its WHERE wherever valid is
//     always true (pm_simplify_valid in tinygrad/uop/symbolic.py).
//   * 10-411's week 2: "loads and stores are bounds checked to never be out
//     of range". With vmin and vmax, that check happens at compile time:
//     every INDEX into a buffer of n elements must have an index in
//     [0, n - 1] for every value its RANGEs can take.
//
// The rules, for ints (a float is anything, [-inf, inf], here):
//
//     CONST c           [c, c]
//     RANGE to n        [0, n - 1]
//     ADD               [a.lo + b.lo, a.hi + b.hi]
//     MUL               the smallest and largest corner product (071)
//     DIV by c > 0      [a.lo DIV c, a.hi DIV c]     (floor division, 183)
//     MOD by c > 0      a, if a already fits in [0, c - 1]; else [0, c - 1]
//     MAX               [max(a.lo, b.lo), max(a.hi, b.hi)]
//     WHERE(c, a, b)    anything a or b can be
//     CMPLT a < b       [1, 1]  if a.hi < b.lo        always true
//                       [0, 0]  if a.lo >= b.hi       never
//                       [0, 1]  otherwise
//
// (bools are 0 and 1.) tinygrad's rules go further: an AND of two
// comparisons, a MOD of a negative number, ... but these do most of the work.
//
// YOUR TASK: RANGE, WHERE and CMPLT in bounds(), then the check in
// checkIndexes().
//
const std = @import("std");

fn constValue(u: *const UOp) f64 {
    return switch (u.arg) {
        .int => |v| @floatFromInt(v),
        .float => |v| v,
        .boolean => |v| if (v) 1 else 0,
        else => unreachable,
    };
}

/// The smallest and largest value u can ever have. (tinygrad: vmin, vmax)
fn bounds(u: *const UOp) [2]f64 {
    const anything = [2]f64{ -std.math.inf(f64), std.math.inf(f64) };
    switch (u.op) {
        .constant => {
            const v = constValue(u);
            return .{ v, v };
        },
        .range => return ???,
        .add => {
            const a = bounds(u.src[0]);
            const b = bounds(u.src[1]);
            return .{ a[0] + b[0], a[1] + b[1] };
        },
        .mul => {
            const a = bounds(u.src[0]);
            const b = bounds(u.src[1]);
            const p = [_]f64{ a[0] * b[0], a[0] * b[1], a[1] * b[0], a[1] * b[1] };
            return .{ @min(@min(p[0], p[1]), @min(p[2], p[3])), @max(@max(p[0], p[1]), @max(p[2], p[3])) };
        },
        .div, .mod => {
            const a = bounds(u.src[0]);
            const c = u.src[1].intValue() orelse return anything;
            if (c <= 0) return anything;
            const cf: f64 = @floatFromInt(c);
            if (u.op == .div) return .{ @floor(a[0] / cf), @floor(a[1] / cf) };
            if (a[0] >= 0 and a[1] < cf) return a;
            return .{ 0, cf - 1 };
        },
        .max => {
            const a = bounds(u.src[0]);
            const b = bounds(u.src[1]);
            return .{ @max(a[0], b[0]), @max(a[1], b[1]) };
        },
        .where => {
            const a = bounds(u.src[1]);
            const b = bounds(u.src[2]);
            return ???;
        },
        .cmplt => {
            const a = bounds(u.src[0]);
            const b = bounds(u.src[1]);
            if (???) return .{ 1, 1 }; // always true
            if (???) return .{ 0, 0 }; // never true
            return .{ 0, 1 };
        },
        .cast => return if (u.dtype == .bool) .{ 0, 1 } else bounds(u.src[0]),
        else => return if (u.dtype == .bool) .{ 0, 1 } else anything,
    }
}

/// The buffer an INDEX reads or writes, if it's one: BUFFER, PARAM or
/// ALLOC, possibly behind AFTERs.
fn memoryOf(u: *const UOp) ?*const UOp {
    var m = u;
    while (m.op == .after) m = m.src[0];
    return switch (m.op) {
        .buffer, .param, .alloc => m,
        else => null,
    };
}

/// 10-411's week 2 rule, checked at compile time: every INDEX into a
/// buffer stays inside it, for every value its RANGEs can take.
fn checkIndexes(g: *Graph, root: *const UOp) Error!void {
    ???; // write this function's body
}

/// Fold what bounds() can prove: a CMPLT that's always true or always
/// false becomes a CONST, and a WHERE on a CONST picks its side.
fn foldKnown(g: *Graph, root: *const UOp) Error!*const UOp {
    var done = Subst.init(g.alloc);
    for (toposort(g, root, false)) |u| {
        const src = g.alloc.alloc(*const UOp, u.src.len) catch @panic("out of memory");
        for (u.src, src) |s, *n| n.* = done.get(s) orelse s;
        var out = try g.new(u.op, src, u.arg);
        if (out.op == .cmplt) {
            const b = bounds(out);
            if (b[0] == b[1]) out = g.boolean(b[0] == 1);
        }
        if (out.op == .where and out.src[0].op == .constant) out = if (constValue(out.src[0]) == 1) out.src[1] else out.src[2];
        done.put(u, out) catch @panic("out of memory");
    }
    return done.get(root).?;
}

const t = std.testing;

fn expectBounds(lo: f64, hi: f64, u: *const UOp) !void {
    const b = bounds(u);
    try t.expectEqual(lo, b[0]);
    try t.expectEqual(hi, b[1]);
}

test "bounds of index maths" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const r = g.range(4, 0);
    const c = g.range(4, 1);
    try expectBounds(0, 3, r);
    const flat = try g.add(try g.mul(r, g.int(4)), c); // r * 4 + c
    try expectBounds(0, 15, flat);
    try expectBounds(0, 3, try g.alu(.div, &.{ flat, g.int(4) }));
    try expectBounds(0, 3, try g.alu(.mod, &.{ flat, g.int(4) }));
    try expectBounds(0, 3, try g.alu(.mod, &.{ r, g.int(8) })); // already fits
    try expectBounds(2, 3, try g.alu(.max, &.{ r, g.int(2) }));
    try expectBounds(-3, 0, try g.mul(r, g.int(-1)));
}

test "where and comparisons" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const r = g.range(4, 0); // 0..3
    try expectBounds(0, 10, try g.where(try g.cmplt(r, g.int(2)), r, g.int(10)));
    try expectBounds(-5, 3, try g.where(try g.cmplt(r, g.int(2)), r, g.int(-5)));
    const r2 = g.range(4, 1); // 0..3 too
    try expectBounds(0, 13, try g.where(try g.cmplt(r, g.int(2)), try g.add(r, g.int(10)), r2));
    try expectBounds(0, 13, try g.where(try g.cmplt(r, g.int(2)), r, try g.add(r2, g.int(10))));
    try expectBounds(1, 1, try g.cmplt(r, g.int(4))); //          3 < 4: always
    try expectBounds(0, 1, try g.cmplt(r, g.int(3))); //          sometimes
    try expectBounds(0, 0, try g.cmplt(try g.add(r, g.int(3)), g.int(3))); // 3..6 < 3: never
    try expectBounds(0, 0, try g.cmplt(r, g.int(0))); //          never below 0
    try expectBounds(0, 1, try g.cmplt(r, r)); //                 only the ranges are compared
    try expectBounds(1, 1, try g.cmplt(r, try g.add(r2, g.int(4)))); //  0..3 < 4..7: always
    try expectBounds(0, 1, try g.cmplt(r, try g.add(r2, g.int(2)))); //  0..3 < 2..5: sometimes
}

test "10-411 week 3: the store stays inside the buffer" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const buf = g.buffer(0, .i32, 3);
    const i = g.range(3, 0);
    const ok = try g.end(try g.store(try g.index(buf, &.{i}), i), &.{i});
    try checkIndexes(&g, ok);
    // a range one too long writes past the end
    const j = g.range(4, 1);
    const bad = try g.end(try g.store(try g.index(buf, &.{j}), j), &.{j});
    try t.expectError(error.Spec, checkIndexes(&g, bad));
    // r * 2 + 1 for r in 0..3 reaches 7: fine for 8 elements, not for 7
    const r = g.range(4, 2);
    const odd = try g.add(try g.mul(r, g.int(2)), g.int(1));
    try checkIndexes(&g, try g.load(try g.index(g.buffer(1, .f32, 8), &.{odd})));
    try t.expectError(error.Spec, checkIndexes(&g, try g.load(try g.index(g.buffer(2, .f32, 7), &.{odd}))));
    // and r - 1 reaches -1
    try t.expectError(error.Spec, checkIndexes(&g, try g.load(try g.index(g.buffer(1, .f32, 8), &.{try g.add(r, g.int(-1))}))));
}

test "a check the compiler can prove disappears" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .weakint, 10);
    const r = g.range(10, 0);
    const read = try g.index(x, &.{r});
    // WHERE(r < 10, x[r], 0): r is at most 9, so it's just x[r]
    try t.expect(try foldKnown(&g, try g.where(try g.cmplt(r, g.int(10)), read, g.int(0))) == read);
    // WHERE(r < 5, x[r], 0) stays
    const half = try g.where(try g.cmplt(r, g.int(5)), read, g.int(0));
    try t.expect(try foldKnown(&g, half) == half);
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

/// Python's //, and 0 for a zero divisor. (tinygrad.helpers.floordiv)
fn floorDiv(x: i64, y: i64) i64 {
    if (y == 0) return 0;
    return @divFloor(x, y);
}

/// Python's %, defined from floorDiv. (tinygrad.helpers.floormod)
fn floorMod(x: i64, y: i64) i64 {
    return x - floorDiv(x, y) * y;
}

/// Keep the low 32 bits, read as a signed number, like ctypes.c_int32.
fn wrapI32(x: i64) i64 {
    return @as(i32, @truncate(x));
}

fn toInt(x: f64) i64 {
    return @intFromFloat(@trunc(x));
}

fn fromInt(x: i64) f64 {
    return @floatFromInt(x);
}

fn fromBool(b: bool) f64 {
    return if (b) 1 else 0;
}

/// Make a freshly computed value fit its dtype.
fn fit(dtype: DType, x: f64) f64 {
    return switch (dtype) {
        .i32 => fromInt(wrapI32(toInt(x))),
        .f32 => @as(f32, @floatCast(x)),
        .bool => fromBool(x != 0),
        else => x, // weak types and void: as is
    };
}

/// One ALU op on scalars. `dtype` is the dtype of the result (182).
fn execAlu(op: Op, dtype: DType, s: []const f64) f64 {
    // ints (and bools) are computed exactly in i64, floats in f64
    const int_math = dtype.isInt() or dtype == .bool;
    const r: f64 = switch (op) {
        .add => if (int_math) fromInt(toInt(s[0]) +% toInt(s[1])) else s[0] + s[1],
        .mul => if (int_math) fromInt(toInt(s[0]) *% toInt(s[1])) else s[0] * s[1],
        .max => @max(s[0], s[1]),
        .xor => fromInt(toInt(s[0]) ^ toInt(s[1])),
        .shl => fromInt(std.math.shl(i64, toInt(s[0]), toInt(s[1]))),
        .div => fromInt(floorDiv(toInt(s[0]), toInt(s[1]))),
        .mod => fromInt(floorMod(toInt(s[0]), toInt(s[1]))),
        .cmplt => fromBool(s[0] < s[1]),
        .cmpne => fromBool(s[0] != s[1]),
        .where => if (s[0] != 0) s[1] else s[2],
        .recip => 1 / s[0], // IEEE: 1/0 is inf, 1/-0.0 is -inf
        else => unreachable,
    };
    return fit(dtype, r);
}

/// CAST x (of any dtype) to `to`.
fn castValue(x: f64, to: DType) f64 {
    return switch (to) {
        .i32, .weakint => fit(to, @trunc(x)),
        else => fit(to, x),
    };
}

const Subst = std.AutoHashMap(*const UOp, *const UOp);

/// `root`, with every key of `map` replaced by its value. `map` also
/// remembers every node done so far, so shared nodes are rebuilt once.
fn substitute(g: *Graph, root: *const UOp, map: *Subst) Error!*const UOp {
    if (map.get(root)) |done| return done;
    const src = g.alloc.alloc(*const UOp, root.src.len) catch @panic("out of memory");
    var changed = false;
    for (root.src, src, 0..) |s, *n, i| {
        if (root.op == .call and i == 0) {
            n.* = s; // a CALL's body has its own PARAMs: leave it alone
            continue;
        }
        n.* = try substitute(g, s, map);
        if (n.* != s) changed = true;
    }
    const out = if (changed) try g.new(root.op, src, root.arg) else root;
    map.put(root, out) catch @panic("out of memory");
    return out;
}

/// Beta reduction: the CALL's body with each PARAM replaced by its argument.
fn inlineCall(g: *Graph, c: *const UOp) Error!*const UOp {
    std.debug.assert(c.op == .call);
    const body = c.src[0];
    const args = c.src[1..];
    var map = Subst.init(g.alloc);
    for (toposort(g, body, false)) |u| {
        if (u.op != .param) continue;
        const slot = u.arg.param.slot;
        if (slot >= args.len) return g.fail("a PARAM's slot has no argument");
        map.put(u, args[slot]) catch @panic("out of memory");
    }
    return substitute(g, body, &map);
}
