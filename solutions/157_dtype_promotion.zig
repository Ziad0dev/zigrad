// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 157: what type is a + b? ─────────────────────────────────
//
// Adding an int8 tensor to a uint8 tensor: what dtype comes out? Neither
// input type can hold every value of the other (int8 has no 200, uint8 has
// no -5), so the answer must be bigger: int16.
//
// tinygrad (like NumPy and JAX) answers such questions with a *promotion
// lattice*: a graph where an edge a -> b means "b can hold every a". The
// result type is the *least upper bound*: the smallest type reachable
// from BOTH inputs.
//
//     bool -> int8, uint8          int8 -> int16    uint8 -> int16, uint16
//     int16 -> int32               uint16 -> int32, uint32
//     int32 -> int64               uint32 -> int64, uint64
//     int64 -> float16, bfloat16   uint64 -> float16, bfloat16
//     float16 -> float32           bfloat16 -> float32     float32 -> float64
//
// (The lattice here is a simplified version of tinygrad's promo_lattice.
// The real one also has fp8 types, and "weak" types for plain Python
// numbers that sit between int64 and float16. So in tinygrad, int64 +
// uint64 gives a weak float, where ours gives float16. Note int64 ->
// float16: every int "fits" a float in range, if not in precision.
// That's the usual convention: mixing ints and floats gives a float.)
//
// YOUR TASK: collect every type reachable from a type, and pick the
// least upper bound.
//
const std = @import("std");

const DType = enum { bool, int8, uint8, int16, uint16, int32, uint32, int64, uint64, float16, bfloat16, float32, float64 };

fn parents(d: DType) []const DType {
    return switch (d) {
        .bool => &.{ .int8, .uint8 },
        .int8 => &.{.int16},
        .uint8 => &.{ .int16, .uint16 },
        .int16 => &.{.int32},
        .uint16 => &.{ .int32, .uint32 },
        .int32 => &.{.int64},
        .uint32 => &.{ .int64, .uint64 },
        .int64, .uint64 => &.{ .float16, .bfloat16 },
        .float16, .bfloat16 => &.{.float32},
        .float32 => &.{.float64},
        .float64 => &.{},
    };
}

const Set = std.EnumSet(DType);

/// d itself, and everything reachable from it.
fn upward(d: DType) Set {
    var s = Set.initOne(d);
    for (parents(d)) |p| s.setUnion(upward(p));
    return s;
}

fn promote(a: DType, b: DType) DType {
    const both = upward(a).intersectWith(upward(b));
    // the smallest: the first in the enum's order
    var it = both.iterator();
    return it.next().?;
}

test "promotion" {
    try std.testing.expectEqual(.int16, promote(.int8, .uint8));
    try std.testing.expectEqual(.int32, promote(.int16, .uint16));
    try std.testing.expectEqual(.float16, promote(.int32, .float16));
    try std.testing.expectEqual(.float32, promote(.float16, .bfloat16));
    try std.testing.expectEqual(.float32, promote(.float32, .int8));
    try std.testing.expectEqual(.bool, promote(.bool, .bool));
    try std.testing.expectEqual(.uint8, promote(.bool, .uint8));
}

test "order doesn't matter" {
    for (std.enums.values(DType)) |x| {
        for (std.enums.values(DType)) |y| try std.testing.expectEqual(promote(x, y), promote(y, x));
    }
}
