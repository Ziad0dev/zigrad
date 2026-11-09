// HARD MODE (zig build -Dhard): no blanks to fill in. Every function
// marked ??? has lost its whole body: write it, from its doc comment,
// its signature and the tests. The gentler version of this file is in
// exercises/, and the answer in solutions/.
//
// ─── Exercise 195: kernels you can run ────────────────────────────────
//
// Chapter 37's capstone: from a tensor program to compiled C, through
// everything you've built. The gist's matmul (reshape, mul, reduce)
// becomes one kernel (192-194), and that kernel's body becomes C (042),
// compiled with `zig cc` and loaded with std.DynLib (052).
//
// Rendering the body is a walk over it. Statements come from the
// structure, expressions from the rest:
//
//   END(x, r0, r1)     for (int r0 = 0; r0 < n0; r0++) { for (...r1...) { x } }
//   STORE(INDEX(p, i), v)     p[i] = v;
//   REDUCE(x, r)       a statement BEFORE the store that uses it:
//                          float acc0 = 0.0f;              (its identity)
//                          for (int r = 0; r < n; r++) acc0 = acc0 + x;
//                      and then, in the expression, just acc0. A reduce
//                      inside a reduce goes inside that reduce's loop.
//   INDEX(p, i)        p[i]                 RANGE      r3
//   WHERE(c, a, b)     (c ? a : b)          DIV, MOD   idiv(a, b), imod(a, b):
//                                                      floor, not C's / (183)
//
// Every kernel gets the same C signature, `void kernel(void **b)`: its
// PARAMs, by slot, as pointers, so one Zig function type calls them all.
// (minicompiler.zig does the same.)
//
// This is the whole of tinygrad's pipeline in miniature: tensor graph,
// rangeify, kernels, render, compile, run. Chapter 38 makes it fast.
//
// YOUR TASK: the loop and the store in stmt(), a REDUCE's loop in
// reduceStmt(), and INDEX and WHERE in expr().
//
const std = @import("std");

const CRender = struct {
    g: *Graph,
    w: *std.Io.Writer,
    accs: std.AutoHashMap(*const UOp, usize),
    depth: usize = 1,

    fn ctype(d: DType) []const u8 {
        return switch (commit(d)) {
            .f32 => "float",
            .i32, .bool => "int",
            else => "void",
        };
    }

    fn indent(r: *CRender) std.Io.Writer.Error!void {
        for (0..r.depth) |_| try r.w.writeAll("  ");
    }

    fn expr(r: *CRender, u: *const UOp) std.Io.Writer.Error!void {
        const w = r.w;
        switch (u.op) {
            .constant => switch (u.arg) {
                .int => |v| try w.print("{d}", .{v}),
                .boolean => |v| try w.writeAll(if (v) "1" else "0"),
                .float => |v| {
                    if (std.math.isInf(v)) return w.writeAll(if (v > 0) "__builtin_inff()" else "-__builtin_inff()");
                    var buf: [64]u8 = undefined;
                    const digits = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
                    try w.print("{s}{s}f", .{ digits, if (std.mem.indexOfAny(u8, digits, ".e") == null) ".0" else "" });
                },
                else => unreachable,
            },
            .range => try w.print("r{d}", .{u.arg.int}),
            .param => try w.print("p{d}[0]", .{u.arg.param.slot}), // a scalar buffer
            .index => {
                if (reduceLane(u)) |rl| return w.print("acc{d}[{d}]", .{ r.accs.get(rl.red).?, rl.lane });
                ???;
                try r.expr(u.src[1]);
                try w.writeAll("]");
            },
            .reduce => try w.print("acc{d}", .{r.accs.get(u).?}),
            .where => {
                try w.writeAll("(");
                try r.expr(u.src[0]);
                ???;
                try r.expr(u.src[1]);
                try w.writeAll(" : ");
                try r.expr(u.src[2]);
                try w.writeAll(")");
            },
            .cast => {
                try w.print("(({s})", .{ctype(u.dtype)});
                try r.expr(u.src[0]);
                try w.writeAll(")");
            },
            .recip => {
                try w.writeAll("(1.0f / ");
                try r.expr(u.src[0]);
                try w.writeAll(")");
            },
            .max, .div, .mod => {
                const name = switch (u.op) {
                    .max => if (u.dtype.isFloat()) "fmax2" else "imax2",
                    .div => "idiv",
                    else => "imod",
                };
                try w.print("{s}(", .{name});
                try r.expr(u.src[0]);
                try w.writeAll(", ");
                try r.expr(u.src[1]);
                try w.writeAll(")");
            },
            .add, .mul, .xor, .shl, .cmplt, .cmpne => {
                const sym = switch (u.op) {
                    .add => " + ",
                    .mul => " * ",
                    .xor => " ^ ",
                    .shl => " << ",
                    .cmplt => " < ",
                    else => " != ",
                };
                try w.writeAll("(");
                try r.expr(u.src[0]);
                try w.writeAll(sym);
                try r.expr(u.src[1]);
                try w.writeAll(")");
            },
            else => unreachable,
        }
    }

    fn openLoop(r: *CRender, rng: *const UOp) std.Io.Writer.Error!void {
        try r.indent();
        try r.w.print("for (int r{d} = 0; r{d} < {d}; r{d}++) {{\n", .{ rng.arg.int, rng.arg.int, rng.src[0].intValue().?, rng.arg.int });
        r.depth += 1;
    }

    fn closeLoop(r: *CRender) std.Io.Writer.Error!void {
        r.depth -= 1;
        try r.indent();
        try r.w.writeAll("}\n");
    }

    /// Emit, as statements, every REDUCE that `u` uses (but not those
    /// inside them: each reduce emits its own).
    fn hoistReduces(r: *CRender, u: *const UOp) std.Io.Writer.Error!void {
        if (u.op == .reduce) {
            if (!r.accs.contains(u)) try r.reduceStmt(u);
            return;
        }
        for (u.src) |s| try r.hoistReduces(s);
    }

    fn reduceStmt(r: *CRender, red: *const UOp) std.Io.Writer.Error!void {
        ???; // write this function's body
    }

    fn stmt(r: *CRender, u: *const UOp) std.Io.Writer.Error!void {
        ???; // write this function's body
    }
};

