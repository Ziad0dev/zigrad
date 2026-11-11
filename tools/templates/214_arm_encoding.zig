//
// ─── Exercise 214: thirty-two bits that mean "add" ────────────────────
//
// Chapter 44: what is a processor anyway? A machine that reads a number
// from memory, does what the number says, and reads the next one. This
// chapter builds one twice, as a Zig program and as a circuit, plus the
// assembler that writes its numbers. First: the numbers.
//
// Our processor is an ARM7, the 1990s design inside the Game Boy Advance
// and the first iPods, and the ancestor of the chip in your phone. It has
// 16 registers of 32 bits, r0 to r15. Three have jobs: r13 is the stack
// pointer (sp), r14 the link register (lr, where a call's return address
// goes), and r15 the program counter (pc). Every instruction is exactly
// one 32-bit word. The top four bits of every one are a *condition*
// (next exercise; 1110 means "always"). The rest depends on the kind:
//
//  data processing (add, sub, mov, cmp, and, orr, ...):
//   31..28 27 26 25 24..21 20 19..16 15..12 11..........0
//   cond    0  0  I opcode  S   Rn     Rd    operand 2
//
//     Rd = Rn <opcode> operand2.   S: also update the flags.
//     I = 1: operand 2 is a constant, as rotate(4 bits), imm8(8 bits):
//            the value is imm8 rotated RIGHT by 2 * rotate.
//     I = 0: operand 2 is register Rm (bits 3..0), shifted:
//            11..7 amount, 6..5 kind (lsl lsr asr ror), bit 4 = 0
//
// The constant is the famous quirk. A 32-bit instruction can't hold a
// 32-bit constant, so ARM spends 12 bits on "8 bits, anywhere": 0xff,
// 0xff00, 0x3fc and 0xf000000f all fit; 0x101 and 0x12345678 don't.
//
//  multiply:        cond 000000 0 S Rd(19..16) 0000 Rs(11..8) 1001 Rm
//  load and store:  cond 01 I P U B W L Rn(19..16) Rd(15..12) offset(12)
//     L: 1 load, 0 store.   B: a byte, not a word.
//     U: add the offset to Rn (1) or subtract it (0).
//     P: use Rn+offset as the address (1), or Rn alone and update Rn
//        afterwards (0, "post-indexed").   W: write the address back to Rn.
//  branch:          cond 101 L offset(24)
//     jump to pc + 8 + 4 * offset (signed). L: put the return address in lr.
//     Why + 8? By the time an ARM7 executes an instruction it has already
//     fetched two more, so its pc register is two instructions ahead (221).
//  software interrupt (a system call):  cond 1111 number(24)
//
// Every golden value in the tests is what LLVM's assembler produces for
// that line (`zig cc -target arm-freestanding-eabi -mcpu=arm7tdmi`).
//
// YOUR TASK: the rotated constant, and the bit-packing.
//
const std = @import("std");

//@export arm_enc
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
        const imm8 = ⟪std.math.rotl(u32, value, 2 * rotate)|||???⟫;
        if (imm8 <= 0xff) return @intCast(⟪(rotate << 8) | imm8|||???⟫);
    }
    return null;
}

/// The constant that a 12-bit immediate operand stands for.
fn decodeImm(operand: u12) u32 {
    const rotate: u32 = operand >> 8;
    const imm8: u32 = operand & 0xff;
    return ⟪std.math.rotr(u32, imm8, 2 * rotate)|||???⟫;
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
        @as(u32, @intFromBool(imm)) << ⟪25|||???⟫ |
        @as(u32, @intFromEnum(op)) << ⟪21|||???⟫ |
        @as(u32, @intFromBool(s)) << 20 |
        @as(u32, rn) << ⟪16|||???⟫ |
        @as(u32, rd) << ⟪12|||???⟫ |
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
    const up = ⟪offset >= 0|||???⟫;
    const size: u32 = ⟪@abs(offset)|||???⟫;
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
    const bytes: i32 = @bitCast(⟪to -% (from +% 8)|||???⟫);
    const words: u32 = @bitCast(⟪@divExact(bytes, 4)|||???⟫);
    return @as(u32, @intFromEnum(cond)) << 28 | 0b101 << 25 | @as(u32, @intFromBool(link)) << 24 | (words & 0xffffff);
}

/// A system call.
fn swiInsn(cond: Cond, number: u24) u32 {
    return @as(u32, @intFromEnum(cond)) << 28 | 0b1111 << 24 | @as(u32, number);
}
//@end

const expectEqual = std.testing.expectEqual;

fn expectWord(want: u32, got: u32) !void {
    if (want != got) {
        std.debug.print("want 0x{x:0>8}, got 0x{x:0>8}\n", .{ want, got });
        return error.TestExpectedEqual;
    }
}

