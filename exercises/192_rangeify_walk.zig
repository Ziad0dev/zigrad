//
// ─── Exercise 192: where kernels split ────────────────────────────────
//
// 191 moved ranges through one op. Rangeify (run_rangeify in
// tinygrad/schedule/indexing.py) moves them through the WHOLE graph, from
// the outputs toward the inputs, and on the way decides the most
// important question in an ML compiler: which values get their own
// buffer. Every value that does ("realize" it, 040, 081) is the output of
// one kernel. Everything else is computed inline, inside its consumer's
// loops: that's kernel fusion.
//
// Visit the UOps consumers-first (the toposort, reversed). Each one gets
// the ranges its OUTPUT is indexed by, "out", and passes "in" down to its
// srcs:
//
//   1. A realized value starts fresh: one new RANGE per axis. (An axis of
//      size 1 gets the constant 0, not a RANGE: tinygrad's new_range.)
//   2. One consumer: take its ranges. That's fusion, for free.
//   3. Several consumers that all index it the same way: same thing.
//      But if they disagree (x[i, j] here, x[j, i] there), one loop nest
//      can't produce both: realize it, with fresh ranges.
//   4. in = out for ALU ops. A movement op maps them (191). A REDUCE adds
//      fresh ranges in front, one per axis it pops: those are its loops.
//      (And a STACK's leading range picks one of its srcs, so its srcs get
//      the ranges after it.)
//
// And one more rule, tinygrad's "ending ranges". An EXPAND whose new axes
// are real loops reuses everything below it once per value of those loops.
// If what's below is a computed value, that's the same work again and
// again, so the first ALU op or REDUCE below an EXPAND like that is
// realized. ("fusion decision: REDUCE before the broadcast".)
//
// Softmax comes out as FOUR buffers here: the max, x - max (its two
// readers, the sum and the divide, index it differently: rule 3), 1/sum,
// and the output. (1/sum, not the sum itself: rule 4 realizes the first
// computed value below the broadcast, and that is the RECIP; the sum is
// computed inside its kernel.) tinygrad agrees, at this stage. Then a cost check
// throws away buffers that are cheap to recompute, and x - max is one:
// that's 194, and it's how tinygrad's softmax ends up as three kernels.
// (Run on a batch of rows, tinygrad gives exactly those three. On a single
// vector like this one it saves one more: the sum is a single number, so
// the divide joins the sum's kernel, as a second loop. Two kernels.)
//
// YOUR TASK: rules 2, 3 and 4, and realizing below a broadcast.
//
const std = @import("std");

const Ranges = struct { in: []const *const UOp, out: []const *const UOp };