/// The lanes of a vector: a STACK (of STACKs...) flattened, row-major.
fn vectorLanes(g: *Graph, u: *const UOp) []const *const UOp {
    if (u.op != .stack) return g.alloc.dupe(*const UOp, &.{u}) catch @panic("out of memory");
    var out: std.ArrayList(*const UOp) = .empty;
    for (u.src) |s| out.appendSlice(g.alloc, vectorLanes(g, s)) catch @panic("out of memory");
    return out.items;
}

/// INDEX(INDEX(REDUCE, a), b) with constant a, b: which reduce, which lane.
fn reduceLane(u: *const UOp) ?struct { red: *const UOp, lane: usize } {
    var x = u;
    var idx: [8]usize = undefined;
    var k: usize = 0;
    while (x.op == .index) {
        if (x.src.len != 2) return null;
        const c = x.src[1].intValue() orelse return null;
        idx[k] = @intCast(c);
        k += 1;
        x = x.src[0];
    }
    if (x.op != .reduce or k == 0) return null;
    // the outermost INDEX was found first: reverse into axis order
    std.mem.reverse(usize, idx[0..k]);
    var lane: usize = 0;
    for (idx[0..k], x.shape[0..k]) |i, n| lane = lane * n + i;
    return .{ .red = x, .lane = lane };
}

const c_helpers =
    \\static inline int idiv(int a, int b) { int q = a / b; return (q * b != a && ((a < 0) != (b < 0))) ? q - 1 : q; }
    \\static inline int imod(int a, int b) { return a - idiv(a, b) * b; }
    \\static inline float fmax2(float a, float b) { return a > b ? a : b; }
    \\static inline int imax2(int a, int b) { return a > b ? a : b; }
    \\
;

/// A kernel's body (a CALL's src[0]) as one C function: void kernel(void **b).
fn renderC(g: *Graph, body: *const UOp, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var params: [16]?*const UOp = @splat(null);
    var n: usize = 0;
    for (toposort(g, body, false)) |u| {
        if (u.op != .param) continue;
        params[u.arg.param.slot] = u;
        n = @max(n, u.arg.param.slot + 1);
    }
    try w.writeAll(c_helpers);
    try w.writeAll("void kernel(void **b) {\n");
    for (params[0..n], 0..) |p, i| {
        const ty = CRender.ctype(p.?.arg.param.dtype);
        try w.print("  {s} *p{d} = ({s} *)b[{d}];\n", .{ ty, i, ty, i });
    }
    var r: CRender = .{ .g = g, .w = w, .accs = .init(g.alloc) };
    try r.stmt(body);
    try w.writeAll("}\n");
}

