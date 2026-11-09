//
// Part V: tinygrad as it is today, and as George Hotz's 10-411
// (Compilers for Machine Learning, Carnegie Mellon) builds it. Parts I-IV
// taught the ideas with small made-up IRs. Part V uses the real ones:
// tinygrad's UOp with its real op names, its text format (UIR), the
// rangeify scheduler, and its code generator. Each exercise names the
// tinygrad file it mirrors, checked against tinygrad master in November
// 2026. These exercises build on each other more than the earlier ones:
// each uses the finished code of the ones before it.
//
// ─── Exercise 181: weak types ─────────────────────────────────────────
//
// Chapter 35: the UOp. Every UOp has a dtype. 10-411 starts with four:
// void (no value: a STORE, a SINK), bool, i32 and f32. tinygrad adds two
// more, and they matter the moment you write `x + 1`:
//
//     weakint      the type of a bare integer literal, like 1
//     weakfloat    the type of a bare float literal, like 0.5
//
// A weak literal has no width of its own. It adopts the type of whatever
// it meets: an i32 plus 1 is an i32, not an i64, and not an error. Only
// when a weak value has to be stored somewhere is it *committed* to a
// real type: weakint to i32, weakfloat to f32, tinygrad's defaults.
//
// Which type wins in a + b? tinygrad's promo_lattice (tinygrad/dtype.py)
// is a graph where an arrow a -> b means "b can hold every a" (157). The
// result is the *least upper bound*: the lowest type both can reach. For
// our six types the lattice is a single chain,
//
//     bool -> weakint -> i32 -> weakfloat -> f32
//
// so the least upper bound is just the later of the two. Consequences
// worth knowing by heart:
//
//     i32 + 1       -> i32         the literal adopts i32
//     1 + 2         -> weakint     still weak: nothing has fixed a width
//     i32 + 0.5     -> weakfloat   an int meets a float: a float, still weak
//     true + 1      -> weakint     bool is the bottom of the lattice
//     f32 < 2       -> bool        comparisons always give bool
//     recip(i32)    -> f32         float-only ops need a float...
//     recip(1)      -> weakfloat   ...and a weak int becomes a weak float
//
// The last two are tinygrad's least_upper_float. (Its commit is smarter
// than ours, too: commit_int picks i64 when a value can't fit an i32.)
//
// YOUR TASK: the dtype of a literal, the least upper bound, commit, and
// leastUpperFloat().
//
const std = @import("std");

//@export dtypes
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
        .int => ⟪.weakint|||???⟫,
        .float => ⟪.weakfloat|||???⟫,
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
    return ⟪if (rank(a) >= rank(b)) a else b|||???⟫;
}

/// The dtype a value gets when it has to be stored. tinygrad: strong_dtype.
fn commit(d: DType) DType {
    return switch (d) {
        .weakint => ⟪.i32|||???⟫,
        .weakfloat => ⟪.f32|||???⟫,
        else => d,
    };
}

/// Float-only ops (RECIP, EXP2, ...) need a float. tinygrad: least_upper_float.
fn leastUpperFloat(d: DType) DType {
    if (d == .weakint) return .weakfloat;
    if (d.isFloat()) return d;
    return ⟪lub(d, .f32)|||???⟫;
}
//@end

const t = std.testing;

test "literals are weak" {
    try t.expectEqual(.weakint, literalDType(.{ .int = 1 }));
    try t.expectEqual(.weakfloat, literalDType(.{ .float = 0.5 }));
    try t.expectEqual(.bool, literalDType(.{ .boolean = true }));
}

test "the least upper bound" {
    try t.expectEqual(.i32, lub(.i32, .weakint)); //          i32 + 1
    try t.expectEqual(.i32, lub(.weakint, .i32)); //          1 + i32
    try t.expectEqual(.weakint, lub(.weakint, .weakint)); //  1 + 2
    try t.expectEqual(.weakfloat, lub(.i32, .weakfloat)); //  i32 + 0.5
    try t.expectEqual(.f32, lub(.weakfloat, .f32)); //        0.5 + f32
    try t.expectEqual(.f32, lub(.i32, .f32));
    try t.expectEqual(.weakint, lub(.bool, .weakint)); //     true + 1
    try t.expectEqual(.bool, lub(.bool, .bool));
}

test "lub is an upper bound, the same either way round" {
    const all = [_]DType{ .bool, .weakint, .i32, .weakfloat, .f32 };
    for (all) |a| {
        try t.expectEqual(a, lub(a, a));
        for (all) |b| {
            try t.expectEqual(lub(a, b), lub(b, a));
            try t.expect(rank(lub(a, b)) >= rank(a) and rank(lub(a, b)) >= rank(b));
        }
    }
}

test "commit only touches weak types" {
    try t.expectEqual(.i32, commit(.weakint));
    try t.expectEqual(.f32, commit(.weakfloat));
    for ([_]DType{ .void, .bool, .i32, .f32 }) |d| try t.expectEqual(d, commit(d));
}

test "float-only ops" {
    try t.expectEqual(.weakfloat, leastUpperFloat(.weakint)); // recip(1)
    try t.expectEqual(.f32, leastUpperFloat(.i32)); //           recip(i32)
    try t.expectEqual(.f32, leastUpperFloat(.bool));
    try t.expectEqual(.weakfloat, leastUpperFloat(.weakfloat));
    try t.expectEqual(.f32, leastUpperFloat(.f32));
}

test "a whole expression: i32 * 2 + 0.5, then stored" {
    const x: DType = .i32;
    const times_two = lub(x, literalDType(.{ .int = 2 }));
    try t.expectEqual(.i32, times_two);
    const plus_half = lub(times_two, literalDType(.{ .float = 0.5 }));
    try t.expectEqual(.weakfloat, plus_half);
    try t.expectEqual(.f32, commit(plus_half));
}