const Rangeify = struct {
    g: *Graph,
    realize: std.AutoArrayHashMapUnmanaged(*const UOp, void) = .empty, // the values that get a buffer: one kernel each
    ranges: std.AutoHashMap(*const UOp, Ranges),
    slot: i64 = 0,

    fn init(g: *Graph) Rangeify {
        return .{ .g = g, .ranges = .init(g.alloc) };
    }

    /// One new RANGE per axis, or 0 for an axis of size 1. (tinygrad: new_range)
    fn fresh(rf: *Rangeify, shape: []const usize) []const *const UOp {
        const out = rf.g.alloc.alloc(*const UOp, shape.len) catch @panic("out of memory");
        for (out, shape) |*r, n| {
            if (n == 1) {
                r.* = rf.g.int(0);
            } else {
                r.* = rf.g.range(n, rf.slot);
                rf.slot += 1;
            }
        }
        return out;
    }

    fn sameRanges(a: []const *const UOp, b: []const *const UOp) bool {
        return std.mem.eql(*const UOp, a, b);
    }

    /// Run rangeify over the graph under `sink`, whose srcs are the outputs.
    fn walk(rf: *Rangeify, sink: *const UOp) Error!void {
        const g = rf.g;
        const order = toposort(g, sink, false);
        // who reads each UOp as data (not a movement op's shape arguments)
        var consumers = std.AutoHashMap(*const UOp, std.ArrayList(*const UOp)).init(g.alloc);
        for (order) |c| {
            const data = if (c.op.isMovement() or c.op == .reduce) c.src[0..1] else c.src;
            for (data) |s| {
                const gop = consumers.getOrPut(s) catch @panic("out of memory");
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                gop.value_ptr.append(g.alloc, c) catch @panic("out of memory");
            }
        }
        for (sink.src) |out| rf.realize.put(g.alloc, out, {}) catch @panic("out of memory");

        var ending = std.AutoHashMap(*const UOp, bool).init(g.alloc);
        var i = order.len;
        while (i > 0) {
            i -= 1;
            const x = order[i];
            switch (x.op) {
                .sink, .constant, .buffer, .param => continue, // no loops of their own
                else => {},
            }
            const users = if (consumers.get(x)) |c| c.items else &.{};
            var end = false;
            for (users) |c| end = end or (ending.get(c) orelse false);
            var seen: std.ArrayList([]const *const UOp) = .empty;
            for (users) |c| {
                if (rf.ranges.get(c)) |r| seen.append(g.alloc, r.in) catch @panic("out of memory");
            }

            var out: []const *const UOp = undefined;
            if (rf.realize.contains(x)) {
                out = rf.fresh(x.shape);
                end = false;
            } else if (seen.items.len == 0) {
                continue; // nothing reads it with ranges: e.g. a shape argument
            } else if (seen.items.len == 1) {
                out = ???;
            } else {
                var agree = true;
                for (seen.items[1..]) |s| agree = agree and sameRanges(s, seen.items[0]);
                if (agree) {
                    out = seen.items[0];
                } else {
                    ???;
                    out = rf.fresh(x.shape);
                }
            }

            // reused across a broadcast's loops: compute it once instead
            const computes = x.op.isAlu() or x.op == .reduce;
            if (end and computes) {
                end = false;
                rf.realize.put(g.alloc, x, {}) catch @panic("out of memory");
                out = ???;
            }

            var in = out;
            if (x.op.isMovement()) in = (try applyMovement(g, x, out, g.boolean(true))).idx;
            if (x.op == .stack) in = out[1..]; // the leading range picks the src; srcs get the rest
            if (x.op == .reduce) {
                const popped = x.src[0].shape[0..x.arg.reduce.pop];
                in = std.mem.concat(g.alloc, *const UOp, &.{ ???, out }) catch @panic("out of memory");
            }
            // an EXPAND whose new axes are real loops ends here
            if (x.op == .expand) {
                const front = (try g.asInts(x.src[1])).len;
                for (out[0..front]) |r| {
                    if (r.op == .range) end = true;
                }
            }
            ending.put(x, end) catch @panic("out of memory");
            rf.ranges.put(x, .{ .in = in, .out = out }) catch @panic("out of memory");
        }
    }
};

const t = std.testing;

fn kernels(g: *Graph, outputs: []const *const UOp) !Rangeify {
    var rf = Rangeify.init(g);
    try rf.walk(try g.sink(outputs));
    return rf;
}

test "an elementwise chain is one kernel" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .f32, 8);
    const y = try g.add(try g.mul(x, try g.expand(g.float(2), &.{8})), try g.expand(g.float(1), &.{8}));
    const rf = try kernels(&g, &.{y});
    try t.expectEqual(1, rf.realize.count());
    // and its loop runs over all of x
    try t.expectEqual(.range, rf.ranges.get(y).?.out[0].op);
    // the mul inside runs in the very same loop: that's fusion
    try t.expect(rf.ranges.get(y.src[0]).?.out[0] == rf.ranges.get(y).?.out[0]);
}

test "a sum is one kernel, with a loop for the reduce" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = try g.reshape(g.buffer(0, .f32, 12), &.{ 3, 4 });
    const s = try g.reduce(x, .add, 1); // sum over the 3 rows: shape (4)
    const rf = try kernels(&g, &.{s});
    try t.expectEqual(1, rf.realize.count());
    const r = rf.ranges.get(s).?;
    try t.expectEqual(1, r.out.len); // the output loop
    try t.expectEqual(2, r.in.len); //  plus the reduce loop in front
    try t.expect(r.in[1] == r.out[0]);
    try t.expect(r.in[0] != r.out[0]);
}

test "softmax: four buffers, for now" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .f32, 16);
    const m = try g.reduce(x, .max, 1);
    const d = try g.add(x, try g.mul(try g.expand(m, &.{16}), try g.expand(g.float(-1), &.{16}))); // x - max
    const s = try g.reduce(d, .add, 1); // (no exp in our op set: it changes nothing here)
    const inv = try g.alu(.recip, &.{s});
    const y = try g.mul(d, try g.expand(inv, &.{16}));
    const rf = try kernels(&g, &.{y});
    try t.expectEqual(4, rf.realize.count());
    try t.expect(rf.realize.contains(m)); //   the reduce before a broadcast
    try t.expect(rf.realize.contains(inv)); // the first computed value below the other broadcast
    try t.expect(!rf.realize.contains(s)); //  so the sum is computed inside inv's kernel
    try t.expect(rf.realize.contains(d)); //   read two different ways (194 undoes this one)
    try t.expect(rf.realize.contains(y)); //   the output
}

