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

//@export bounds
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
        .range => return ⟪.{ 0, @floatFromInt(u.src[0].intValue().? - 1) }|||???⟫,
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
            return ⟪.{ @min(a[0], b[0]), @max(a[1], b[1]) }|||???⟫;
        },
        .cmplt => {
            const a = bounds(u.src[0]);
            const b = bounds(u.src[1]);
            if (⟪a[1] < b[0]|||???⟫) return .{ 1, 1 }; // always true
            if (⟪a[0] >= b[1]|||???⟫) return .{ 0, 0 }; // never true
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
        if (⟪b[0] < 0 or b[1] > n - 1|||???⟫) return g.fail("an INDEX can go out of bounds");
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
//@end

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

//@include dtypes

//@include uop_core

//@include uop_rules

//@include alu

//@include substitute
