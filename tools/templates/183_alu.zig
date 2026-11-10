//
// ─── Exercise 183: what the ALU ops compute ───────────────────────────
//
// A compiler is only right if it computes exactly what the spec says,
// down to the last bit. tinygrad defines every ALU op once, in Python, in
// tinygrad/uop/ops.py (python_alu and exec_alu). Its PYTHON device (043)
// and its constant folding both use that table, and every renderer has to
// agree with it. The parts that bite:
//
//   DIV, MOD     FLOOR division, like Python's // and %:
//                -7 DIV 2 = -4 and -7 MOD 2 = 1. C's / and % truncate
//                instead (-3 and -1); tinygrad calls those TRUNCDIV and
//                TRUNCMOD, and must turn one into the other when it renders
//                C (158). x DIV 0 is 0 (tinygrad's floordiv), and MOD is
//                defined from DIV: x MOD y = x - (x DIV y) * y. In C both
//                would be undefined.
//   i32          wraps around: 2147483647 + 1 = -2147483648. Python ints
//                never overflow, so tinygrad computes the exact answer and
//                then keeps its low 32 bits (truncate in dtype.py, c_int32).
//   f32          every result is rounded to the nearest f32 (c_float), even
//                though Python computes in f64.
//   weakint,     not truncated or rounded at all: a weak value has no width
//   weakfloat    yet (181).
//   bool         stays 0 or 1: true + true is true (an OR), true * false is
//                false (an AND).
//   RECIP        1/x, where 1/0 is inf (and 1/-0.0 is -inf), never an error.
//   CMPLT, CMPNE give a bool. WHERE(c, a, b) is a if c, else b.
//   CAST         to an int truncates toward zero, like C; to bool is x != 0.
//
// We keep every value as an f64. i32s and bools fit exactly, so one
// representation does for all of them, and the dtype says how to read it.
// Integer ops convert to i64 first, so nothing is lost on the way.
//
// YOUR TASK: floor division and modulo, the i32 wrap, and f32 rounding.
//
const std = @import("std");

//@export alu
/// Python's //, and 0 for a zero divisor. (tinygrad.helpers.floordiv)
fn floorDiv(x: i64, y: i64) i64 {
    if (y == 0) return 0;
    return ⟪@divFloor(x, y)|||???⟫;
}

/// Python's %, defined from floorDiv. (tinygrad.helpers.floormod)
fn floorMod(x: i64, y: i64) i64 {
    return ⟪x - floorDiv(x, y) * y|||???⟫;
}

/// Keep the low 32 bits, read as a signed number, like ctypes.c_int32.
fn wrapI32(x: i64) i64 {
    return ⟪@as(i32, @truncate(x))|||???⟫;
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
        .f32 => ⟪@as(f32, @floatCast(x))|||???⟫,
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
//@end

const t = std.testing;

test "floor division, not C's" {
    try t.expectEqual(-4, floorDiv(-7, 2));
    try t.expectEqual(1, floorMod(-7, 2));
    try t.expectEqual(-4, floorDiv(7, -2));
    try t.expectEqual(-1, floorMod(7, -2));
    try t.expectEqual(3, floorDiv(-7, -2));
    try t.expectEqual(-1, floorMod(-7, -2));
    try t.expectEqual(3, floorDiv(7, 2));
    try t.expectEqual(1, floorMod(7, 2));
    // the definition holds for every pair: x = (x DIV y) * y + x MOD y
    var x: i64 = -9;
    while (x <= 9) : (x += 1) {
        var y: i64 = -4;
        while (y <= 4) : (y += 1) {
            if (y == 0) continue;
            try t.expectEqual(x, floorDiv(x, y) * y + floorMod(x, y));
        }
    }
}

test "dividing by zero is 0, so x MOD 0 is x" {
    try t.expectEqual(0, floorDiv(7, 0));
    try t.expectEqual(7, floorMod(7, 0));
}

test "i32 wraps, weakint doesn't" {
    try t.expectEqual(-2147483648, execAlu(.add, .i32, &.{ 2147483647, 1 }));
    try t.expectEqual(2147483648, execAlu(.add, .weakint, &.{ 2147483647, 1 }));
    try t.expectEqual(0, execAlu(.mul, .i32, &.{ 65536, 65536 })); // 2^32
    try t.expectEqual(-2147483648, execAlu(.shl, .i32, &.{ 1, 31 }));
    try t.expectEqual(12, execAlu(.shl, .i32, &.{ 3, 2 }));
    try t.expectEqual(5, execAlu(.xor, .i32, &.{ 6, 3 }));
    try t.expectEqual(-4, execAlu(.div, .i32, &.{ -7, 2 }));
    try t.expectEqual(1, execAlu(.mod, .i32, &.{ -7, 2 }));
}

test "f32 rounds every result, weakfloat doesn't" {
    const f: f32 = 0.1;
    const g: f32 = 0.2;
    try t.expectEqual(@as(f64, f + g), execAlu(.add, .f32, &.{ f, g }));
    // (Zig would add the literals 0.1 + 0.2 exactly, at compile time: use f64 variables)
    const a: f64 = 0.1;
    const b: f64 = 0.2;
    try t.expectEqual(a + b, execAlu(.add, .weakfloat, &.{ a, b }));
    try t.expect(execAlu(.add, .f32, &.{ 0.1, 0.2 }) != execAlu(.add, .weakfloat, &.{ 0.1, 0.2 }));
}

test "bools, comparisons, where, recip" {
    try t.expectEqual(1, execAlu(.add, .bool, &.{ 1, 1 })); // true OR true
    try t.expectEqual(0, execAlu(.mul, .bool, &.{ 1, 0 })); // true AND false
    try t.expectEqual(1, execAlu(.cmplt, .bool, &.{ -1, 0 }));
    try t.expectEqual(0, execAlu(.cmplt, .bool, &.{ 0, 0 }));
    try t.expectEqual(1, execAlu(.cmpne, .bool, &.{ 2, 3 }));
    try t.expectEqual(7, execAlu(.where, .i32, &.{ 1, 7, 9 }));
    try t.expectEqual(9, execAlu(.where, .i32, &.{ 0, 7, 9 }));
    try t.expectEqual(0.25, execAlu(.recip, .f32, &.{4}));
    try t.expectEqual(std.math.inf(f64), execAlu(.recip, .f32, &.{0}));
    try t.expectEqual(-std.math.inf(f64), execAlu(.recip, .f32, &.{-0.0}));
}

test "casts" {
    try t.expectEqual(-2, castValue(-2.7, .i32)); // toward zero, like C
    try t.expectEqual(2, castValue(2.7, .i32));
    try t.expectEqual(1, castValue(0.5, .bool));
    try t.expectEqual(0, castValue(0, .bool));
    try t.expectEqual(@as(f64, @as(f32, 0.1)), castValue(0.1, .f32));
    try t.expectEqual(-2147483648, castValue(2147483648, .i32)); // wraps
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include dtypes

//@include uop_core

//@include uop_rules
