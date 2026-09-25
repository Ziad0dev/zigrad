//
// ─── Exercise 158: strength reduction ──────────────────────────────────
//
// Integer division and modulo are SLOW on most chips (tens of cycles),
// and index maths is full of them (071-073). But dividing by a power of
// two is just a shift:
//
//     x * 2^k   ->  x << k
//     x / 2^k   ->  x >> k          only if x >= 0 (see below)
//     x % 2^k   ->  x & (2^k - 1)   only if x >= 0
//
// Replacing an expensive op with a cheap equivalent is called *strength
// reduction*. tinygrad does it with rewrite rules (025, 156) in its late
// passes.
//
// The "x >= 0" matters because C, like the other languages tinygrad
// renders (042), divides by TRUNCATING toward zero: -7 / 2 = -3, but
// -7 >> 1 = -4. For non-negative x they agree, and the range analysis of
// 071 can often prove x >= 0 (loop variables start at 0). When it can't,
// a fix-up works for any sign: (x + (x < 0 ? 2^k - 1 : 0)) >> k, which is
// the rule tinygrad uses. Its rules go further, too: for x >= 0, division
// by ANY constant becomes a multiply and a shift (the "magic number" trick
// from Hacker's Delight, chapter 10). Here we keep to the simple case.
//
// A number c is a power of two if c > 0 and c & (c - 1) == 0 (a single 1
// bit), and k is then its count of trailing zeros (@ctz).
//
// YOUR TASK: the power-of-two test, and the three rewrites.
//
const std = @import("std");

const Op = enum { mul, div, mod, shl, shr, band };

/// x OP c, where x is a variable with range [lo, hi] and c a constant.
const Expr = struct { op: Op, c: i64, lo: i64, hi: i64 };

fn eval(e: Expr, x: i64) i64 {
    return switch (e.op) {
        .mul => x * e.c,
        .div => @divTrunc(x, e.c), // C semantics
        .mod => @rem(x, e.c), //      C semantics
        .shl => x << @intCast(e.c),
        .shr => x >> @intCast(e.c),
        .band => x & e.c,
    };
}

fn isPow2(c: i64) bool {
    return ???;
}

fn reduce(e: Expr) Expr {
    if (!isPow2(e.c)) return e;
    const k: i64 = @ctz(e.c);
    return switch (e.op) {
        .mul => .{ .op = .shl, .c = ???, .lo = e.lo, .hi = e.hi },
        .div => if (???) .{ .op = .shr, .c = k, .lo = e.lo, .hi = e.hi } else e,
        .mod => if (e.lo >= 0) .{ .op = .band, .c = ???, .lo = e.lo, .hi = e.hi } else e,
        else => e,
    };
}

fn sameEverywhere(a: Expr, b: Expr) bool {
    var x = a.lo;
    while (x <= a.hi) : (x += 1) {
        if (eval(a, x) != eval(b, x)) return false;
    }
    return true;
}

test "powers of two" {
    try std.testing.expect(isPow2(1) and isPow2(8) and isPow2(1024));
    try std.testing.expect(!isPow2(0) and !isPow2(6) and !isPow2(-8));
}

test "the rewrites are exact for x >= 0" {
    for ([_]Op{ .mul, .div, .mod }) |op| {
        const e: Expr = .{ .op = op, .c = 8, .lo = 0, .hi = 200 };
        const r = reduce(e);
        try std.testing.expect(r.op != op); // it was rewritten
        try std.testing.expect(sameEverywhere(e, r));
    }
}

test "negative x: division is left alone, because a shift would be wrong" {
    const e: Expr = .{ .op = .div, .c = 2, .lo = -10, .hi = 10 };
    try std.testing.expectEqual(.div, reduce(e).op);
    // proof that it had to be: -7 / 2 = -3 in C, but -7 >> 1 = -4
    try std.testing.expect(!sameEverywhere(e, .{ .op = .shr, .c = 1, .lo = -10, .hi = 10 }));
    // multiplication is fine for any sign
    try std.testing.expectEqual(.shl, reduce(.{ .op = .mul, .c = 4, .lo = -10, .hi = 10 }).op);
}