const KernelFn = *const fn ([*]const ?*anyopaque) callconv(.c) void;

/// Render, compile with zig cc, and load one kernel body.
fn compile(g: *Graph, body: *const UOp, tmp: *std.testing.TmpDir, name: []const u8) !std.DynLib {
    const io = std.testing.io;
    var src: std.Io.Writer.Allocating = .init(g.alloc);
    try renderC(g, body, &src.writer);
    const c_name = try std.fmt.allocPrint(g.alloc, "{s}.c", .{name});
    try tmp.dir.writeFile(io, .{ .sub_path = c_name, .data = src.written() });
    var dir_buf: [4096]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const c_path = try std.fs.path.join(g.alloc, &.{ dir, c_name });
    const so_path = try std.fs.path.join(g.alloc, &.{ dir, try std.fmt.allocPrint(g.alloc, "{s}.so", .{name}) });
    const result = try std.process.run(g.alloc, io, .{
        .argv = &.{ "zig", "cc", "-O3", "-march=native", "-shared", "-fPIC", "-nostdlib", c_path, "-o", so_path },
    });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("zig cc failed:\n{s}\n{s}\n", .{ result.stderr, src.written() });
        return error.CompileFailed;
    }
    return std.DynLib.open(so_path);
}

/// Run a schedule of CALLs as compiled C. Buffers are f32 (or i32) arrays.
const Runner = struct {
    g: *Graph,
    tmp: std.testing.TmpDir,
    arrays: std.AutoHashMap(*const UOp, []f32),
    libs: std.ArrayList(std.DynLib) = .empty,

    fn array(rn: *Runner, buf: *const UOp) []f32 {
        const gop = rn.arrays.getOrPut(buf) catch @panic("out of memory");
        if (!gop.found_existing) {
            gop.value_ptr.* = rn.g.alloc.alloc(f32, prod(buf.shape)) catch @panic("out of memory");
            @memset(gop.value_ptr.*, 0);
        }
        return gop.value_ptr.*;
    }

    fn run(rn: *Runner, calls: []const *const UOp) !void {
        for (calls, 0..) |c, i| {
            var lib = try compile(rn.g, c.src[0], &rn.tmp, try std.fmt.allocPrint(rn.g.alloc, "k{d}", .{i}));
            try rn.libs.append(rn.g.alloc, lib);
            const kernel = lib.lookup(KernelFn, "kernel") orelse return error.KernelNotFound;
            var ptrs: [16]?*anyopaque = undefined;
            for (c.src[1..], 0..) |a, j| {
                var buf = a;
                while (buf.op == .after) buf = buf.src[0];
                ptrs[j] = rn.array(buf).ptr;
            }
            kernel(&ptrs);
        }
    }

    fn deinit(rn: *Runner) void {
        for (rn.libs.items) |*l| l.close();
        rn.tmp.cleanup();
    }
};

const t = std.testing;

fn gemm(g: *Graph, a_buf: *const UOp, b_buf: *const UOp, n: usize) !*const UOp {
    // the leading-axis way: C[i, j] = sum over k of A[i, k] * B[k, j]
    const a = try g.reshape(a_buf, &.{ n, n });
    const b = try g.reshape(b_buf, &.{ n, n });
    const a3 = try g.permute(try g.expand(try g.permute(a, &.{ 1, 0 }), &.{n}), &.{ 1, 2, 0 });
    const b3 = try g.permute(try g.expand(b, &.{n}), &.{ 1, 0, 2 });
    return g.reduce(try g.mul(a3, b3), .add, 1);
}

test "a column sum, as C" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .f32, 12);
    const s = try schedule(&g, &.{try g.reduce(try g.reshape(x, &.{ 3, 4 }), .add, 1)});
    var out: std.Io.Writer.Allocating = .init(g.alloc);
    try renderC(&g, s.calls[0].src[0], &out.writer);
    try t.expectEqualStrings(c_helpers ++
        \\void kernel(void **b) {
        \\  float *p0 = (float *)b[0];
        \\  float *p1 = (float *)b[1];
        \\  for (int r0 = 0; r0 < 4; r0++) {
        \\    float acc0 = 0.0f;
        \\    for (int r1 = 0; r1 < 3; r1++) {
        \\      acc0 = acc0 + p1[((r1 * 4) + r0)];
        \\    }
        \\    p0[r0] = acc0;
        \\  }
        \\}
        \\
    , out.written());
}

