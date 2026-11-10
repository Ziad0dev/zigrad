// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 189: running UIR: movement ops and REDUCE ───────────────
//
// Weeks 4 and 5 of 10-411 add the tensor-shaped ops, and with them you
// can write any model: matmuls and convolutions are movement ops plus a
// multiply and a REDUCE (019, 020), the leading-axis way (182):
//
//   EXPAND(x, [a b])        new leading axes: x, repeated a * b times.
//   PERMUTE(x, p)           output axis i is input axis p[i]. So output
//                           index i0 i1 ... reads input index j where
//                           j[p[i]] = i_i.
//   PAD(x, off, size)       x placed at `off` inside zeros of `size`.
//   SHRINK(x, off, size)    `size` elements of x, starting at `off`.
//   RESHAPE                 the same numbers, row-major, a new shape.
//   REDUCE(x, pop=k)        combine the k leading axes away: output
//                           element j is the sum (or max, or product) of
//                           every input element whose position, past the
//                           first k axes, is j.
//
// REDUCE starts from its op's identity: 0 for add, 1 for mul, and the
// smallest value there is for max (tinygrad's identity_element).
//
// After rangeify (Chapter 37), REDUCE has a second form: no axes to pop,
// but RANGEs as extra srcs, REDUCE(x, r0, r1, op=add). It means the sum of x
// over every value of the ranges: a loop with an accumulator, like END
// but adding up instead of storing. That's what a kernel's reduction
// looks like in tinygrad between rangeify and codegen.
//
// YOUR TASK: EXPAND, PERMUTE, PAD and SHRINK in evalMovement(), and the
// combining step of evalReduce().
//
const std = @import("std");

/// A flat position as an index, for a row-major shape (008).
fn unravel(pos: usize, shape: []const usize, idx: []usize) void {
    var rem = pos;
    var k = shape.len;
    while (k > 0) {
        k -= 1;
        idx[k] = rem % shape[k];
        rem /= shape[k];
    }
}

/// An index as a flat position, for a row-major shape (007).
fn ravel(idx: []const usize, shape: []const usize) usize {
    var pos: usize = 0;
    for (idx, shape) |i, s| pos = pos * s + i;
    return pos;
}

fn evalMovement(it: *Interp, u: *const UOp, x: Value) RunError!Value {
    const g = it.g;
    const v = it.alloc(u.dtype, u.shape);
    const idx = g.alloc.alloc(usize, @max(u.shape.len, x.shape.len)) catch @panic("out of memory");
    switch (u.op) {
        .reshape => @memcpy(v.data, x.data), // row-major order doesn't move
        .expand => {
            // new axes in front: all of x, once per position of the new axes
            const n = x.data.len;
            if (n == 0) return v;
            for (0..v.data.len / n) |rep| {
                @memcpy(v.data[rep * n .. (rep + 1) * n], x.data);
            }
        },
        .permute => {
            const perm = try g.asInts(u.src[1]);
            const in_idx = g.alloc.alloc(usize, perm.len) catch @panic("out of memory");
            for (v.data, 0..) |*d, pos| {
                unravel(pos, u.shape, idx[0..u.shape.len]);
                // output axis i is input axis perm[i]
                for (perm, 0..) |axis, i| in_idx[axis] = idx[i];
                d.* = x.data[ravel(in_idx, x.shape)];
            }
        },
        .pad => {
            const offsets = try g.asInts(u.src[1]);
            @memset(v.data, 0);
            for (x.data, 0..) |d, pos| {
                unravel(pos, x.shape, idx[0..x.shape.len]);
                for (idx[0..x.shape.len], offsets) |*i, off| i.* += off;
                v.data[ravel(idx[0..u.shape.len], u.shape)] = d;
            }
        },
        .shrink => {
            const offsets = try g.asInts(u.src[1]);
            for (v.data, 0..) |*d, pos| {
                unravel(pos, u.shape, idx[0..u.shape.len]);
                for (idx[0..u.shape.len], offsets) |*i, off| i.* += off;
                d.* = x.data[ravel(idx[0..x.shape.len], x.shape)];
            }
        },
        else => unreachable,
    }
    return v;
}

