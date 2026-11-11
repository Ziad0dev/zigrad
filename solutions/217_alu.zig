// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 217: the arithmetic of a processor ──────────────────────
//
// Before a processor in gates, a processor in Zig: an *emulator*, a
// program that does to an array of 16 numbers exactly what the chip
// does to its registers. It is the specification. When the Verilog CPU
// arrives (219–222), "correct" will mean "does what the emulator does",
// instruction for instruction, which is how real processors are verified.
//
// This exercise is the part with no memory in it: given two numbers and
// an operation, what comes out, and what happens to the four *flags*?
//
//   N  negative   bit 31 of the result
//   Z  zero       the result is 0
//   C  carry      an addition carried out of bit 31 (unsigned overflow)
//   V  overflow   the SIGNED result is wrong: two positives gave a
//                 negative, or two negatives a positive
//
// ONE circuit, the adder, does all the arithmetic, because of two's
// complement: -b is ~b + 1. So
//
//     a + b      = add(a,  b, carry in 0)
//     a - b      = add(a, ~b, carry in 1)
//     a + b + C  = add(a,  b, carry in C)     adc: the carry from a lower
//     a - b - !C = add(a, ~b, carry in C)     word, for 64-bit maths
//
// That makes C after a subtraction mean "NO borrow": after `cmp a, b`,
// C is set exactly when a >= b as unsigned numbers. V has a neat test:
// the result's sign differs from the sign of BOTH inputs.
//
// The flags exist for the conditions. Every ARM instruction carries one
// in its top four bits, and does nothing unless it holds:
//
//   eq Z        ne !Z       cs C         cc !C       unsigned >=, <
//   mi N        pl !N       vs V         vc !V
//   hi C and !Z             ls !C or Z               unsigned >, <=
//   ge N == V   lt N != V                            signed >=, <
//   gt !Z and N == V        le Z or N != V           signed >, <=
//   al always
//
// Why is signed "less than" N != V? After cmp, a < b means a - b is
// negative, so N... unless the subtraction overflowed, and then the sign
// is exactly backwards.
//
// The second operand passes through the *barrel shifter* first. It can
// shift by any amount in one step, and its last bit shifted out becomes
// the carry for the logical operations (and, orr, mov, ...), which have
// no carry of their own.
//
// YOUR TASK: the adder's flags, subtraction, the conditions, the shifter.
//
const std = @import("std");

const Flags = struct { n: bool = false, z: bool = false, c: bool = false, v: bool = false };

const Sum = struct { value: u32, carry: bool, overflow: bool };

/// a + b + carry_in, with the two flags only an adder can know.
fn addWithCarry(a: u32, b: u32, carry_in: bool) Sum {
    const wide = @as(u64, a) + @as(u64, b) + @intFromBool(carry_in);
    const value: u32 = @truncate(wide);
    return .{
        .value = value,
        // did the true sum need a 33rd bit?
        .carry = wide >> 32 != 0,
        // does the result's sign differ from a's AND from b's?
        .overflow = ((a ^ value) & (b ^ value)) >> 31 != 0,
    };
}

/// Does an instruction with this condition run, given the flags?
fn condPasses(cond: Cond, f: Flags) bool {
    return switch (cond) {
        .eq => f.z,
        .ne => !f.z,
        .cs => f.c,
        .cc => !f.c,
        .mi => f.n,
        .pl => !f.n,
        .vs => f.v,
        .vc => !f.v,
        .hi => f.c and !f.z,
        .ls => !f.c or f.z,
        .ge => f.n == f.v,
        .lt => f.n != f.v,
        .gt => !f.z and f.n == f.v,
        .le => f.z or f.n != f.v,
        .al => true,
    };
}

const Shifted = struct { value: u32, carry: bool };