test "8 bits, anywhere" {
    try expectEqual(@as(?u12, 0x001), encodeImm(1));
    try expectEqual(@as(?u12, 0xcff), encodeImm(0xff00));
    try expectEqual(@as(?u12, 0xfff), encodeImm(0x3fc));
    try expectEqual(@as(?u12, 0x2ff), encodeImm(0xf000000f)); // it wraps around
    try expectEqual(@as(?u12, 0x102), encodeImm(0x80000000));
    try expectEqual(@as(?u12, null), encodeImm(0x101));
    try expectEqual(@as(?u12, null), encodeImm(0x12345678));
    try expectEqual(@as(?u12, null), encodeImm(0x1fe)); // 8 bits wide, but at an odd position
    // several encodings can mean one value: the smallest rotation is the one assemblers pick
    try expectEqual(@as(u32, 1), decodeImm(0x001));
    try expectEqual(@as(u32, 1), decodeImm(0x104));
    var prng = std.Random.DefaultPrng.init(214);
    for (0..2000) |_| {
        const operand = prng.random().int(u12);
        const value = decodeImm(operand);
        try expectEqual(value, decodeImm(encodeImm(value).?));
    }
}

test "data processing" {
    try expectWord(0xe3a00001, dataProc(.al, .mov, false, 0, 0, true, encodeImm(1).?)); // mov r0, #1
    try expectWord(0xe3e03000, dataProc(.al, .mvn, false, 3, 0, true, 0)); // mvn r3, #0
    try expectWord(0xe0810002, dataProc(.al, .add, false, 0, 1, false, shiftedReg(2, .lsl, 0))); // add r0, r1, r2
    try expectWord(0xe0921183, dataProc(.al, .add, true, 1, 2, false, shiftedReg(3, .lsl, 3))); // adds r1, r2, r3, lsl #3
    try expectWord(0xe0454756, dataProc(.al, .sub, false, 4, 5, false, shiftedByReg(6, .asr, 7))); // sub r4, r5, r6, asr r7
    try expectWord(0xe350000a, dataProc(.al, .cmp, true, 0, 0, true, 10)); // cmp r0, #10
    try expectWord(0x02800001, dataProc(.eq, .add, false, 0, 0, true, 1)); // addeq r0, r0, #1
    try expectWord(0x10511002, dataProc(.ne, .sub, true, 1, 1, false, 2)); // subsne r1, r1, r2
    try expectWord(0xe1a0f00e, dataProc(.al, .mov, false, PC, 0, false, LR)); // mov pc, lr: return
    try expectWord(0xe38002ff, dataProc(.al, .orr, false, 0, 0, true, encodeImm(0xf000000f).?));
}

test "multiply, load, store" {
    try expectWord(0xe0000291, mulInsn(.al, false, 0, 1, 2)); // mul r0, r1, r2
    try expectWord(0xe0130594, mulInsn(.al, true, 3, 4, 5)); // muls r3, r4, r5
    try expectWord(0xe5910000, memImm(.al, .{ .load = true, .rd = 0, .rn = 1 }, 0)); // ldr r0, [r1]
    try expectWord(0xe5910004, memImm(.al, .{ .load = true, .rd = 0, .rn = 1 }, 4)); // ldr r0, [r1, #4]
    try expectWord(0xe5110004, memImm(.al, .{ .load = true, .rd = 0, .rn = 1 }, -4)); // ldr r0, [r1, #-4]
    try expectWord(0xe5c32001, memImm(.al, .{ .load = false, .byte = true, .rd = 2, .rn = 3 }, 1)); // strb r2, [r3, #1]
    // the two instructions this part uses as push and pop:
    try expectWord(0xe52d0004, memImm(.al, .{ .load = false, .rd = 0, .rn = SP, .writeback = true }, -4)); // str r0, [sp, #-4]!
    try expectWord(0xe49d0004, memImm(.al, .{ .load = true, .rd = 0, .rn = SP, .pre = false }, 4)); // ldr r0, [sp], #4
    try expectWord(0xe7d32004, memReg(.al, .{ .load = true, .byte = true, .rd = 2, .rn = 3 }, true, 4)); // ldrb r2, [r3, r4]
    try expectWord(0xe7910102, memReg(.al, .{ .load = true, .rd = 0, .rn = 1 }, true, shiftedReg(2, .lsl, 2))); // ldr r0, [r1, r2, lsl #2]
}

test "branches count words from two instructions ahead" {
    try expectWord(0xeafffffe, branch(.al, false, 0x54, 0x54)); // b to itself: -2
    try expectWord(0xebfffffe, branch(.al, true, 0x100, 0x100));
    try expectWord(0x1affffff, branch(.ne, false, 0x5c, 0x60)); // the very next instruction: -1
    try expectWord(0xea000000, branch(.al, false, 0, 8));
    try expectWord(0xea0003fe, branch(.al, false, 0, 0x1000));
    try expectWord(0xeb00000e, branch(.al, true, 0x8000, 0x8040));
    try expectWord(0xef123456, swiInsn(.al, 0x123456));
}