test "an int reduce gets an int accumulator" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .i32, 12);
    const s = try schedule(&g, &.{try g.reduce(try g.reshape(x, &.{ 3, 4 }), .max, 1)});
    var out: std.Io.Writer.Allocating = .init(g.alloc);
    try renderC(&g, s.calls[0].src[0], &out.writer);
    // max starts from the smallest int, not from a float's -inf
    try t.expect(std.mem.indexOf(u8, out.written(), "int acc0 = -2147483648;") != null);
    try t.expect(std.mem.indexOf(u8, out.written(), "acc0 = imax2(acc0, p1[((r1 * 4) + r0)]);") != null);
}

test "softmax, compiled: three kernels that agree with the interpreter" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const n = 7;
    const x = g.buffer(0, .f32, n);
    const m = try g.reduce(x, .max, 1);
    const d = try g.add(x, try g.mul(try g.expand(m, &.{n}), try g.expand(g.float(-1), &.{n})));
    const y = try g.mul(d, try g.expand(try g.alu(.recip, &.{try g.reduce(d, .add, 1)}), &.{n}));
    const data = [n]f64{ 0.5, 2, -1, 3, 0, 1.5, -2 };
    var it = Interp.init(&g);
    @memcpy(it.storage(x), &data);
    const want = try it.eval(y);

    const s = try schedule(&g, &.{y});
    try t.expectEqual(3, s.calls.len);
    var rn: Runner = .{ .g = &g, .tmp = t.tmpDir(.{}), .arrays = .init(g.alloc) };
    defer rn.deinit();
    for (rn.array(x), data) |*a, v| a.* = @floatCast(v);
    try rn.run(s.calls);
    const got = rn.array(s.lower.filled.get(y).?.src[0]);
    for (want.data, got) |w, v| try t.expectApproxEqAbs(w, v, 1e-5);
}