test "a matmul is one kernel" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const a = try g.reshape(g.buffer(0, .f32, 6), &.{ 2, 3 });
    const b = try g.reshape(g.buffer(1, .f32, 12), &.{ 3, 4 });
    const a3 = try g.permute(try g.expand(try g.permute(a, &.{ 1, 0 }), &.{4}), &.{ 1, 2, 0 });
    const b3 = try g.permute(try g.expand(b, &.{2}), &.{ 1, 0, 2 });
    const c = try g.reduce(try g.mul(a3, b3), .add, 1);
    const rf = try kernels(&g, &.{c});
    try t.expectEqual(1, rf.realize.count()); // only movement ops under the EXPANDs
}

test "consumers that disagree force a buffer" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = try g.reshape(g.buffer(0, .f32, 9), &.{ 3, 3 });
    const y = try g.add(x, try g.expand(g.float(1), &.{ 3, 3 }));
    // y + y.T: one loop nest can't produce y[i, j] and y[j, i] at once
    const rf = try kernels(&g, &.{try g.add(y, try g.permute(y, &.{ 1, 0 }))});
    try t.expectEqual(2, rf.realize.count());
    try t.expect(rf.realize.contains(y));
    // y * y reads it the same way twice: no buffer needed
    const rf2 = try kernels(&g, &.{try g.mul(y, y)});
    try t.expectEqual(1, rf2.realize.count());
    // x + x.T: x is a RESHAPE of a buffer, read two ways, so it gets a buffer
    // too, for now. "If a buffer is being stored just for permutes or
    // something, remove it" says tinygrad's remove_bufferize: that's 194.
    const rf3 = try kernels(&g, &.{try g.add(x, try g.permute(x, &.{ 1, 0 }))});
    try t.expectEqual(2, rf3.realize.count());
    try t.expect(rf3.realize.contains(x));
}

test "a computed value is broadcast: compute it once" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .f32, 4);
    const w = try g.reshape(g.buffer(1, .f32, 12), &.{ 3, 4 });
    const y = try g.mul(x, try g.expand(g.float(2), &.{4}));
    const rf = try kernels(&g, &.{try g.add(try g.expand(y, &.{3}), w)});
    try t.expectEqual(2, rf.realize.count());
    try t.expect(rf.realize.contains(y));
    // with a loop of its own, not the broadcast's
    const e = try g.expand(y, &.{3});
    try t.expect(rf.ranges.get(y).?.out[0] != rf.ranges.get(e).?.in[0]);
    // but broadcasting a buffer costs nothing
    const rf2 = try kernels(&g, &.{try g.add(try g.expand(x, &.{3}), w)});
    try t.expectEqual(1, rf2.realize.count());
}

test "an axis of size 1 gets the constant 0, not a loop" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = try g.reshape(g.buffer(0, .f32, 4), &.{ 1, 4 });
    const y = try g.add(x, try g.expand(g.float(1), &.{ 1, 4 }));
    const rf = try kernels(&g, &.{y});
    const out = rf.ranges.get(y).?.out;
    try t.expect(out[0] == g.int(0));
    try t.expectEqual(.range, out[1].op);
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

