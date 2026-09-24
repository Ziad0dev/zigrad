//
// ─── Exercise 002: floats are not real numbers ─────────────────────────
//
// Tensors are usually full of f32s: 32-bit floating point numbers. An f32
// keeps about 7 significant digits and rounds away the rest. Three
// things follow from that, and you'll meet all of them again:
//
// 1. Tiny errors creep in, so never compare floats with ==. Ask "are
//    these close enough?" instead.
//
// 2. Big numbers swallow small ones. Near 100,000,000 the gap from one
//    f32 to the next is 8, so adding 1 changes nothing at all. That means
//    the ORDER you add numbers in can change the answer. A GPU adds in a
//    different order than a CPU, which is why their results can differ in
//    the last few digits.
//
// 3. Numbers can overflow to infinity (inf), and some operations give
//    "not a number" (nan), like inf - inf. One nan poisons every result
//    it touches. Exercise 018 (softmax) is all about dodging this.
//
// YOUR TASK: write approxEq, then predict what the floats will do.
//
const std = @import("std");

/// Are a and b within `tolerance` of each other? (@abs is absolute value.)
fn approxEq(a: f32, b: f32, tolerance: f32) bool {
    return ⟪@abs(a - b) <= tolerance|||???⟫;
}

test "close enough is good enough" {
    var total: f32 = 0;
    for (0..10) |_| total += 0.1;

    try std.testing.expect(total != 1.0); // ten 0.1s are NOT exactly 1...
    try std.testing.expect(approxEq(total, 1.0, 1e-5)); // ...but close.
    try std.testing.expect(!approxEq(1.0, 1.1, 1e-5));
}

test "big numbers swallow small ones" {
    const big: f32 = 100_000_000;
    const small: f32 = 1;

    // Predict it! What is (big + small) - big, in f32?
    try std.testing.expectEqual(⟪0|||???⟫, (big + small) - big);

    // Same three numbers, added in a different order.
    const left = (big + -big) + small;
    const right = big + (-big + small);
    try std.testing.expectEqual(⟪1|||???⟫, left);
    try std.testing.expectEqual(⟪0|||???⟫, right);
}

test "infinity and not-a-number" {
    const huge = @exp(@as(f32, 100)); // e^100 is too big for an f32
    try std.testing.expect(std.math.isInf(huge));

    const broken = huge - huge; // inf - inf
    // Which std.math function checks for "not a number"?
    try std.testing.expect(std.math.⟪isNan|||???⟫(broken));
}