/// The barrel shifter, for any amount from 0 to 255. The carry out is
/// the last bit that fell off the end. An amount of 0 changes nothing,
/// not even the carry.
fn barrelShift(kind: Shift, value: u32, amount: u32, carry_in: bool) Shifted {
    if (amount == 0) return .{ .value = value, .carry = carry_in };
    const sign = value >> 31 != 0;
    switch (kind) {
        .lsl => {
            if (amount > 32) return .{ .value = 0, .carry = false };
            // the last bit out is bit (32 - amount)
            const carry = (value >> @intCast(32 - amount)) & 1 != 0;
            return .{ .value = if (amount == 32) 0 else value << @intCast(amount), .carry = carry };
        },
        .lsr => {
            if (amount > 32) return .{ .value = 0, .carry = false };
            // the last bit out is bit (amount - 1)
            const carry = (value >> @intCast(amount - 1)) & 1 != 0;
            return .{ .value = if (amount == 32) 0 else value >> @intCast(amount), .carry = carry };
        },
        .asr => {
            // an ARITHMETIC shift right copies the sign bit in from the left,
            // so that -8 asr 1 is -4. Past 31 places, only sign bits are left.
            if (amount >= 32) return .{ .value = if (sign) 0xffffffff else 0, .carry = sign };
            const signed: i32 = @bitCast(value);
            return .{ .value = @bitCast(signed >> @intCast(amount)), .carry = (value >> @intCast(amount - 1)) & 1 != 0 };
        },
        .ror => {
            // a ROTATE puts the bits that fall off back in at the top
            const out = std.math.rotr(u32, value, amount % 32);
            return .{ .value = out, .carry = out >> 31 != 0 };
        },
    }
}

/// How the 5-bit shift amount of an instruction is meant (215's
/// shiftAmount(), backwards): for lsr and asr, 0 means 32. And `ror #0`
/// is a different shift altogether, "rotate right extended": one place,
/// through the carry flag, which makes a 33-bit rotation.
fn shiftByImmediate(kind: Shift, value: u32, amount: u5, carry_in: bool) Shifted {
    return switch (kind) {
        .lsl => barrelShift(.lsl, value, amount, carry_in),
        .lsr, .asr => barrelShift(kind, value, if (amount == 0) 32 else amount, carry_in),
        .ror => if (amount == 0)
            .{ .value = @as(u32, @intFromBool(carry_in)) << 31 | value >> 1, .carry = value & 1 != 0 }
        else
            barrelShift(.ror, value, amount, carry_in),
    };
}

const AluResult = struct {
    value: u32,
    /// The flags, if the instruction has its S bit.
    flags: Flags,
    /// false for tst, teq, cmp, cmn: they only set flags.
    writes: bool,
};