/// Towards zero, like C. Where C gives up (NaN, or a number too big for
/// any int: undefined behaviour), we pick an answer instead of
/// crashing: NaN is 0, and the rest stop at the largest i64.
fn toInt(x: f64) i64 {
    if (std.math.isNan(x)) return 0;
    const limit: f64 = @floatFromInt(std.math.maxInt(i64));
    if (x >= limit) return std.math.maxInt(i64);
    if (x <= -limit) return std.math.minInt(i64);
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
        .range => return .{ 0, @floatFromInt(u.src[0].intValue().? - 1) },
        .add => {
            const a = bounds(u.src[0]);
            const b = bounds(u.src[1]);
            return .{ a[0] + b[0], a[1] + b[1] };
        },
        .mul => {
            const a = bounds(u.src[0]);
            const b = bounds(u.src[1]);
            const p = [_]f64{ times(a[0], b[0]), times(a[0], b[1]), times(a[1], b[0]), times(a[1], b[1]) };
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
            return .{ @min(a[0], b[0]), @max(a[1], b[1]) };
        },
        .cmplt => {
            const a = bounds(u.src[0]);
            const b = bounds(u.src[1]);
            if (a[1] < b[0]) return .{ 1, 1 }; // always true
            if (a[0] >= b[1]) return .{ 0, 0 }; // never true
            return .{ 0, 1 };
        },
        .cast => {
            if (u.dtype == .bool) return .{ 0, 1 };
            const b = bounds(u.src[0]);
            if (!u.dtype.isInt()) return b;
            // to an int: toward zero (183), and an i32 that could wrap can be anything
            const lo = @trunc(b[0]);
            const hi = @trunc(b[1]);
            if (u.dtype == .i32 and (lo < -2147483648 or hi > 2147483647)) return .{ -2147483648, 2147483647 };
            return .{ lo, hi };
        },
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
/// x * y for the corners of a range. 0 times anything is 0, even times
/// an unknown (infinite) bound: IEEE says 0 * inf is NaN, and a NaN
/// bound would make every comparison with it false, so an index known
/// to be out of bounds would pass the check below.
fn times(x: f64, y: f64) f64 {
    if (x == 0 or y == 0) return 0;
    return x * y;
}

fn checkIndexes(g: *Graph, root: *const UOp) Error!void {
    for (toposort(g, root, true)) |u| {
        if (u.op != .index) continue;
        const mem = memoryOf(u.src[0]) orelse continue;
        if (mem.shape.len != 1 or u.src.len != 2) return g.fail("a buffer is flat: index it with one int");
        const b = bounds(u.src[1]);
        const n: f64 = @floatFromInt(mem.shape[0]);
        if (b[0] < 0 or b[1] > n - 1) return g.fail("an INDEX can go out of bounds");
    }
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

fn isConst(u: *const UOp, v: i64) bool {
    return u.intValue() == v;
}

fn isTrue(u: *const UOp) bool {
    return u.op == .constant and u.arg == .boolean and u.arg.boolean;
}

/// If u is a * c (or c * a) for the constant c, a.
fn timesConst(u: *const UOp, c: i64) ?*const UOp {
    if (u.op != .mul) return null;
    if (isConst(u.src[1], c)) return u.src[0];
    if (isConst(u.src[0], c)) return u.src[1];
    return null;
}

/// One simplification of u, or null if none applies. (072's rules, on UOps.)
fn simplifyOnce(g: *Graph, u: *const UOp) Error!?*const UOp {
    // constant folding: an ALU op of literals is a literal
    if (u.op.isAlu() and u.op != .cast and u.src.len > 0) {
        var all_const = true;
        var args: [3]f64 = undefined;
        for (u.src, 0..) |s, i| {
            if (s.op != .constant) {
                all_const = false;
                break;
            }
            args[i] = constValue(s);
        }
        if (all_const) {
            const v = execAlu(u.op, u.dtype, args[0..u.src.len]);
            return switch (u.dtype) {
                .bool => g.boolean(v != 0),
                .weakint => g.int(@intFromFloat(v)),
                .weakfloat => g.float(v),
                else => null, // a strong dtype: tinygrad keeps the CAST; so do we
            };
        }
    }
    // a comparison bounds can decide, and a WHERE on a constant (185)
    if (u.op == .cmplt) {
        const b = bounds(u);
        if (b[0] == b[1]) return g.boolean(b[0] == 1);
    }
    if (u.op == .where and u.src[0].op == .constant) return if (constValue(u.src[0]) == 1) u.src[1] else u.src[2];
    switch (u.op) {
        .add => {
            if (isConst(u.src[1], 0)) return u.src[0];
            if (isConst(u.src[0], 0)) return u.src[1];
            // (x + c1) + c2 -> x + (c1 + c2)
            if (u.src[1].intValue()) |c2| if (u.src[0].op == .add) if (u.src[0].src[1].intValue()) |c1|
                return try g.add(u.src[0].src[0], g.int(c1 + c2));
        },
        .mul => {
            if (u.dtype == .bool) {
                if (isTrue(u.src[0])) return u.src[1]; // true AND x
                if (isTrue(u.src[1])) return u.src[0];
            }
            if (isConst(u.src[1], 1)) return u.src[0];
            if (isConst(u.src[0], 1)) return u.src[1];
            if (isConst(u.src[1], 0) or isConst(u.src[0], 0)) return g.int(0);
        },
        .div, .mod => {
            const c = u.src[1].intValue() orelse return null;
            if (c <= 0) return null;
            const x = u.src[0];
            if (c == 1) return if (u.op == .div) x else g.int(0);
            const b = bounds(x);
            const cf: f64 = @floatFromInt(c);
            if (b[0] >= 0 and b[1] < cf) return if (u.op == .div) g.int(0) else x;
            if (timesConst(x, c)) |a| return if (u.op == .div) a else g.int(0);
            if (x.op == .add) {
                for (0..2) |side| {
                    // (a*c + y) DIV c -> a + y DIV c, and (a*c + y) MOD c -> y MOD c
                    const a = timesConst(x.src[side], c) orelse continue;
                    const y = x.src[1 - side];
                    if (u.op == .mod) return try g.alu(.mod, &.{ y, u.src[1] });
                    return try g.add(a, try g.alu(.div, &.{ y, u.src[1] }));
                }
            }
        },
        else => {},
    }
    return null;
}

/// Simplify a whole graph: bottom-up, each node until no rule fires (025).
fn symbolic(g: *Graph, root: *const UOp) Error!*const UOp {
    var done = Subst.init(g.alloc);
    return simplifyNode(g, root, &done);
}

fn simplifyNode(g: *Graph, u: *const UOp, done: *Subst) Error!*const UOp {
    if (done.get(u)) |d| return d;
    const src = g.alloc.alloc(*const UOp, u.src.len) catch @panic("out of memory");
    for (u.src, src) |s, *n| n.* = try simplifyNode(g, s, done);
    var cur = try g.new(u.op, src, u.arg);
    while (try simplifyOnce(g, cur)) |next| cur = try simplifyNode(g, next, done);
    done.put(u, cur) catch @panic("out of memory");
    return cur;
}

/// One step up through a movement op: the index into its input, and when
/// that index is valid at all.
const Mapped = struct { idx: []const *const UOp, valid: *const UOp };

/// a AND b, for bools: that's MUL (183).
fn and_(g: *Graph, a: *const UOp, b: *const UOp) Error!*const UOp {
    return g.mul(a, b);
}

fn applyMovement(g: *Graph, u: *const UOp, out: []const *const UOp, valid: *const UOp) Error!Mapped {
    const in_shape = u.src[0].shape;
    var in = g.alloc.alloc(*const UOp, in_shape.len) catch @panic("out of memory");
    var ok = valid;
    switch (u.op) {
        .shrink => {
            const offsets = try g.asInts(u.src[1]);
            for (in, out, offsets) |*i, o, off| i.* = try g.add(o, g.int(@intCast(off)));
        },
        .permute => {
            const perm = try g.asInts(u.src[1]);
            for (perm, 0..) |axis, i| in[axis] = out[i];
        },
        .expand => {
            const front = try g.asInts(u.src[1]);
            // (a copy: `in` is simplified in place below, and `out` is the caller's)
            in = g.alloc.dupe(*const UOp, out[front.len..]) catch @panic("out of memory");
        },
        .pad => {
            const offsets = try g.asInts(u.src[1]);
            for (in, out, offsets, in_shape) |*i, o, off, n| {
                const lo: i64 = @intCast(off);
                const hi: i64 = @intCast(off + n);
                i.* = try g.add(o, g.int(-lo));
                // valid where off <= o < off + n, written with CMPLT only: off - 1 < o
                const inside = try and_(g, try g.cmplt(g.int(lo - 1), o), try g.cmplt(o, g.int(hi)));
                ok = try and_(g, ok, inside);
            }
        },
        .reshape => {
            // flatten over the output shape...
            var flat = g.int(0);
            for (out, 0..) |o, k| flat = try g.add(flat, try g.mul(o, g.int(@intCast(prod(u.shape[k + 1 ..])))));
            // ...and unflatten over the input's
            for (in, 0..) |*i, k| {
                const q = try g.alu(.div, &.{ flat, g.int(@intCast(prod(in_shape[k + 1 ..]))) });
                i.* = try g.alu(.mod, &.{ q, g.int(@intCast(in_shape[k])) });
            }
        },
        else => unreachable,
    }
    for (in) |*i| i.* = try symbolic(g, i.*);
    return .{ .idx = in, .valid = try symbolic(g, ok) };
}