/// Where a REDUCE starts. (tinygrad: identity_element)
fn identity(op: Op, dtype: DType) f64 {
    return switch (op) {
        .add => 0,
        .mul => 1,
        .max => switch (dtype) {
            .i32 => -2147483648,
            .bool => 0,
            else => -std.math.inf(f64),
        },
        else => unreachable,
    };
}

/// The same, as a literal of the dtype a buffer of `dtype` would have (181).
fn identityConst(g: *Graph, op: Op, dtype: DType) *const UOp {
    const d = commit(dtype);
    const v = identity(op, d);
    return if (d.isFloat()) g.float(v) else g.int(@intFromFloat(v));
}

/// REDUCE: pop leading axes off a tensor, or combine src[0] over the
/// values of the ranges src[1..] (after rangeify).
fn evalReduce(it: *Interp, u: *const UOp) RunError!Value {
    const op = u.arg.reduce.op;
    const v = it.alloc(u.dtype, u.shape);
    @memset(v.data, identity(op, u.dtype));
    if (u.src.len == 1) {
        const x = try it.eval(u.src[0]);
        // the leading axes go; what's left is the last v.data.len of each block
        const kept = v.data.len;
        for (x.data, 0..) |d, pos| {
            const j = pos % kept;
            v.data[j] = execAlu(op, u.dtype, &.{ v.data[j], d });
        }
        return v;
    }
    const ranges = u.src[1..];
    const counters = it.g.alloc.alloc(i64, ranges.len) catch @panic("out of memory");
    if (it.startLoops(ranges, counters)) {
        while (true) {
            const x = try it.eval(u.src[0]);
            for (v.data, x.data) |*acc, d| acc.* = execAlu(op, u.dtype, &.{ acc.*, d });
            if (!it.step(ranges, counters)) break;
        }
    }
    return v;
}

const t = std.testing;

fn expectRuns(text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    var it = Interp.init(&g);
    runUir(&it, text) catch |err| {
        std.debug.print("{s}: {s}{s}\n", .{ @errorName(err), it.why, g.why });
        return err;
    };
}

test "weeks 4 and 5" {
    try expectRuns(
        \\%values = add [1 2 3] (expand 1 3)
        \\%sum = reduce %values op=add pop=1
        \\%test = assert %sum 9
    );
    try expectRuns(
        \\%matrix = reshape [1 2 3 4] [2 2]
        \\%transposed = permute %matrix [1 0]
        \\%test = assert (index %transposed 1 0) 2
    );
}

test "each movement op" {
    try expectRuns("%x = expand [1 2] [3]\n%t = assert %x [[1 2] [1 2] [1 2]]");
    try expectRuns("%x = expand 5 [2 2]\n%t = assert %x [[5 5] [5 5]]");
    try expectRuns("%x = pad [1 2 3] [1] [5]\n%t = assert %x [0 1 2 3 0]");
    try expectRuns("%x = shrink [10 20 30 40] [1] [2]\n%t = assert %x [20 30]");
    try expectRuns("%x = pad (reshape [1 2 3 4] [2 2]) [0 1] [3 3]\n%t = assert %x [[0 1 2] [0 3 4] [0 0 0]]");
    try expectRuns("%x = shrink (reshape [1 2 3 4 5 6] [2 3]) [1 1] [1 2]\n%t = assert %x [[5 6]]");
    // a 3-axis permute: output [i j k] is input [j k i], so out[3 1 2] = in[1 2 3] = 1*12 + 2*4 + 3
    try expectRuns(
        \\%x = reshape [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23] [2 3 4]
        \\%p = permute %x [2 0 1]
        \\%t = assert (index %p 3 1 2) 23
        \\%u = assert (index %p 0 1 1) 16
    );
}