/// One data-processing operation: a <op> b. `flags` are the flags before,
/// and `shifter_carry` is the carry out of the barrel shifter that made b.
fn alu(op: Op, a: u32, b: u32, flags: Flags, shifter_carry: bool) AluResult {
    const sum: ?Sum = switch (op) {
        .add, .cmn => addWithCarry(a, b, false),
        .adc => addWithCarry(a, b, flags.c),
        .sub, .cmp => addWithCarry(a, ~b, true),
        .sbc => addWithCarry(a, ~b, flags.c),
        .rsb => addWithCarry(b, ~a, true), // "reverse subtract": b - a
        .rsc => addWithCarry(b, ~a, flags.c),
        else => null,
    };
    const writes = switch (op) {
        .tst, .teq, .cmp, .cmn => false,
        else => true,
    };
    if (sum) |s| {
        return .{ .value = s.value, .writes = writes, .flags = .{ .n = s.value >> 31 != 0, .z = s.value == 0, .c = s.carry, .v = s.overflow } };
    }
    const value = switch (op) {
        .@"and", .tst => a & b,
        .eor, .teq => a ^ b,
        .orr => a | b,
        .mov => b,
        .bic => a & ~b, // "bit clear"
        .mvn => ~b,
        else => unreachable,
    };
    // A logical operation: N and Z from the result, C from the shifter, V untouched.
    return .{ .value = value, .writes = writes, .flags = .{ .n = value >> 31 != 0, .z = value == 0, .c = shifter_carry, .v = flags.v } };
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "the adder's carry and overflow" {
    var s = addWithCarry(1, 2, false);
    try expect(s.value == 3 and !s.carry and !s.overflow);
    s = addWithCarry(0xffffffff, 1, false); // unsigned: wraps. signed: -1 + 1 = 0, fine
    try expect(s.value == 0 and s.carry and !s.overflow);
    s = addWithCarry(0x7fffffff, 1, false); // the biggest positive, plus one
    try expect(s.value == 0x80000000 and !s.carry and s.overflow);
    s = addWithCarry(0x80000000, 0x80000000, false); // two big negatives
    try expect(s.value == 0 and s.carry and s.overflow);
    s = addWithCarry(0xffffffff, 0xffffffff, true);
    try expect(s.value == 0xffffffff and s.carry and !s.overflow);
    s = addWithCarry(0x7fffffff, 0, true);
    try expect(s.value == 0x80000000 and s.overflow);
}

test "arithmetic against Zig's own" {
    var prng = std.Random.DefaultPrng.init(217);
    const rand = prng.random();
    const interesting = [_]u32{ 0, 1, 2, 0x7fffffff, 0x80000000, 0x80000001, 0xfffffffe, 0xffffffff };
    for (0..4000) |i| {
        const a = if (i % 3 == 0) interesting[rand.uintLessThan(usize, interesting.len)] else rand.int(u32);
        const b = if (i % 5 == 0) interesting[rand.uintLessThan(usize, interesting.len)] else rand.int(u32);
        const sa: i32 = @bitCast(a);
        const sb: i32 = @bitCast(b);
        const before: Flags = .{ .c = rand.boolean(), .v = rand.boolean() };

        const add = alu(.add, a, b, before, false);
        try expectEqual(a +% b, add.value);
        try expectEqual(@addWithOverflow(a, b)[1] == 1, add.flags.c);
        try expectEqual(@addWithOverflow(sa, sb)[1] == 1, add.flags.v);

        const sub = alu(.sub, a, b, before, false);
        try expectEqual(a -% b, sub.value);
        try expectEqual(a >= b, sub.flags.c); // carry = no borrow
        try expectEqual(@subWithOverflow(sa, sb)[1] == 1, sub.flags.v);
        try expectEqual(a == b, sub.flags.z);
        try expectEqual((a -% b) >> 31 == 1, sub.flags.n);

        try expectEqual(b -% a, alu(.rsb, a, b, before, false).value);
        const carry: u32 = @intFromBool(before.c);
        try expectEqual(a +% b +% carry, alu(.adc, a, b, before, false).value);
        try expectEqual(a -% b -% (1 - carry), alu(.sbc, a, b, before, false).value);
        try expectEqual(b -% a -% (1 - carry), alu(.rsc, a, b, before, false).value);

        // after cmp, every condition means what its name says
        const cmp = alu(.cmp, a, b, before, false);
        try expect(!cmp.writes);
        try expectEqual(a == b, condPasses(.eq, cmp.flags));
        try expectEqual(a != b, condPasses(.ne, cmp.flags));
        try expectEqual(a >= b, condPasses(.cs, cmp.flags));
        try expectEqual(a < b, condPasses(.cc, cmp.flags));
        try expectEqual(a > b, condPasses(.hi, cmp.flags));
        try expectEqual(a <= b, condPasses(.ls, cmp.flags));
        try expectEqual(sa >= sb, condPasses(.ge, cmp.flags));
        try expectEqual(sa < sb, condPasses(.lt, cmp.flags));
        try expectEqual(sa > sb, condPasses(.gt, cmp.flags));
        try expectEqual(sa <= sb, condPasses(.le, cmp.flags));
        try expect(condPasses(.al, cmp.flags));
    }
}

test "logical operations take their carry from the shifter" {
    const before: Flags = .{ .c = true, .v = true };
    var r = alu(.@"and", 0xf0f0, 0xff00, before, false);
    try expect(r.value == 0xf000 and !r.flags.c and r.flags.v and !r.flags.z and !r.flags.n);
    r = alu(.orr, 0xf0f0, 0x0f0f, before, true);
    try expect(r.value == 0xffff and r.flags.c);
    r = alu(.eor, 0xff, 0xff, before, true);
    try expect(r.value == 0 and r.flags.z);
    r = alu(.bic, 0xff, 0x0f, before, true);
    try expect(r.value == 0xf0);
    r = alu(.mvn, 123, 0, before, true);
    try expect(r.value == 0xffffffff and r.flags.n and r.writes);
    r = alu(.mov, 123, 7, before, true);
    try expect(r.value == 7);
    try expect(!alu(.tst, 1, 1, before, true).writes);
    try expect(alu(.teq, 5, 5, before, true).flags.z);
    try expect(condPasses(.mi, .{ .n = true }) and !condPasses(.pl, .{ .n = true }));
    try expect(condPasses(.vs, .{ .v = true }) and !condPasses(.vc, .{ .v = true }));
}

test "the barrel shifter" {
    const x: u32 = 0x80000003;
    try expectEqual(Shifted{ .value = x, .carry = true }, barrelShift(.lsl, x, 0, true)); // untouched
    try expectEqual(Shifted{ .value = 6, .carry = true }, barrelShift(.lsl, x, 1, false));
    try expectEqual(Shifted{ .value = 0x80000000, .carry = true }, barrelShift(.lsl, x, 31, false));
    try expectEqual(Shifted{ .value = 0, .carry = true }, barrelShift(.lsl, x, 32, false)); // bit 0 was last out
    try expectEqual(Shifted{ .value = 0, .carry = false }, barrelShift(.lsl, x, 33, true));
    try expectEqual(Shifted{ .value = 0x40000001, .carry = true }, barrelShift(.lsr, x, 1, false));
    try expectEqual(Shifted{ .value = 0x20000000, .carry = true }, barrelShift(.lsr, x, 2, false));
    try expectEqual(Shifted{ .value = 0x10000000, .carry = false }, barrelShift(.lsr, x, 3, true));
    try expectEqual(Shifted{ .value = 0, .carry = true }, barrelShift(.lsr, x, 32, false));
    try expectEqual(Shifted{ .value = 0, .carry = false }, barrelShift(.lsr, x, 200, true));
    try expectEqual(Shifted{ .value = 0xc0000001, .carry = true }, barrelShift(.asr, x, 1, false));
    try expectEqual(Shifted{ .value = 0xffffffff, .carry = true }, barrelShift(.asr, x, 32, false));
    try expectEqual(Shifted{ .value = 0xffffffff, .carry = true }, barrelShift(.asr, x, 99, false));
    try expectEqual(Shifted{ .value = 0, .carry = false }, barrelShift(.asr, 0x7fffffff, 40, true));
    try expectEqual(Shifted{ .value = 0x3fffffff, .carry = true }, barrelShift(.asr, 0x7fffffff, 1, false));
    try expectEqual(Shifted{ .value = 0xc0000001, .carry = true }, barrelShift(.ror, x, 1, false));
    try expectEqual(Shifted{ .value = 0x38000000, .carry = false }, barrelShift(.ror, x, 4, true));
    try expectEqual(Shifted{ .value = x, .carry = true }, barrelShift(.ror, x, 32, false));
    try expectEqual(Shifted{ .value = 0x38000000, .carry = false }, barrelShift(.ror, x, 36, true));
    // -8 >> 1 is -4 only with an arithmetic shift
    try expectEqual(@as(u32, @bitCast(@as(i32, -4))), barrelShift(.asr, @bitCast(@as(i32, -8)), 1, false).value);
}

test "shift amounts as instructions store them" {
    const x: u32 = 0x80000003;
    try expectEqual(Shifted{ .value = x, .carry = false }, shiftByImmediate(.lsl, x, 0, false));
    try expectEqual(Shifted{ .value = 0, .carry = true }, shiftByImmediate(.lsr, x, 0, false)); // lsr #32
    try expectEqual(Shifted{ .value = 0xffffffff, .carry = true }, shiftByImmediate(.asr, x, 0, false)); // asr #32
    try expectEqual(Shifted{ .value = 0x40000001, .carry = true }, shiftByImmediate(.ror, x, 0, false)); // rrx
    try expectEqual(Shifted{ .value = 0xc0000001, .carry = true }, shiftByImmediate(.ror, x, 0, true));
    try expectEqual(Shifted{ .value = 0x38000000, .carry = false }, shiftByImmediate(.ror, x, 4, true));
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

const Cond = enum(u4) { eq, ne, cs, cc, mi, pl, vs, vc, hi, ls, ge, lt, gt, le, al };
const Op = enum(u4) { @"and", eor, sub, rsb, add, adc, sbc, rsc, tst, teq, cmp, cmn, orr, mov, bic, mvn };
const Shift = enum(u2) { lsl, lsr, asr, ror };
const SP: u4 = 13;
const LR: u4 = 14;
const PC: u4 = 15;

/// The 12-bit operand for the constant `value`: rotate in bits 11..8,
/// imm8 in bits 7..0. null if no rotation works. imm8 rotated RIGHT by
/// 2 * rotate gives the value, so the value rotated LEFT by that much is
/// imm8: try each rotate from 0 up, and take the first that fits in 8 bits.
fn encodeImm(value: u32) ?u12 {
    for (0..16) |rotate| {
        const imm8 = std.math.rotl(u32, value, 2 * rotate);
        if (imm8 <= 0xff) return @intCast((rotate << 8) | imm8);
    }
    return null;
}

/// The constant that a 12-bit immediate operand stands for.
fn decodeImm(operand: u12) u32 {
    const rotate: u32 = operand >> 8;
    const imm8: u32 = operand & 0xff;
    return std.math.rotr(u32, imm8, 2 * rotate);
}

/// Operand 2 for "Rm, shifted by a constant amount".
fn shiftedReg(rm: u4, kind: Shift, amount: u5) u12 {
    return @as(u12, amount) << 7 | @as(u12, @intFromEnum(kind)) << 5 | rm;
}

/// Operand 2 for "Rm, shifted by the amount in Rs": bit 4 is set, and Rs
/// sits where the top of the amount was.
fn shiftedByReg(rm: u4, kind: Shift, rs: u4) u12 {
    return @as(u12, rs) << 8 | @as(u12, @intFromEnum(kind)) << 5 | 1 << 4 | rm;
}

/// A data-processing instruction. `imm` is the I bit.
fn dataProc(cond: Cond, op: Op, s: bool, rd: u4, rn: u4, imm: bool, operand2: u12) u32 {
    return @as(u32, @intFromEnum(cond)) << 28 |
        @as(u32, @intFromBool(imm)) << 25 |
        @as(u32, @intFromEnum(op)) << 21 |
        @as(u32, @intFromBool(s)) << 20 |
        @as(u32, rn) << 16 |
        @as(u32, rd) << 12 |
        operand2;
}

/// rd = rm * rs.
fn mulInsn(cond: Cond, s: bool, rd: u4, rm: u4, rs: u4) u32 {
    return @as(u32, @intFromEnum(cond)) << 28 | @as(u32, @intFromBool(s)) << 20 |
        @as(u32, rd) << 16 | @as(u32, rs) << 8 | 0b1001 << 4 | rm;
}

const Mem = struct {
    load: bool,
    byte: bool = false,
    rd: u4,
    rn: u4,
    /// P: true for [rn, #offset], false for [rn], #offset
    pre: bool = true,
    /// W: the ! in [rn, #offset]!
    writeback: bool = false,
};

fn memBits(cond: Cond, m: Mem, up: bool) u32 {
    return @as(u32, @intFromEnum(cond)) << 28 | 0b01 << 26 |
        @as(u32, @intFromBool(m.pre)) << 24 | @as(u32, @intFromBool(up)) << 23 |
        @as(u32, @intFromBool(m.byte)) << 22 | @as(u32, @intFromBool(m.writeback)) << 21 |
        @as(u32, @intFromBool(m.load)) << 20 | @as(u32, m.rn) << 16 | @as(u32, m.rd) << 12;
}

/// A load or store with a constant offset, from -4095 to 4095. The
/// instruction holds the offset's SIZE in 12 bits, and its sign as the U
/// bit: up for an offset of zero or more.
fn memImm(cond: Cond, m: Mem, offset: i32) u32 {
    const up = offset >= 0;
    const size: u32 = @abs(offset);
    std.debug.assert(size < 4096);
    return memBits(cond, m, up) | size;
}

/// A load or store whose offset is a (shifted) register: the I bit, and
/// the same layout as operand 2 of a data-processing instruction.
fn memReg(cond: Cond, m: Mem, up: bool, operand: u12) u32 {
    return memBits(cond, m, up) | 1 << 25 | @as(u32, operand);
}

/// A branch from the instruction at address `from` to address `to`. The
/// offset counts words, from 8 bytes past the branch, and is stored in
/// 24 bits (two's complement when it is negative).
fn branch(cond: Cond, link: bool, from: u32, to: u32) u32 {
    const bytes: i32 = @bitCast(to -% (from +% 8));
    const words: u32 = @bitCast(@divExact(bytes, 4));
    return @as(u32, @intFromEnum(cond)) << 28 | 0b101 << 25 | @as(u32, @intFromBool(link)) << 24 | (words & 0xffffff);
}

/// A system call.
fn swiInsn(cond: Cond, number: u24) u32 {
    return @as(u32, @intFromEnum(cond)) << 28 | 0b1111 << 24 | @as(u32, number);
}