test "the gist's matmul: one kernel, checked, then timed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    var prng = std.Random.DefaultPrng.init(0);
    const rand = prng.random();

    // small, against the interpreter
    {
        const n = 16;
        const a = g.buffer(0, .f32, n * n);
        const b = g.buffer(1, .f32, n * n);
        const c = try gemm(&g, a, b, n);
        var it = Interp.init(&g);
        for (it.storage(a)) |*v| v.* = @floatCast(@as(f32, rand.float(f32) - 0.5));
        for (it.storage(b)) |*v| v.* = @floatCast(@as(f32, rand.float(f32) - 0.5));
        const want = try it.eval(c);
        const s = try schedule(&g, &.{c});
        try t.expectEqual(1, s.calls.len);
        var rn: Runner = .{ .g = &g, .tmp = t.tmpDir(.{}), .arrays = .init(g.alloc) };
        defer rn.deinit();
        for (rn.array(a), it.storage(a)) |*d, v| d.* = @floatCast(v);
        for (rn.array(b), it.storage(b)) |*d, v| d.* = @floatCast(v);
        try rn.run(s.calls);
        for (want.data, rn.array(s.lower.filled.get(c).?.src[0])) |w, v| try t.expectApproxEqAbs(w, v, 1e-4);
    }

    // 256 x 256, timed (176): compile once, then the best of 5 runs
    const n = 256;
    const a = g.buffer(2, .f32, n * n);
    const b = g.buffer(3, .f32, n * n);
    const s = try schedule(&g, &.{try gemm(&g, a, b, n)});
    try t.expectEqual(1, s.calls.len);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var lib = try compile(&g, s.calls[0].src[0], &tmp, "gemm");
    defer lib.close();
    const kernel = lib.lookup(KernelFn, "kernel") orelse return error.KernelNotFound;
    const av = try g.alloc.alloc(f32, n * n);
    const bv = try g.alloc.alloc(f32, n * n);
    const cv = try g.alloc.alloc(f32, n * n);
    for (av, bv) |*x, *y| {
        x.* = rand.float(f32);
        y.* = rand.float(f32);
    }
    // the CALL's args, in PARAM order: whichever buffers the body touched first
    var ptrs: [3]?*anyopaque = undefined;
    for (s.calls[0].src[1..], 0..) |arg, j| {
        var buf = arg;
        while (buf.op == .after) buf = buf.src[0];
        ptrs[j] = if (buf == a) av.ptr else if (buf == b) bv.ptr else cv.ptr;
    }
    const io = t.io;
    var best: f64 = std.math.inf(f64);
    for (0..5) |_| {
        const t0 = std.Io.Timestamp.now(io, .awake);
        kernel(&ptrs);
        const dt = t0.durationTo(std.Io.Timestamp.now(io, .awake));
        best = @min(best, @as(f64, @floatFromInt(dt.nanoseconds)) * 1e-9);
    }
    // spot checks against a plain loop
    for ([_][2]usize{ .{ 0, 0 }, .{ 17, 200 }, .{ 255, 255 } }) |ij| {
        var sum: f32 = 0;
        for (0..n) |k| sum += av[ij[0] * n + k] * bv[k * n + ij[1]];
        try t.expectApproxEqRel(sum, cv[ij[0] * n + ij[1]], 1e-4);
    }
    const flops: f64 = 2.0 * n * n * n;
    std.debug.print("\n256x256 matmul, from tensors to C: {d:.3} ms, {d:.2} GFLOPS (best of 5)\nChapter 38 makes it faster.\n", .{ best * 1e3, flops / best * 1e-9 });
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
            return .{ @min(a[0], b[0]), @max(a[1], b[1]) };
        },
        .cmplt => {
            const a = bounds(u.src[0]);
            const b = bounds(u.src[1]);
            if (a[1] < b[0]) return .{ 1, 1 }; // always true
            if (a[0] >= b[1]) return .{ 0, 0 }; // never true
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
                return it.eval(target); // LOAD of a plain value is the value
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
                out = seen.items[0];
            } else {
                var agree = true;
                for (seen.items[1..]) |s| agree = agree and sameRanges(s, seen.items[0]);
                if (agree) {
                    out = seen.items[0];
                } else {
                    rf.realize.put(g.alloc, x, {}) catch @panic("out of memory");
                    out = rf.fresh(x.shape);
                }
            }

            // reused across a broadcast's loops: compute it once instead
            const computes = x.op.isAlu() or x.op == .reduce;
            if (end and computes) {
                end = false;
                rf.realize.put(g.alloc, x, {}) catch @panic("out of memory");
                out = rf.fresh(x.shape);
            }

            var in = out;
            if (x.op.isMovement()) in = (try applyMovement(g, x, out, g.boolean(true))).idx;
            if (x.op == .stack) in = out[1..]; // the leading range picks the src; srcs get the rest
            if (x.op == .reduce) {
                const popped = x.src[0].shape[0..x.arg.reduce.pop];
                in = std.mem.concat(g.alloc, *const UOp, &.{ rf.fresh(popped), out }) catch @panic("out of memory");
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

/// The flat position of an index into a row-major shape, simplified.
fn flatIndex(g: *Graph, idx: []const *const UOp, shape: []const usize) Error!*const UOp {
    var flat = g.int(0);
    for (idx, 0..) |i, k| flat = try g.add(flat, try g.mul(i, g.int(@intCast(prod(shape[k + 1 ..])))));
    return symbolic(g, flat);
}

/// Where element idx of x lives in buf: buf itself for a scalar, else an INDEX.
fn element(g: *Graph, buf: *const UOp, idx: []const *const UOp, shape: []const usize) Error!*const UOp {
    if (shape.len == 0) return buf;
    return g.index(buf, &.{try flatIndex(g, idx, shape)});
}

fn zeroOf(g: *Graph, dtype: DType) *const UOp {
    return if (dtype.isFloat()) g.float(0) else if (dtype == .bool) g.boolean(false) else g.int(0);
}

const Lower = struct {
    g: *Graph,
    rf: *Rangeify,
    filled: std.AutoHashMap(*const UOp, *const UOp), // realized value -> AFTER(its buffer, its kernel)
    kernels: std.ArrayList(*const UOp) = .empty, //       each kernel's END, in order
    slot: u32 = 100, //                                  slots for new buffers (inputs use small ones)

    fn init(g: *Graph, rf: *Rangeify) Lower {
        return .{ .g = g, .rf = rf, .filled = .init(g.alloc) };
    }

    /// The scalar value of x at index idx (one index per axis of x).
    fn at(lw: *Lower, x: *const UOp, idx: []const *const UOp) Error!*const UOp {
        const g = lw.g;
        if (lw.filled.get(x)) |buf| return element(g, buf, idx, x.shape);
        return lw.compute(x, idx);
    }

    /// Like at(), but x's own value, never its buffer: for x's own kernel.
    fn compute(lw: *Lower, x: *const UOp, idx: []const *const UOp) Error!*const UOp {
        const g = lw.g;
        switch (x.op) {
            .constant => return x,
            .buffer => return element(g, x, idx, x.shape),
            .stack => {
                // pick a src by the leading index: a chain of WHEREs (tinygrad builds a tree)
                var v = try lw.at(x.src[x.src.len - 1], idx[1..]);
                var k = x.src.len - 1;
                while (k > 0) {
                    k -= 1;
                    v = try g.where(try g.cmplt(idx[0], g.int(@intCast(k + 1))), try lw.at(x.src[k], idx[1..]), v);
                }
                return v;
            },
            .reshape, .permute, .expand, .shrink, .pad => {
                const m = try applyMovement(g, x, idx, g.boolean(true));
                const inner = try lw.at(x.src[0], m.idx);
                if (m.valid == g.boolean(true)) return inner;
                return g.where(m.valid, inner, zeroOf(g, x.dtype));
            },
            .reduce => {
                // the loops 192 made for the axes it pops (fresh ones if it never got any)
                const pop = x.arg.reduce.pop;
                const loops = if (lw.rf.ranges.get(x)) |r| r.in[0..pop] else lw.rf.fresh(x.src[0].shape[0..pop]);
                const inner = try lw.at(x.src[0], std.mem.concat(g.alloc, *const UOp, &.{ loops, idx }) catch @panic("out of memory"));
                var srcs: std.ArrayList(*const UOp) = .empty;
                srcs.append(g.alloc, inner) catch @panic("out of memory");
                for (loops) |r| if (r.op == .range) srcs.append(g.alloc, r) catch @panic("out of memory");
                return g.new(.reduce, srcs.items, .{ .reduce = .{ .op = x.arg.reduce.op, .pop = 0 } });
            },
            else => {
                if (!x.op.isAlu()) return g.fail("can't lower this op");
                const src = g.alloc.alloc(*const UOp, x.src.len) catch @panic("out of memory");
                for (x.src, src) |s, *n| n.* = try lw.at(s, idx);
                return g.new(x.op, src, x.arg);
            },
        }
    }

    /// One kernel: loops over x's ranges, storing every element of x.
    fn kernel(lw: *Lower, x: *const UOp) Error!void {
        const g = lw.g;
        const ranges = lw.rf.ranges.get(x).?.out;
        const size: ?usize = if (x.shape.len == 0) null else prod(x.shape);
        const buf = g.local(lw.slot, commit(x.dtype), size);
        lw.slot += 1;
        const st = try g.store(try element(g, buf, ranges, x.shape), try lw.compute(x, ranges));
        var loops: std.ArrayList(*const UOp) = .empty;
        for (ranges) |r| if (r.op == .range) loops.append(g.alloc, r) catch @panic("out of memory");
        const done = if (loops.items.len == 0) st else try g.end(st, loops.items);
        lw.kernels.append(g.alloc, done) catch @panic("out of memory");
        lw.filled.put(x, try g.after(buf, &.{done})) catch @panic("out of memory");
    }

    /// Every realized value under sink gets its kernel, producers first.
    /// The result: each output, read from its buffer after its kernel.
    fn run(lw: *Lower, sink: *const UOp) Error!*const UOp {
        for (toposort(lw.g, sink, false)) |x| {
            if (lw.rf.realize.contains(x)) try lw.kernel(x);
        }
        const outs = lw.g.alloc.alloc(*const UOp, sink.src.len) catch @panic("out of memory");
        for (sink.src, outs) |s, *o| o.* = lw.filled.get(s).?;
        return lw.g.sink(outs);
    }
};

/// Rangeify a tensor graph: decide the buffers (192), then write the kernels.
fn rangeify(g: *Graph, outputs: []const *const UOp) Error!Lower {
    const rf = g.alloc.create(Rangeify) catch @panic("out of memory");
    rf.* = Rangeify.init(g);
    const sink = try g.sink(outputs);
    try rf.walk(sink);
    var lw = Lower.init(g, rf);
    _ = try lw.run(sink);
    return lw;
}

/// Does x (a realized value) deserve its buffer? (tinygrad: remove_bufferize)
fn keepBuffer(rf: *Rangeify, x: *const UOp) bool {
    const g = rf.g;
    var buffers = std.AutoHashMap(*const UOp, void).init(g.alloc);
    var reduces: std.ArrayList(*const UOp) = .empty;
    // what x is computed from, down to buffers and other realized values
    var stack: std.ArrayList(*const UOp) = .empty;
    var seen = std.AutoHashMap(*const UOp, void).init(g.alloc);
    stack.append(g.alloc, x) catch @panic("out of memory");
    while (stack.pop()) |u| {
        if (seen.contains(u)) continue;
        seen.put(u, {}) catch @panic("out of memory");
        if (u != x and (u.op == .buffer or rf.realize.contains(u))) {
            buffers.put(u, {}) catch @panic("out of memory");
            continue;
        }
        if (u.op == .reduce) reduces.append(g.alloc, u) catch @panic("out of memory");
        const data = if (u.op.isMovement() or u.op == .reduce) u.src[0..1] else u.src;
        for (data) |s| stack.append(g.alloc, s) catch @panic("out of memory");
    }
    if (buffers.count() > 3) return true;
    // a reduce that reads a buffer is a whole loop: don't redo it per element
    for (reduces.items) |r| {
        for (toposort(g, r, false)) |u| {
            if (u != x and (u.op == .buffer or rf.realize.contains(u))) return true;
        }
    }
    return false;
}

/// Un-realize every buffer keepBuffer() doesn't want, producers first.
fn removeCheapBuffers(rf: *Rangeify, outputs: []const *const UOp) void {
    var i: usize = 0;
    while (i < rf.realize.count()) {
        const x = rf.realize.keys()[i];
        const is_output = std.mem.indexOfScalar(*const UOp, outputs, x) != null;
        if (!is_output and !keepBuffer(rf, x)) {
            _ = rf.realize.orderedRemove(x);
        } else i += 1;
    }
}

/// A kernel (an END, or a STORE with no loop) as a CALL of a reusable body.
fn toCall(g: *Graph, kernel: *const UOp) Error!*const UOp {
    var map = Subst.init(g.alloc);
    var args: std.ArrayList(*const UOp) = .empty;
    var slot_of = std.AutoHashMap(*const UOp, u32).init(g.alloc); // buffer -> PARAM slot
    var ranges: u32 = 0;
    for (toposort(g, kernel, false)) |u| {
        switch (u.op) {
            .buffer, .alloc => {
                if (slot_of.contains(u)) continue;
                const slot: u32 = @intCast(args.items.len);
                slot_of.put(u, slot) catch @panic("out of memory");
                args.append(g.alloc, u) catch @panic("out of memory");
                const size: ?usize = if (u.shape.len == 0) null else u.shape[0];
                map.put(u, g.param(slot, u.arg.param.dtype, size)) catch @panic("out of memory");
            },
            .after => {
                // a buffer some kernel writes first: the CALL waits on the AFTER
                const buf = u.src[0];
                const slot = slot_of.get(buf).?; // its BUFFER came first, in toposort order
                args.items[slot] = u;
                map.put(u, map.get(buf).?) catch @panic("out of memory");
            },
            .range => {
                map.put(u, g.range(@intCast(u.src[0].intValue().?), ranges)) catch @panic("out of memory");
                ranges += 1;
            },
            else => {},
        }
    }
    const body = try g.sink(&.{try substitute(g, kernel, &map)});
    return g.call(body, args.items);
}

/// The whole scheduler: rangeify (192), drop cheap buffers, write the
/// kernels (193), and make them CALLs, in the order they must run.
fn schedule(g: *Graph, outputs: []const *const UOp) Error!struct { calls: []const *const UOp, lower: Lower } {
    const rf = g.alloc.create(Rangeify) catch @panic("out of memory");
    rf.* = Rangeify.init(g);
    const sink = try g.sink(outputs);
    try rf.walk(sink);
    removeCheapBuffers(rf, outputs);
    var lw = Lower.init(g, rf);
    _ = try lw.run(sink);
    const calls = g.alloc.alloc(*const UOp, lw.kernels.items.len) catch @panic("out of memory");
    for (lw.kernels.items, calls) |k, *c| c.* = try toCall(g, k);
    return .{ .calls = calls, .lower = lw };
}
