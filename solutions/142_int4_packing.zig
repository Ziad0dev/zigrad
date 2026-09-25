// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 142: packing 4-bit numbers ───────────────────────────────
//
// Go further: 4 bits per weight, 16 possible values (-8 to 7). A 70B
// model shrinks from 140 GB (f16) to about 35 GB. That's how big LLMs run
// on a single consumer GPU.
//
// Memory is addressed in bytes, so two 4-bit values ("nibbles") share one
// byte: the first in the low 4 bits, the second in the high 4 bits.
//
//     pack(3, -2):   3 = 0011,  -2 = 1110 (two's complement, 4 bits)
//                    byte = 1110 0011 = 0xE3
//
// Unpacking needs *sign extension*: the 4-bit pattern 1110 means -2, but
// as the low bits of a larger number it would read as 14. Shift the
// nibble to the TOP of an i8 (left by 4), then do an arithmetic shift
// right by 4: the sign bit is copied back down.
//
// Kernels unpack on the fly, inside the matmul, so the full-size weights
// never exist in memory.
//
// YOUR TASK: pack and unpack.
//
const std = @import("std");

fn pack(lo: i4, hi: i4) u8 {
    const l: u8 = @as(u4, @bitCast(lo));
    const h: u8 = @as(u4, @bitCast(hi));
    return l | (h << 4);
}

fn unpackLo(byte: u8) i8 {
    const shifted: i8 = @bitCast(byte << 4); // low nibble moved to the top
    return shifted >> 4; // arithmetic shift: sign bits come back down
}

fn unpackHi(byte: u8) i8 {
    return @as(i8, @bitCast(byte)) >> 4;
}

test "pack 3 and -2" {
    try std.testing.expectEqual(0xE3, pack(3, -2));
    try std.testing.expectEqual(3, unpackLo(0xE3));
    try std.testing.expectEqual(-2, unpackHi(0xE3));
}

test "every pair round-trips" {
    var lo: i8 = -8;
    while (lo <= 7) : (lo += 1) {
        var hi: i8 = -8;
        while (hi <= 7) : (hi += 1) {
            const b = pack(@intCast(lo), @intCast(hi));
            try std.testing.expectEqual(lo, unpackLo(b));
            try std.testing.expectEqual(hi, unpackHi(b));
        }
    }
}
