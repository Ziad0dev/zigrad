//
// ─── Exercise 191: movement ops on ranges ─────────────────────────────
//
// Chapter 37: rangeify, the heart of tinygrad's scheduler today
// (tinygrad/schedule/indexing.py), and 10-411's weeks 4 and 5.
//
// A kernel is loops. To compute y = some ops on x, with y of shape
// (4, 5), you loop r0 over 0..3 and r1 over 0..4, and compute y[r0, r1].
// Rangeify starts there: it gives the OUTPUT one RANGE per axis, then walks
// the graph from the output toward the inputs, asking at each op "if the
// output wants element [r0, r1], which element of my input is that?"
//
// For ALU ops the answer is "the same one". For movement ops it's index
// maths, and that's the whole point: the movement op disappears into the
// index expression, and costs nothing at run time. tinygrad's
// apply_movement_op does exactly this, op by op, from the output's ranges
// to the input's ("rngs" there, `out` here):
//
//   SHRINK(off)       in[k] = out[k] + off[k]
//   PERMUTE(p)        in[p[i]] = out[i]           (tinygrad: rngs[argsort(p)])
//   EXPAND(front)     in = out without its leading len(front) entries: the
//                     new axes just aren't read
//   PAD(off, size)    in[k] = out[k] - off[k], but only VALID when
//                     off[k] <= out[k] < off[k] + n[k]; elsewhere the value
//                     is 0, not a read (tinygrad: .valid(...), a WHERE later)
//   RESHAPE           flatten out to one number over the output shape, then
//                     unflatten it over the input shape:
//                       flat  = sum of out[k] * stride_out[k]
//                       in[k] = (flat DIV stride_in[k]) MOD n_in[k]
//
// RESHAPE's expression looks awful, and simplifying it is what makes it
// fast: reshaping (2, 3) to (6) and back gives back exactly r0 and r1.
// tinygrad's comment on _apply_reshape: "this simplify is doing a lot of
// heavy lifting. this is the replacement for the reshape view merging
// code". That simplifier (symbolic, below) is 072's rules on real UOps,
// with 185's bounds: (a*c + b) DIV c = a + b DIV c, x MOD c = x when x is
// already in [0, c), and so on.
//
// YOUR TASK: the five cases of applyMovement().
//
const std = @import("std");

//@export symbolic
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
//@end

//@export movement_ranges
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
            for (in, out, offsets) |*i, o, off| i.* = ⟪try g.add(o, g.int(@intCast(off)))|||???⟫;
        },
        .permute => {
            const perm = try g.asInts(u.src[1]);
            for (perm, 0..) |axis, i| in[⟪axis|||???⟫] = out[i];
        },
        .expand => {
            const front = try g.asInts(u.src[1]);
            // (a copy: `in` is simplified in place below, and `out` is the caller's)
            in = g.alloc.dupe(*const UOp, ⟪out[front.len..]|||???⟫) catch @panic("out of memory");
        },
        .pad => {
            const offsets = try g.asInts(u.src[1]);
            for (in, out, offsets, in_shape) |*i, o, off, n| {
                const lo: i64 = @intCast(off);
                const hi: i64 = @intCast(off + n);
                i.* = try g.add(o, g.int(-lo));
                // valid where off <= o < off + n, written with CMPLT only: off - 1 < o
                const inside = try and_(g, try g.cmplt(g.int(lo - 1), o), try g.cmplt(o, g.int(hi)));
                ok = ⟪try and_(g, ok, inside)|||???⟫;
            }
        },
        .reshape => {
            // flatten over the output shape...
            var flat = g.int(0);
            for (out, 0..) |o, k| flat = try g.add(flat, try g.mul(o, g.int(@intCast(prod(u.shape[k + 1 ..])))));
            // ...and unflatten over the input's
            for (in, 0..) |*i, k| {
                const q = try g.alu(.div, &.{ flat, g.int(@intCast(prod(in_shape[k + 1 ..]))) });
                i.* = ⟪try g.alu(.mod, &.{ q, g.int(@intCast(in_shape[k])) })|||???⟫;
            }
        },
        else => unreachable,
    }
    for (in) |*i| i.* = try symbolic(g, i.*);
    return .{ .idx = in, .valid = try symbolic(g, ok) };
}
//@end

const t = std.testing;