test "reduces" {
    try expectRuns("%x = reduce (reshape [1 2 3 4 5 6] [2 3]) op=add pop=1\n%t = assert %x [5 7 9]");
    try expectRuns("%x = reduce (reshape [1 2 3 4 5 6] [2 3]) op=max pop=2\n%t = assert %x 6");
    try expectRuns("%x = reduce (reshape [1 2 3 4 5 6] [3 2]) op=mul pop=1\n%t = assert %x [15 48]");
    try expectRuns("%x = reduce [-5 -2 -9] op=max pop=1\n%t = assert %x -2");
    // over ranges: the sum of [1 2 3 4] at r = 0..3
    try expectRuns("%r = range 4 slot=0\n%s = reduce (index [1 2 3 4] %r) %r op=add\n%t = assert %s 10");
}

test "a matmul from movement ops, the leading-axis way" {
    // C[i, j] = sum over k of A[i, k] * B[k, j]: put k in front, then pop it
    try expectRuns(
        \\%a = reshape [1 2 3 4 5 6] [2 3]
        \\%b = reshape [7 8 9 10 11 12] [3 2]
        \\%a3 = permute (expand (permute %a [1 0]) [2]) [1 2 0]
        \\%b3 = permute (expand %b [2]) [1 0 2]
        \\%c = reduce (mul %a3 %b3) op=add pop=1
        \\%t = assert %c [[58 64] [139 154]]
    );
}

