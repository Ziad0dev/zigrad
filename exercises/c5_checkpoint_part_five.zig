//
// ─── Checkpoint 5: Part V, from memory ────────────────────────────────
//
// No blanks, nothing new: the rules of Part V that a compiler gets wrong
// when its author half-remembers them. Try each cold. If you have to look
// one up, read YOUR finished exercise (its number is in the doc comment),
// close it, and write it from memory.
//
// YOUR TASK: write aluDType(), floorDiv() and floorMod(), cmpltBounds(),
// reshapeIndex() and reduceLeading().
//
const std = @import("std");

/// In promotion order: each can hold everything before it.
const DType = enum { bool, weakint, i32, weakfloat, f32 };

const Op = enum { add, mul, max, cmplt, cmpne };

/// (181, 182) The dtype of `a op b`.
fn aluDType(op: Op, a: DType, b: DType) DType {
    ???;
}

/// (183) UIR's DIV, the way tinygrad defines it, zero divisor included.
fn floorDiv(x: i64, y: i64) i64 {
    ???;
}

/// (183) UIR's MOD, the way tinygrad defines it, zero divisor included.
fn floorMod(x: i64, y: i64) i64 {
    ???;
}

/// A value known to lie in [lo, hi].
const Bounds = struct { lo: i64, hi: i64 };

/// (185) The bounds of `a < b` as a number: 1 for true, 0 for false.
fn cmpltBounds(a: Bounds, b: Bounds) Bounds {
    ???;
}

/// (191) Rangeify's RESHAPE: the output of a reshape is read at index
/// `out` (one entry per axis of out_shape). Which index of its input
/// (of shape in_shape) is that? Write it into `in`.
fn reshapeIndex(out: []const usize, out_shape: []const usize, in_shape: []const usize, in: []usize) void {
    ???;
}

fn prod(shape: []const usize) usize {
    var p: usize = 1;
    for (shape) |n| p *= n;
    return p;
}

/// (182, 189) REDUCE with op=add: sum away the `pop` LEADING axes of x
/// (row-major, of shape `shape`) into `out`, which has the shape that is
/// left.
fn reduceLeading(x: []const f64, shape: []const usize, pop: usize, out: []f64) void {
    ???;
}

const t = std.testing;

test "dtypes of ALU ops" {
    try t.expectEqual(.i32, aluDType(.add, .i32, .weakint)); //       i32 + 1
    try t.expectEqual(.i32, aluDType(.mul, .weakint, .i32)); //       2 * i32
    try t.expectEqual(.weakint, aluDType(.add, .weakint, .weakint)); // 1 + 2 is still weak
    try t.expectEqual(.weakfloat, aluDType(.max, .i32, .weakfloat)); // an int meets 0.5
    try t.expectEqual(.f32, aluDType(.add, .weakfloat, .f32));
    try t.expectEqual(.weakint, aluDType(.add, .bool, .weakint)); //   true + 1
    try t.expectEqual(.bool, aluDType(.mul, .bool, .bool)); //         AND
    try t.expectEqual(.bool, aluDType(.cmplt, .f32, .weakint)); //     comparisons give bool
    try t.expectEqual(.bool, aluDType(.cmpne, .i32, .i32));
}

test "floor division and modulo" {
    try t.expectEqual(-4, floorDiv(-7, 2));
    try t.expectEqual(1, floorMod(-7, 2));
    try t.expectEqual(-4, floorDiv(7, -2));
    try t.expectEqual(-1, floorMod(7, -2));
    try t.expectEqual(3, floorDiv(-7, -2));
    try t.expectEqual(-1, floorMod(-7, -2));
    try t.expectEqual(3, floorDiv(7, 2));
    try t.expectEqual(-3, floorDiv(-6, 2)); // exact: nothing to round
    try t.expectEqual(0, floorMod(-6, 2));
    try t.expectEqual(0, floorDiv(7, 0));
    try t.expectEqual(7, floorMod(7, 0));
}

test "what a comparison can be" {
    const r: Bounds = .{ .lo = 0, .hi = 3 };
    const always: Bounds = .{ .lo = 1, .hi = 1 };
    const never: Bounds = .{ .lo = 0, .hi = 0 };
    const maybe: Bounds = .{ .lo = 0, .hi = 1 };
    try t.expectEqual(always, cmpltBounds(r, .{ .lo = 4, .hi = 4 })); // 0..3 < 4
    try t.expectEqual(maybe, cmpltBounds(r, .{ .lo = 3, .hi = 3 })); //  3 < 3 fails
    try t.expectEqual(never, cmpltBounds(r, .{ .lo = 0, .hi = 0 })); //  nothing in 0..3 is < 0
    try t.expectEqual(never, cmpltBounds(.{ .lo = 3, .hi = 6 }, r)); //  3..6 < 0..3: 3 < 3 fails too
    try t.expectEqual(maybe, cmpltBounds(.{ .lo = 2, .hi = 6 }, r)); //  2 < 3
    try t.expectEqual(maybe, cmpltBounds(r, r));
    try t.expectEqual(always, cmpltBounds(r, .{ .lo = 4, .hi = 7 }));
}

test "a reshape, as index maths" {
    var in: [3]usize = undefined;
    // (2, 3) viewed as (6): flat 4 is row 1, column 1
    reshapeIndex(&.{4}, &.{6}, &.{ 2, 3 }, in[0..2]);
    try t.expectEqualSlices(usize, &.{ 1, 1 }, in[0..2]);
    // (6) viewed as (2, 3): [1, 2] is flat 5
    reshapeIndex(&.{ 1, 2 }, &.{ 2, 3 }, &.{6}, in[0..1]);
    try t.expectEqual(5, in[0]);
    // (2, 3, 4) viewed as (4, 6): [3, 1] is flat 19 = 1 * 12 + 1 * 4 + 3
    reshapeIndex(&.{ 3, 1 }, &.{ 4, 6 }, &.{ 2, 3, 4 }, &in);
    try t.expectEqualSlices(usize, &.{ 1, 1, 3 }, &in);
    // every position of (3, 4) -> (2, 6) lands on the same flat position
    for (0..2) |a| for (0..6) |b| {
        reshapeIndex(&.{ a, b }, &.{ 2, 6 }, &.{ 3, 4 }, in[0..2]);
        try t.expectEqual(a * 6 + b, in[0] * 4 + in[1]);
        try t.expect(in[1] < 4);
    };
}

test "REDUCE pops leading axes" {
    // (2, 3): rows [1 2 3] and [4 5 6]
    const x = [_]f64{ 1, 2, 3, 4, 5, 6 };
    var out: [6]f64 = @splat(99);
    reduceLeading(&x, &.{ 2, 3 }, 1, &out);
    try t.expectEqualSlices(f64, &.{ 5, 7, 9 }, out[0..3]); // the 2 went, the 3 stayed
    reduceLeading(&x, &.{ 2, 3 }, 2, &out);
    try t.expectEqual(21, out[0]);
    reduceLeading(&x, &.{ 2, 3 }, 0, &out);
    try t.expectEqualSlices(f64, &x, &out); // nothing popped, nothing summed
    // (3, 2, 1), pop 2: everything into the one element left
    reduceLeading(&x, &.{ 3, 2, 1 }, 2, &out);
    try t.expectEqual(21, out[0]);
    // (3, 2), pop 1: columns of [1 2], [3 4], [5 6]
    reduceLeading(&x, &.{ 3, 2 }, 1, &out);
    try t.expectEqualSlices(f64, &.{ 9, 12 }, out[0..2]);
}