/// Check applyMovement against the interpreter (189): for every output
/// position, y[pos] must be x[the mapped index] where valid, else 0.
fn checkAgainstInterp(g: *Graph, y: *const UOp) !void {
    std.debug.assert(y.op.isMovement());
    const x = y.src[0];
    var it = Interp.init(g);
    const xv = try it.eval(x);
    const yv = try it.eval(y);
    const ranges = g.alloc.alloc(*const UOp, y.shape.len) catch unreachable;
    for (ranges, y.shape, 0..) |*r, n, i| r.* = g.range(n, @intCast(i));
    const m = try applyMovement(g, y, ranges, g.boolean(true));
    const pos_idx = g.alloc.alloc(usize, y.shape.len) catch unreachable;
    for (yv.data, 0..) |want, pos| {
        unravel(pos, y.shape, pos_idx);
        it.varying.clearRetainingCapacity();
        for (ranges, pos_idx) |r, i| try it.loops.put(r, @intCast(i));
        const valid = (try it.eval(m.valid)).scalar() == 1;
        var got: f64 = 0;
        if (valid) {
            var flat: usize = 0;
            for (m.idx, x.shape) |e, n| {
                const i = (try it.eval(e)).scalar();
                try t.expect(i >= 0 and i < @as(f64, @floatFromInt(n)));
                flat = flat * n + @as(usize, @intFromFloat(i));
            }
            got = xv.data[flat];
        }
        try t.expectEqual(want, got);
    }
}

fn arange(g: *Graph, n: usize) *const UOp {
    const c = g.alloc.alloc(*const UOp, n) catch unreachable;
    for (c, 0..) |*u, i| u.* = g.int(@intCast(i + 1));
    return g.stack(c) catch unreachable;
}

test "each op, checked element by element" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = try g.reshape(arange(&g, 24), &.{ 2, 3, 4 });
    try checkAgainstInterp(&g, try g.shrink(x, &.{ 1, 1, 0 }, &.{ 1, 2, 3 }));
    try checkAgainstInterp(&g, try g.permute(x, &.{ 2, 0, 1 }));
    try checkAgainstInterp(&g, try g.expand(x, &.{ 2, 3 }));
    try checkAgainstInterp(&g, try g.pad(x, &.{ 1, 0, 2 }, &.{ 4, 3, 7 }));
    try checkAgainstInterp(&g, try g.reshape(x, &.{ 6, 4 }));
    try checkAgainstInterp(&g, try g.reshape(x, &.{ 4, 3, 2 }));
    try checkAgainstInterp(&g, try g.reshape(x, &.{24}));
}

test "the expressions come out clean" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = try g.reshape(arange(&g, 6), &.{ 2, 3 });
    const r0 = g.range(2, 0);
    const r1 = g.range(3, 1);
    const one = g.boolean(true);
    // permute [1 0] swaps the ranges, nothing more
    const p = try applyMovement(&g, try g.permute(x, &.{ 1, 0 }), &.{ r1, r0 }, one);
    try t.expect(p.idx[0] == r0 and p.idx[1] == r1);
    // reshape (2, 3) -> (6): r0 * 3 + r1, with no DIV or MOD left
    const flat = try applyMovement(&g, try g.reshape(x, &.{6}), &.{try g.add(try g.mul(r0, g.int(3)), r1)}, one);
    try t.expect(flat.idx[0] == r0 and flat.idx[1] == r1);
    // and (6) -> (2, 3) gives r // 3 and r % 3
    const r = g.range(6, 2);
    const back = try applyMovement(&g, try g.reshape(try g.reshape(x, &.{6}), &.{ 2, 3 }), &.{ r0, r1 }, one);
    try t.expect(back.idx[0] == try g.add(try g.mul(r0, g.int(3)), r1));
    const split = try applyMovement(&g, try g.reshape(x, &.{6}), &.{r}, one);
    try t.expect(split.idx[0] == try g.alu(.div, &.{ r, g.int(3) }));
    try t.expect(split.idx[1] == try g.alu(.mod, &.{ r, g.int(3) }));
    // expand: the new axis isn't read at all
    const e = try applyMovement(&g, try g.expand(x, &.{4}), &.{ g.range(4, 3), r0, r1 }, one);
    try t.expectEqual(2, e.idx.len);
    try t.expect(e.idx[0] == r0 and e.idx[1] == r1 and e.valid == one);
    // pad with no padding on an axis adds no condition for it
    const pd = try applyMovement(&g, try g.pad(x, &.{ 0, 1 }, &.{ 2, 5 }), &.{ r0, g.range(5, 4) }, one);
    try t.expect(pd.idx[0] == r0);
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include dtypes

//@include uop_core

//@include uop_rules

//@include alu

//@include substitute

//@include bounds

//@include uir_parse

//@include interp

//@include interp_movement
