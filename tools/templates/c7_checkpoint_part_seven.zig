//
// ─── Checkpoint 7: Part VII, from memory ──────────────────────────────
//
// No blanks, nothing new: six functions from all over Part VII, from
// the processor up to the network. Try each cold. If you have to look
// one up, read YOUR finished exercise (its number is in the doc
// comment), close it, and write it from memory.
//
// YOUR TASK: write encodeImm(), addWithCarry(), crc32(), translate(),
// checksum() and seqBefore().
//
const std = @import("std");

/// (214) An ARM constant is 8 bits, rotated right by an even amount.
/// The 12-bit operand for `value`: the rotate (half the amount, 0 to 15)
/// in bits 11..8 and the 8 bits in bits 7..0, taking the smallest rotate
/// that works. null if none does.
fn encodeImm(value: u32) ?u12 {
    //⟪
    for (0..16) |rotate| {
        const imm8 = std.math.rotl(u32, value, 2 * rotate);
        if (imm8 <= 0xff) return @intCast((rotate << 8) | imm8);
    }
    return null;
    //|||
    ???;
    //⟫
}

const Sum = struct { value: u32, carry: bool, overflow: bool };

/// (217) a + b + carry_in, with the two flags only an adder can know:
/// carry (the true sum didn't fit in 32 bits) and overflow (as SIGNED
/// numbers, the result has the wrong sign).
fn addWithCarry(a: u32, b: u32, carry_in: bool) Sum {
    //⟪
    const wide = @as(u64, a) + @as(u64, b) + @intFromBool(carry_in);
    const value: u32 = @truncate(wide);
    return .{
        .value = value,
        .carry = wide >> 32 != 0,
        .overflow = ((a ^ value) & (b ^ value)) >> 31 != 0,
    };
    //|||
    ???;
    //⟫
}

/// (231) CRC-32 as Ethernet computes it: the register starts at all
/// ones, bits go in low bit first, the constant is 0xedb88320, and the
/// result is the register inverted.
fn crc32(bytes: []const u8) u32 {
    //⟪
    var crc: u32 = 0xffffffff;
    for (bytes) |byte| {
        for (0..8) |k| {
            const bit_in: u32 = (byte >> @intCast(k)) & 1;
            const differs = (crc & 1) != bit_in;
            crc >>= 1;
            if (differs) crc ^= 0xedb88320;
        }
    }
    return ~crc;
    //|||
    ???;
    //⟫
}

const TlbEntry = struct { valid: bool = false, writable: bool = false, vpage: u20 = 0, ppage: u20 = 0 };

/// (234) The physical address for a virtual one, with 4096-byte pages.
/// error.TlbMiss if no valid entry has its page; error.ReadOnly for a
/// write to a page that isn't writable.
fn translate(entries: []const TlbEntry, addr: u32, write: bool) !u32 {
    //⟪
    const vpage: u20 = @intCast(addr >> 12);
    for (entries) |e| {
        if (!e.valid or e.vpage != vpage) continue;
        if (write and !e.writable) return error.ReadOnly;
        return @as(u32, e.ppage) << 12 | (addr & 0xfff);
    }
    return error.TlbMiss;
    //|||
    _ = .{ entries, addr, write };
    ???;
    //⟫
}

/// (241) The Internet checksum: the bytes added up as 16-bit big-endian
/// words (an odd last byte is a high byte), carries folded back in at
/// the bottom, and the result inverted.
fn checksum(bytes: []const u8) u16 {
    //⟪
    var total: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) total += @as(u32, bytes[i]) << 8 | bytes[i + 1];
    if (i < bytes.len) total += @as(u32, bytes[i]) << 8;
    while (total >> 16 != 0) total = (total & 0xffff) + (total >> 16);
    return ~@as(u16, @intCast(total));
    //|||
    ???;
    //⟫
}

/// (241) Is TCP sequence number a before b? They wrap around: after
/// 0xffffffff comes 0.
fn seqBefore(a: u32, b: u32) bool {
    //⟪
    return @as(i32, @bitCast(a -% b)) < 0;
    //|||
    ???;
    //⟫
}

const t = std.testing;