test "a 1D convolution: windows by shrink, stacked" {
    // [1 2 3 4 5] with the kernel [1 0 -1], no padding: x[i] - x[i+2]
    try expectRuns(
        \\%x = [1 2 3 4 5]
        \\%win = stack (shrink %x [0] [3]) (shrink %x [1] [3]) (shrink %x [2] [3])
        \\%w = permute (expand [1 0 -1] [3]) [1 0]
        \\%y = reduce (mul %win %w) op=add pop=1
        \\%t = assert %y [-2 -2 -2]
    );
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
                break :blk .{ .param = .{ .slot = std.math.cast(u32, slot) orelse return g.fail("slot= out of range"), .dtype = dtype } };
            },
            .range => blk: {
                const slot = args.slot orelse return g.fail("a range needs slot=");
                if (args.dtype != null or args.op != null or args.pop != null) return g.fail("unknown arg");
                break :blk .{ .int = slot };
            },
            .reduce => blk: {
                const rop = args.op orelse return g.fail("a reduce needs op=");
                if (args.slot != null or args.dtype != null) return g.fail("unknown arg");
                break :blk .{ .reduce = .{ .op = rop, .pop = std.math.cast(u32, args.pop orelse 0) orelse return g.fail("pop= out of range") } };
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

const Value = struct {
    dtype: DType,
    shape: []const usize,
    data: []f64,

    fn scalar(v: Value) f64 {
        std.debug.assert(v.data.len == 1);
        return v.data[0];
    }
};

const RunError = Error || error{ AssertFailed, OutOfBounds, Unbound };

/// Where a read or a write goes: a whole buffer, or one element of it.
const Place = struct { buf: *const UOp, mem: []f64, offset: usize, whole: bool };

const Interp = struct {
    g: *Graph,
    memory: std.AutoHashMap(*const UOp, []f64), //   each BUFFER's and ALLOC's numbers
    loops: std.AutoHashMap(*const UOp, i64), //      the current value of each running RANGE
    fixed: std.AutoHashMap(*const UOp, Value), //    values no running RANGE can change
    varying: std.AutoHashMap(*const UOp, Value), //  values in the current loop step
    open: std.AutoHashMap(*const UOp, []const *const UOp),
    why: []const u8 = "",

    fn init(g: *Graph) Interp {
        return .{
            .g = g,
            .memory = .init(g.alloc),
            .loops = .init(g.alloc),
            .fixed = .init(g.alloc),
            .varying = .init(g.alloc),
            .open = .init(g.alloc),
        };
    }

    fn fail(it: *Interp, err: RunError, why: []const u8) RunError {
        it.why = why;
        return err;
    }

    /// The numbers of a BUFFER or ALLOC: zeros, the first time.
    fn storage(it: *Interp, buf: *const UOp) []f64 {
        const gop = it.memory.getOrPut(buf) catch @panic("out of memory");
        if (!gop.found_existing) {
            gop.value_ptr.* = it.g.alloc.alloc(f64, prod(buf.shape)) catch @panic("out of memory");
            @memset(gop.value_ptr.*, 0);
        }
        return gop.value_ptr.*;
    }

    /// The RANGEs u depends on that nothing has closed. (tinygrad: UOp.ranges)
    fn openRanges(it: *Interp, u: *const UOp) []const *const UOp {
        if (it.open.get(u)) |r| return r;
        var out: std.ArrayList(*const UOp) = .empty;
        if (u.op == .range) out.append(it.g.alloc, u) catch @panic("out of memory");
        for (u.src, 0..) |s, i| {
            if (u.op == .call and i == 0) continue; // a CALL's body is its own world
            for (it.openRanges(s)) |r| {
                if (std.mem.indexOfScalar(*const UOp, out.items, r) == null) out.append(it.g.alloc, r) catch @panic("out of memory");
            }
        }
        // END, STAGE and a REDUCE over ranges close the ranges in src[1..]
        const closes = u.op == .end or u.op == .stage or (u.op == .reduce and u.src.len > 1);
        if (closes) {
            var i: usize = 0;
            while (i < out.items.len) {
                if (std.mem.indexOfScalar(*const UOp, u.src[1..], out.items[i]) != null) {
                    _ = out.orderedRemove(i);
                } else i += 1;
            }
        }
        it.open.put(u, out.items) catch @panic("out of memory");
        return out.items;
    }

    fn eval(it: *Interp, u: *const UOp) RunError!Value {
        if (it.fixed.get(u)) |v| return v;
        if (it.varying.get(u)) |v| return v;
        const v = try it.compute(u);
        const memo = if (it.openRanges(u).len == 0) &it.fixed else &it.varying;
        memo.put(u, v) catch @panic("out of memory");
        return v;
    }

    fn alloc(it: *Interp, dtype: DType, shape: []const usize) Value {
        const data = it.g.alloc.alloc(f64, prod(shape)) catch @panic("out of memory");
        return .{ .dtype = dtype, .shape = shape, .data = data };
    }

    fn void_(it: *Interp) Value {
        return it.alloc(.void, &.{});
    }

    /// Run the ranges' loops: set each to its next value, the innermost
    /// first. False when they've all been through every value.
    fn step(it: *Interp, ranges: []const *const UOp, counters: []i64) bool {
        it.varying.clearRetainingCapacity();
        var k = ranges.len;
        while (k > 0) {
            k -= 1;
            counters[k] += 1;
            if (counters[k] < ranges[k].src[0].intValue().?) {
                it.setLoops(ranges, counters);
                return true;
            }
            counters[k] = 0;
        }
        for (ranges) |r| _ = it.loops.remove(r);
        return false;
    }

    /// Start the loops over `ranges`. False if some range is empty.
    fn startLoops(it: *Interp, ranges: []const *const UOp, counters: []i64) bool {
        @memset(counters, 0);
        for (ranges) |r| {
            if (r.op != .range) return false;
            if (r.src[0].intValue().? <= 0) return false;
        }
        it.varying.clearRetainingCapacity();
        it.setLoops(ranges, counters);
        return true;
    }

    fn setLoops(it: *Interp, ranges: []const *const UOp, counters: []const i64) void {
        for (ranges, counters) |r, c| it.loops.put(r, c) catch @panic("out of memory");
    }

    /// Where a read or write of u goes, or null if u isn't memory at all.
    fn place(it: *Interp, u: *const UOp) RunError!?Place {
        switch (u.op) {
            .buffer, .alloc => return .{ .buf = u, .mem = it.storage(u), .offset = 0, .whole = true },
            .after => {
                for (u.src[1..]) |dep| _ = try it.eval(dep); // the stores happen first
                return it.place(u.src[0]);
            },
            .index => {
                const base = (try it.place(u.src[0])) orelse return null; // indexing a value, not memory
                if (u.src.len != 2 or !base.whole) return it.fail(error.Spec, "index a buffer with exactly one int");
                const i = (try it.eval(u.src[1])).scalar();
                if (i < 0 or i >= @as(f64, @floatFromInt(base.mem.len))) return it.fail(error.OutOfBounds, "an INDEX outside its buffer");
                return .{ .buf = base.buf, .mem = base.mem, .offset = @intFromFloat(i), .whole = false };
            },
            .param => return it.fail(error.Unbound, "a PARAM outside its CALL"),
            else => return null,
        }
    }

    fn read(it: *Interp, p: Place) Value {
        const dtype = p.buf.arg.param.dtype;
        if (p.whole) {
            const v = it.alloc(dtype, p.buf.shape);
            @memcpy(v.data, p.mem);
            return v;
        }
        const v = it.alloc(dtype, &.{});
        v.data[0] = p.mem[p.offset];
        return v;
    }

    /// STORE value into target, committed to the buffer's dtype.
    fn write(it: *Interp, target: *const UOp, value: Value) RunError!void {
        const p = (try it.place(target)) orelse return it.fail(error.Spec, "a STORE needs a buffer, or an INDEX into one");
        const n = if (p.whole) p.mem.len else 1;
        if (value.data.len != n) return it.fail(error.Spec, "a STORE's value doesn't fit its target");
        for (value.data, 0..) |x, i| p.mem[p.offset + i] = fit(p.buf.arg.param.dtype, x);
    }

    fn compute(it: *Interp, u: *const UOp) RunError!Value {
        switch (u.op) {
            .constant => {
                const v = it.alloc(u.dtype, &.{});
                v.data[0] = switch (u.arg) {
                    .int => |x| @floatFromInt(x),
                    .float => |x| x,
                    .boolean => |x| if (x) 1 else 0,
                    else => unreachable,
                };
                return v;
            },
            .range => {
                const i = it.loops.get(u) orelse return it.fail(error.Unbound, "a RANGE outside its loop");
                const v = it.alloc(.weakint, &.{});
                v.data[0] = @floatFromInt(i);
                return v;
            },
            .param => return it.fail(error.Unbound, "a PARAM outside its CALL"),
            .call => return it.eval(try inlineCall(it.g, u)),
            .buffer, .alloc, .after, .load => {
                const target = if (u.op == .load) u.src[0] else u;
                if (try it.place(target)) |p| return it.read(p);
                // not memory (place() has run an AFTER's deps): the value underneath
                return it.eval(u.src[0]);
            },
            .index => {
                if (try it.place(u)) |p| return it.read(p);
                return it.indexValue(u);
            },
            .store => {
                try it.write(u.src[0], try it.eval(u.src[1]));
                return it.void_();
            },
            .end => {
                const ranges = u.src[1..];
                const counters = it.g.alloc.alloc(i64, ranges.len) catch @panic("out of memory");
                if (it.startLoops(ranges, counters)) {
                    while (true) {
                        _ = try it.eval(u.src[0]);
                        if (!it.step(ranges, counters)) break;
                    }
                }
                return it.void_();
            },
            .sink => {
                for (u.src) |s| _ = try it.eval(s);
                return it.void_();
            },
            .assert => {
                const got = try it.eval(u.src[0]);
                const want = try it.eval(u.src[1]);
                if (!sameShape(got.shape, want.shape)) return it.fail(error.AssertFailed, "assert: the shapes differ");
                for (got.data, want.data) |a, b| {
                    // compare as the actual dtype: the literal 0.1 is an f32's 0.1 here
                    const same = a == fit(got.dtype, b) or (std.math.isNan(a) and std.math.isNan(b));
                    if (!same) return it.fail(error.AssertFailed, "assert: the values differ");
                }
                return it.void_();
            },
            .stack => {
                const v = it.alloc(u.dtype, u.shape);
                var at: usize = 0;
                for (u.src) |s| {
                    const x = try it.eval(s);
                    for (x.data) |d| {
                        v.data[at] = fit(u.dtype, d);
                        at += 1;
                    }
                }
                return v;
            },
            .where => {
                // a scalar condition is a GATE: only the side it picks runs, like
                // C's ?:. A padded read, WHERE(valid, x[i - 1], 0), must not read
                // x[-1] where it isn't valid. (tinygrad gates the load itself.)
                const c = try it.eval(u.src[0]);
                if (u.shape.len == 0) {
                    const picked = try it.eval(if (c.scalar() != 0) u.src[1] else u.src[2]);
                    const v = it.alloc(u.dtype, u.shape);
                    v.data[0] = fit(u.dtype, picked.scalar());
                    return v;
                }
                return it.elementwise(u);
            },
            .cast, .recip, .add, .mul, .max, .xor, .shl, .div, .mod, .cmplt, .cmpne => return it.elementwise(u),

            .reshape, .expand, .permute, .pad, .shrink => return evalMovement(it, u, try it.eval(u.src[0])),
            .reduce => return evalReduce(it, u),
            .stage => {
                // the value of src[0] at every value of the ranges, stacked in front
                const ranges = u.src[1..];
                const v = it.alloc(u.dtype, u.shape);
                const counters = it.g.alloc.alloc(i64, ranges.len) catch @panic("out of memory");
                var at: usize = 0;
                if (it.startLoops(ranges, counters)) {
                    while (true) {
                        const x = try it.eval(u.src[0]);
                        @memcpy(v.data[at .. at + x.data.len], x.data);
                        at += x.data.len;
                        if (!it.step(ranges, counters)) break;
                    }
                }
                return v;
            },
        }
    }

    /// An ALU op, element by element (183).
    fn elementwise(it: *Interp, u: *const UOp) RunError!Value {
        var srcs: [3]Value = undefined;
        for (u.src, 0..) |s, i| srcs[i] = try it.eval(s);
        const v = it.alloc(u.dtype, u.shape);
        for (v.data, 0..) |*d, j| {
            var args: [3]f64 = undefined;
            for (srcs[0..u.src.len], 0..) |s, i| args[i] = s.data[j];
            d.* = if (u.op == .cast) castValue(args[0], u.dtype) else execAlu(u.op, u.dtype, args[0..u.src.len]);
        }
        return v;
    }

    /// INDEX into a value (not memory): pops leading axes. An index that is
    /// itself a tensor gathers, its shape coming first (182).
    fn indexValue(it: *Interp, u: *const UOp) RunError!Value {
        const x = try it.eval(u.src[0]);
        const idx = u.src[1..];
        const v = it.alloc(u.dtype, u.shape);
        const inner = prod(x.shape[idx.len..]);
        var vals = it.g.alloc.alloc(Value, idx.len) catch @panic("out of memory");
        var front: usize = 1;
        for (idx, 0..) |s, j| {
            vals[j] = try it.eval(s);
            front *= vals[j].data.len;
        }
        for (0..front) |f| {
            var rem = f;
            var offset: usize = 0;
            var stride = inner;
            var j = idx.len;
            while (j > 0) {
                j -= 1;
                const n = vals[j].data.len;
                const i = vals[j].data[rem % n];
                rem /= n;
                if (i < 0 or i >= @as(f64, @floatFromInt(x.shape[j]))) return it.fail(error.OutOfBounds, "an INDEX outside its tensor");
                offset += @as(usize, @intFromFloat(i)) * stride;
                stride *= x.shape[j];
            }
            @memcpy(v.data[f * inner .. (f + 1) * inner], x.data[offset .. offset + inner]);
        }
        return v;
    }
};

/// Run a program: each ASSERT, in order, and then the last line. The other
/// lines are just definitions: they run when something uses them. (A bare
/// RANGE has no value outside its loop, nor a PARAM outside its CALL.)
/// A failure's reason is in it.why, or it.g.why if the spec rejected it.
fn runUir(it: *Interp, text: []const u8) RunError!void {
    const lines = try parseLines(it.g, text);
    for (lines, 0..) |line, i| {
        if (line.op == .assert or i == lines.len - 1) _ = try it.eval(line);
    }
}
