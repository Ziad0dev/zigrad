//
// ─── Exercise 049: smaller numbers ─────────────────────────────────────
//
// Chapter 10: the runtime, everything around the kernels. First: data
// types. Remember 044? Most kernels are memory-bound, so numbers that take
// HALF the bytes make them nearly twice as fast. tinygrad's dtypes
// include float16, bfloat16 and int8 for exactly this reason.
//
// An f32 is 1 sign bit, 8 exponent bits (the range) and 23 fraction bits
// (the precision). The 16-bit formats split their bits differently:
//
//     f16:  5 exponent bits, 10 fraction   precise-ish, but max ≈ 65504
//     bf16: 8 exponent bits,  7 fraction   same range as f32, less precise
//
// bf16 is literally the top half of an f32. Converting is keeping the top
// 16 bits, with rounding: add 0x7FFF, plus 1 if the kept part is odd
// ("round half to even"), then shift right by 16. Going back is just
// shifting left.
//
// int8 goes further: 1 byte per number. *Quantization* maps each float
// to an integer from -127 to 127 with a shared scale:
//
//     scale = max(|x|) / 127          q = round(x / scale)
//     x ≈ q * scale                   (off by at most scale / 2)
//
// YOUR TASK: finish the bf16 conversions and the quantizer.
//
const std = @import("std");

fn bf16FromF32(x: f32) u16 {
    const bits: u32 = @bitCast(x);
    const rounding: u32 = 0x7FFF + ((bits >> 16) & 1);
    return ???;
}

fn f32FromBf16(b: u16) f32 {
    return ???;
}

/// Quantize x into q, return the scale.
fn quantize(x: []const f32, q: []i8) f32 {
    var biggest: f32 = 0;
    for (x) |v| biggest = @max(biggest, @abs(v));
    if (biggest == 0) biggest = 1; // all zeros: any scale works
    const scale = ???;
    for (x, q) |v, *o| o.* = ???;
    return scale;
}

fn dequantize(q: []const i8, scale: f32, out: []f32) void {
    for (q, out) |v, *o| o.* = ???;
}

test "f16: precise, but small" {
    try std.testing.expectEqual(2048, @as(f16, @floatCast(@as(f32, 2049)))); // steps of 2 here
    try std.testing.expect(std.math.isInf(@as(f16, @floatCast(@as(f32, 70000)))));
}

test "bf16: the top half of an f32" {
    try std.testing.expectEqual(0x3F80, bf16FromF32(1.0));
    try std.testing.expectEqual(3.140625, f32FromBf16(bf16FromF32(3.140625))); // fits exactly
    const third = f32FromBf16(bf16FromF32(1.0 / 3.0));
    try std.testing.expectApproxEqRel(1.0 / 3.0, third, 1.0 / 256.0); // ~2-3 digits
    try std.testing.expect(!std.math.isInf(f32FromBf16(bf16FromF32(1e38)))); // f32's range
}

test "bf16 rounds to nearest" {
    // 1 + 2^-8 is exactly halfway between two bf16s: ties go to the even one (1.0)
    try std.testing.expectEqual(1.0, f32FromBf16(bf16FromF32(1.0 + 1.0 / 256.0)));
    // a bit more than halfway rounds up
    try std.testing.expectEqual(1.0 + 1.0 / 128.0, f32FromBf16(bf16FromF32(1.0 + 1.0 / 256.0 + 1.0 / 4096.0)));
}

test "int8 quantization" {
    const x = [_]f32{ 0.5, -1.27, 0.01, 1.0, -0.333 };
    var q: [5]i8 = undefined;
    const scale = quantize(&x, &q);
    try std.testing.expectApproxEqAbs(0.01, scale, 1e-7);
    try std.testing.expectEqual(-127, q[1]); // the biggest maps to ±127

    var back: [5]f32 = undefined;
    dequantize(&q, scale, &back);
    for (x, back) |orig, got| try std.testing.expect(@abs(orig - got) <= scale / 2 + 1e-6);
}