test "ARM constants" {
    try t.expectEqual(@as(?u12, 0x0ff), encodeImm(0xff));
    try t.expectEqual(@as(?u12, 0x000), encodeImm(0));
    try t.expectEqual(@as(?u12, 0xc01), encodeImm(0x100)); // 1, rotated right by 24
    try t.expectEqual(@as(?u12, 0x4ff), encodeImm(0xff000000));
    try t.expectEqual(@as(?u12, 0x102), encodeImm(0x80000000));
    try t.expectEqual(@as(?u12, 0x2ff), encodeImm(0xf000000f)); // the 8 bits may wrap around the ends
    try t.expectEqual(@as(?u12, null), encodeImm(0x101));
    try t.expectEqual(@as(?u12, null), encodeImm(0x1fe)); // 8 bits, but at an odd position
    try t.expectEqual(@as(?u12, null), encodeImm(0x12345678));
}

test "the adder's flags" {
    try t.expectEqual(Sum{ .value = 3, .carry = false, .overflow = false }, addWithCarry(1, 2, false));
    try t.expectEqual(Sum{ .value = 4, .carry = false, .overflow = false }, addWithCarry(1, 2, true));
    try t.expectEqual(Sum{ .value = 0, .carry = true, .overflow = false }, addWithCarry(0xffffffff, 1, false));
    try t.expectEqual(Sum{ .value = 0, .carry = true, .overflow = false }, addWithCarry(0xffffffff, 0, true));
    try t.expectEqual(Sum{ .value = 0x80000000, .carry = false, .overflow = true }, addWithCarry(0x7fffffff, 1, false));
    try t.expectEqual(Sum{ .value = 0x7fffffff, .carry = true, .overflow = true }, addWithCarry(0x80000000, 0xffffffff, false));
    try t.expectEqual(Sum{ .value = 0xfffffffe, .carry = true, .overflow = false }, addWithCarry(0xffffffff, 0xffffffff, false));
    try t.expectEqual(Sum{ .value = 0x40000000, .carry = false, .overflow = false }, addWithCarry(0x20000000, 0x20000000, false));
    try t.expectEqual(Sum{ .value = 0xffffffff, .carry = true, .overflow = false }, addWithCarry(0xffffffff, 0xffffffff, true));
}

test "CRC-32" {
    try t.expectEqual(@as(u32, 0xcbf43926), crc32("123456789"));
    try t.expectEqual(@as(u32, 0), crc32(""));
    var prng = std.Random.DefaultPrng.init(7);
    var buf: [200]u8 = undefined;
    prng.random().bytes(&buf);
    for ([_]usize{ 1, 2, 63, 200 }) |len| try t.expectEqual(std.hash.Crc32.hash(buf[0..len]), crc32(buf[0..len]));
}

test "translating an address" {
    const entries = [_]TlbEntry{
        .{ .valid = true, .vpage = 0x40001, .ppage = 0x00007 },
        .{ .valid = false, .writable = true, .vpage = 0x12345, .ppage = 0x00001 },
        .{ .valid = true, .writable = true, .vpage = 0xfffff, .ppage = 0x80009 },
    };
    try t.expectEqual(@as(u32, 0x00007a2c), try translate(&entries, 0x40001a2c, false));
    try t.expectEqual(@as(u32, 0x00007fff), try translate(&entries, 0x40001fff, false));
    try t.expectError(error.ReadOnly, translate(&entries, 0x40001a2c, true));
    try t.expectError(error.TlbMiss, translate(&entries, 0x40002000, false));
    try t.expectError(error.TlbMiss, translate(&entries, 0x12345000, false));
    try t.expectEqual(@as(u32, 0x80009ffc), try translate(&entries, 0xfffffffc, true));
    try t.expectError(error.TlbMiss, translate(&.{}, 0, false));
}

test "the Internet checksum" {
    try t.expectEqual(@as(u16, 0x220d), checksum(&.{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 }));
    try t.expectEqual(@as(u16, 0xffff), checksum(""));
    try t.expectEqual(@as(u16, 0x54ff), checksum(&.{0xab}));
    try t.expectEqual(@as(u16, 0xfffd), checksum(&.{ 0xff, 0xff, 0x00, 0x02 })); // the carry comes back in
    const header = [_]u8{ 0x45, 0x00, 0x00, 0x73, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11, 0xb8, 0x61, 0xc0, 0xa8, 0x00, 0x01, 0xc0, 0xa8, 0x00, 0xc7 };
    try t.expectEqual(@as(u16, 0), checksum(&header)); // a correct header, checksum included
}

test "before and after, on a circle" {
    try t.expect(seqBefore(1, 2));
    try t.expect(!seqBefore(2, 1));
    try t.expect(!seqBefore(5, 5));
    try t.expect(seqBefore(0xffffffff, 0));
    try t.expect(seqBefore(0xfffffff0, 0x10));
    try t.expect(!seqBefore(0x10, 0xfffffff0));
    try t.expect(seqBefore(0x7fffffff, 0x80000000));
}
