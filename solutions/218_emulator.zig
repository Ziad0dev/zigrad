// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 218: a processor, in software ───────────────────────────
//
// What is a processor anyway? This loop:
//
//     forever:
//         fetch    read the word at address pc
//         decode   work out what it asks for (214, backwards)
//         execute  do it: change a register, or memory, or pc itself
//
// That's all of it. 217 was the "execute" of arithmetic. This exercise is
// the loop, and the three kinds of instruction that make a calculator
// into a computer: branches, loads and stores.
//
// A BRANCH changes pc. `bl` first saves the address of the instruction
// after it in lr (r14), so the code it jumps to can come back with
// `mov pc, lr`. That is all a function call is.
//
// LOADS and STORES move words between registers and memory. Memory here
// is a *bus*: the processor puts an address on it and something answers.
// Below 1 MB, RAM answers. At 0x10000000, the UART answers:
//
//     0x10000000  write: send this byte
//     0x10000004  read:  bit 0 = ready to send, bit 1 = a byte has arrived
//     0x10000008  read:  the byte that arrived
//
// The processor can't tell the difference, and doesn't need to. That is
// memory-mapped I/O (213), and it is why "print a character" needs no
// special instruction: it's a store.
//
// Two details the tests care about. An instruction that reads r15 gets
// its own address + 8 (214). And a load or store that can't be done (no
// such address) must leave every register exactly as it was, pc included,
// so that whoever handles the *fault* can fix the problem and run the
// instruction again. The operating system will lean on that, hard, in
// chapter 46.
//
// The Cpu here is the reference model for the rest of Part VII. To check
// it against something that isn't us, the same random instruction streams
// were run through QEMU's ARM emulation while this exercise was written.
//
// YOUR TASK: the pieces of step() marked below, and the UART's side of
// the bus.
//
const std = @import("std");

const Access = enum { read, write, execute };
const Fault = struct { addr: u32, access: Access };

/// What happened in one step, when it wasn't just "an instruction ran".
const Event = union(enum) {
    ok,
    /// A `swi` instruction: a request to whoever is in charge.
    swi: u24,
    /// A word that is no instruction we know. Its address is still in pc.
    undefined: u32,
    /// Memory said no. pc still points at the instruction.
    fault: Fault,
};

fn bit(insn: u32, comptime n: u5) bool {
    return (insn >> n) & 1 != 0;
}

fn field(insn: u32, comptime low: u5) u4 {
    return @truncate(insn >> low);
}

const Cpu = struct {
    /// r[15] is the address of the instruction about to run.
    r: [16]u32 = @splat(0),
    flags: Flags = .{},

    /// A register's value as an instruction at address `pc` sees it.
    fn get(cpu: *const Cpu, n: u4, pc: u32) u32 {
        return if (n == PC) pc +% 8 else cpu.r[n];
    }

    /// Runs one instruction. `mem` is anything with
    ///     read(addr: u32, size: u3) !u32    and
    ///     write(addr: u32, size: u3, value: u32) !void
    /// where size is 1 (a byte) or 4 (a word).
    fn step(cpu: *Cpu, mem: anytype) Event {
        const pc = cpu.r[PC];
        const insn = mem.read(pc, 4) catch return .{ .fault = .{ .addr = pc, .access = .execute } };
        const cond = std.enums.fromInt(Cond, insn >> 28) orelse return .{ .undefined = insn };
        cpu.r[PC] = pc +% 4; // unless the instruction says otherwise
        if (!condPasses(cond, cpu.flags)) return .ok;

        const event: Event = if (field(insn, 24) == 0b1111)
            .{ .swi = @truncate(insn) }
        else if (insn >> 25 & 0b111 == 0b101)
            cpu.branchInsn(insn, pc)
        else if (insn & 0x0fc000f0 == 0x00000090)
            cpu.multiply(insn, pc)
        else switch (insn >> 26 & 0b11) {
            0b00 => cpu.dataProcessing(insn, pc),
            0b01 => cpu.loadStore(insn, pc, mem),
            else => .{ .undefined = insn },
        };
        if (event == .undefined or event == .fault) cpu.r[PC] = pc;
        return event;
    }

    fn branchInsn(cpu: *Cpu, insn: u32, pc: u32) Event {
        // bits 23..0 are a signed number of WORDS, counted from pc + 8
        const words: i24 = @bitCast(@as(u24, @truncate(insn)));
        const bytes: i32 = @as(i32, words) * 4;
        if (bit(insn, 24)) cpu.r[LR] = pc +% 4; // bl: where to come back to
        cpu.r[PC] = pc +% 8 +% @as(u32, @bitCast(bytes));
        return .ok;
    }

    fn multiply(cpu: *Cpu, insn: u32, pc: u32) Event {
        if (bit(insn, 21)) return .{ .undefined = insn }; // multiply-accumulate: not built
        const product = cpu.get(field(insn, 0), pc) *% cpu.get(field(insn, 8), pc);
        cpu.r[field(insn, 16)] = product;
        if (bit(insn, 20)) {
            cpu.flags.n = product >> 31 != 0;
            cpu.flags.z = product == 0;
        }
        return .ok;
    }

    fn dataProcessing(cpu: *Cpu, insn: u32, pc: u32) Event {
        const op: Op = @enumFromInt(field(insn, 21));
        const s = bit(insn, 20);
        var b: Shifted = undefined;
        if (bit(insn, 25)) {
            // a constant: 8 bits, anywhere. Its carry is its top bit, if it was rotated at all.
            const value = decodeImm(@truncate(insn));
            b = .{ .value = value, .carry = if (field(insn, 8) == 0) cpu.flags.c else value >> 31 != 0 };
        } else {
            const rm = cpu.get(field(insn, 0), pc);
            const kind: Shift = @enumFromInt(insn >> 5 & 0b11);
            if (bit(insn, 4)) {
                // shifted by the low byte of register Rs
                if (bit(insn, 7)) return .{ .undefined = insn };
                b = barrelShift(kind, rm, cpu.get(field(insn, 8), pc) & 0xff, cpu.flags.c);
            } else {
                b = shiftByImmediate(kind, rm, @truncate(insn >> 7), cpu.flags.c);
            }
        }
        const result = alu(op, cpu.get(field(insn, 16), pc), b.value, cpu.flags, b.carry);
        // cmp and friends exist only to set flags; without S they are other instructions
        if (!result.writes and !s) return .{ .undefined = insn };
        if (s) cpu.flags = result.flags;
        if (result.writes) cpu.r[field(insn, 12)] = result.value; // into r15, this is a jump
        return .ok;
    }

    fn loadStore(cpu: *Cpu, insn: u32, pc: u32, mem: anytype) Event {
        const pre = bit(insn, 24); // P
        const up = bit(insn, 23); // U
        const size: u3 = if (bit(insn, 22)) 1 else 4; // B
        const writeback = bit(insn, 21); // W
        const load = bit(insn, 20); // L
        const rn = field(insn, 16);
        const rd = field(insn, 12);

        var offset: u32 = insn & 0xfff;
        if (bit(insn, 25)) {
            // a register offset, shifted by a constant
            if (bit(insn, 4)) return .{ .undefined = insn };
            offset = shiftByImmediate(@enumFromInt(insn >> 5 & 0b11), cpu.get(field(insn, 0), pc), @truncate(insn >> 7), cpu.flags.c).value;
        }
        const base = cpu.get(rn, pc);
        const moved = if (up) base +% offset else base -% offset;
        // [rn, #n] uses the moved address. [rn], #n uses rn as it was.
        const addr = if (pre) moved else base;
        // rn itself changes for [rn], #n and for [rn, #n]!
        const updates_rn = !pre or writeback;

        if (load) {
            const value = mem.read(addr, size) catch return .{ .fault = .{ .addr = addr, .access = .read } };
            if (updates_rn) cpu.r[rn] = moved;
            cpu.r[rd] = value;
        } else {
            mem.write(addr, size, cpu.get(rd, pc)) catch return .{ .fault = .{ .addr = addr, .access = .write } };
            if (updates_rn) cpu.r[rn] = moved;
        }
        return .ok;
    }

    /// Steps until something other than .ok happens. null: `limit`
    /// instructions went by and nothing did.
    fn run(cpu: *Cpu, mem: anytype, limit: usize) ?Event {
        for (0..limit) |_| {
            const event = cpu.step(mem);
            if (event != .ok) return event;
        }
        return null;
    }
};

const uart_base: u32 = 0x10000000;

/// The whole computer, so far: RAM from address 0, and a UART.
const Board = struct {
    ram: []u8,
    alloc: std.mem.Allocator,
    /// Every byte the program has sent.
    uart_out: std.ArrayList(u8) = .empty,
    /// Bytes on their way to the program.
    uart_in: []const u8 = "",

    fn init(alloc: std.mem.Allocator, ram_size: usize) !Board {
        const ram = try alloc.alloc(u8, ram_size);
        @memset(ram, 0);
        return .{ .ram = ram, .alloc = alloc };
    }

    fn deinit(b: *Board) void {
        b.alloc.free(b.ram);
        b.uart_out.deinit(b.alloc);
    }

    /// Copies a program into RAM.
    fn load(b: *Board, addr: u32, bytes: []const u8) void {
        @memcpy(b.ram[addr..][0..bytes.len], bytes);
    }

    fn read(b: *Board, addr: u32, size: u3) !u32 {
        if (addr >= uart_base) {
            switch (addr - uart_base) {
                // status: always ready to send (bit 0); bit 1 when input is waiting
                4 => return 1 | @as(u32, @intFromBool(b.uart_in.len > 0)) << 1,
                8 => {
                    if (b.uart_in.len == 0) return 0;
                    const byte = b.uart_in[0];
                    b.uart_in = b.uart_in[1..]; // reading the register takes the byte
                    return byte;
                },
                else => return error.NoDevice,
            }
        }
        if (size == 1) {
            if (addr >= b.ram.len) return error.NoDevice;
            return b.ram[addr];
        }
        // a word must sit at a multiple of 4
        if (addr % 4 != 0 or @as(usize, addr) + 4 > b.ram.len) return error.NoDevice;
        return std.mem.readInt(u32, b.ram[addr..][0..4], .little);
    }

    fn write(b: *Board, addr: u32, size: u3, value: u32) !void {
        if (addr == uart_base) return b.uart_out.append(b.alloc, @truncate(value));
        if (size == 1) {
            if (addr >= b.ram.len) return error.NoDevice;
            b.ram[addr] = @truncate(value);
            return;
        }
        if (addr % 4 != 0 or @as(usize, addr) + 4 > b.ram.len) return error.NoDevice;
        std.mem.writeInt(u32, b.ram[addr..][0..4], value, .little);
    }
};

const ta = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Ran = struct {
    cpu: Cpu,
    board: Board,
    event: ?Event,
};

/// Assembles `source` at 0x8000 and runs it there, with the stack at the top of 64 KB.
fn runProgram(source: []const u8, uart_in: []const u8) !Ran {
    var prog = try assemble(ta, source, 0x8000, null);
    defer prog.deinit(ta);
    var ran: Ran = .{ .cpu = .{}, .board = try Board.init(ta, 0x10000), .event = null };
    ran.board.uart_in = uart_in;
    ran.board.load(0x8000, prog.code);
    ran.cpu.r[PC] = 0x8000;
    ran.cpu.r[SP] = 0x10000;
    ran.event = ran.cpu.run(&ran.board, 100_000);
    return ran;
}

test "count to ten" {
    var ran = try runProgram(
        \\        mov   r0, #0
        \\loop:   add   r0, r0, #1
        \\        cmp   r0, #10
        \\        bne   loop
        \\        swi   7
    , "");
    defer ran.board.deinit();
    try expectEqual(Event{ .swi = 7 }, ran.event.?);
    try expectEqual(@as(u32, 10), ran.cpu.r[0]);
    try expectEqual(@as(u32, 0x8014), ran.cpu.r[PC]); // just past the swi
    try expect(ran.cpu.flags.z and ran.cpu.flags.c);
}

test "conditional execution: absolute value without a branch" {
    var ran = try runProgram(
        \\        mvn   r0, #41         @ -42
        \\        cmp   r0, #0
        \\        rsblt r0, r0, #0      @ only if it was negative
        \\        mov   r1, #5
        \\        cmp   r1, #0
        \\        rsblt r1, r1, #0      @ skipped
        \\        swi   0
    , "");
    defer ran.board.deinit();
    try expectEqual(@as(u32, 42), ran.cpu.r[0]);
    try expectEqual(@as(u32, 5), ran.cpu.r[1]);
}

test "memory: summing an array, three addressing modes" {
    var ran = try runProgram(
        \\        ldr   r4, =numbers
        \\        mov   r0, #0
        \\        mov   r5, #4
        \\sum:    ldr   r1, [r4], #4          @ load, then step the pointer
        \\        add   r0, r0, r1
        \\        subs  r5, r5, #1
        \\        bne   sum
        \\        ldr   r6, =numbers
        \\        mov   r7, #2
        \\        ldr   r2, [r6, r7, lsl #2]  @ numbers[2]
        \\        ldr   r3, [r6, #4]!         @ step the pointer, then load
        \\        ldr   r8, =result
        \\        str   r0, [r8]
        \\        strb  r0, [r8, #5]
        \\        ldrb  r9, [r6, #1]          @ the second byte of 0x00000102
        \\        swi   0
        \\numbers:
        \\        .word 1000, 0x102, 30, 4
        \\result: .word 0, 0
    , "");
    defer ran.board.deinit();
    try expectEqual(@as(u32, 1000 + 0x102 + 30 + 4), ran.cpu.r[0]);
    try expectEqual(@as(u32, 30), ran.cpu.r[2]);
    try expectEqual(@as(u32, 0x102), ran.cpu.r[3]);
    try expectEqual(ran.cpu.r[4] - 12, ran.cpu.r[6]); // r4 walked 4 words, r6 one
    try expectEqual(@as(u32, 1), ran.cpu.r[9]); // little-endian: 02 01 00 00
    const result = ran.cpu.r[8];
    try expectEqual(@as(u32, 1292), std.mem.readInt(u32, ran.board.ram[result..][0..4], .little));
    try expectEqual(@as(u8, 1292 & 0xff), ran.board.ram[result + 5]);
}

test "calls, a stack, and recursion" {
    var ran = try runProgram(
        \\        mov   r0, #10
        \\        bl    fact
        \\        swi   0
        \\@ fact(n) = n < 2 ? 1 : n * fact(n - 1)
        \\fact:   cmp   r0, #2
        \\        movlt r0, #1
        \\        movlt pc, lr              @ return
        \\        str   lr, [sp, #-4]!      @ push the return address
        \\        str   r0, [sp, #-4]!      @ push n
        \\        sub   r0, r0, #1
        \\        bl    fact                @ overwrites lr: that's why we saved it
        \\        ldr   r1, [sp], #4        @ pop n
        \\        mul   r0, r1, r0
        \\        ldr   pc, [sp], #4        @ pop the return address, straight into pc
    , "");
    defer ran.board.deinit();
    try expectEqual(@as(u32, 3628800), ran.cpu.r[0]);
    try expectEqual(@as(u32, 0x10000), ran.cpu.r[SP]); // everything pushed was popped
    // lr is just a register: it still holds what the innermost `bl fact` put there
    try expectEqual(@as(u32, 0x8028), ran.cpu.r[LR]);
}

test "hello, world: printing is a store" {
    var ran = try runProgram(
        \\        ldr   r1, =0x10000000     @ the UART
        \\        ldr   r2, =message
        \\next:   ldrb  r0, [r2], #1
        \\        cmp   r0, #0
        \\        strne r0, [r1]
        \\        bne   next
        \\        swi   0
        \\message:
        \\        .asciz "hello, world\n"
    , "");
    defer ran.board.deinit();
    try std.testing.expectEqualStrings("hello, world\n", ran.board.uart_out.items);
}

test "reading the UART: upper-case an echo" {
    var ran = try runProgram(
        \\        ldr   r1, =0x10000000
        \\wait:   ldr   r0, [r1, #4]        @ status
        \\        tst   r0, #2              @ has a byte arrived?
        \\        beq   done
        \\        ldr   r0, [r1, #8]        @ take it
        \\        cmp   r0, #'a'
        \\        subhs r0, r0, #32
        \\        str   r0, [r1]
        \\        b     wait
        \\done:   swi   0
    , "abc");
    defer ran.board.deinit();
    try std.testing.expectEqualStrings("ABC", ran.board.uart_out.items);
}

test "64-bit addition, with the carry flag as the link" {
    var ran = try runProgram(
        \\        mvn   r0, #0              @ low word:  0xffffffff
        \\        mov   r1, #1              @ high word: 1
        \\        adds  r0, r0, #2          @ low + 2 carries out...
        \\        adc   r1, r1, #0          @ ...into the high word
        \\        swi   0
    , "");
    defer ran.board.deinit();
    try expectEqual(@as(u32, 1), ran.cpu.r[0]);
    try expectEqual(@as(u32, 2), ran.cpu.r[1]);
}

test "pc reads two instructions ahead" {
    var ran = try runProgram(
        \\        mov   r0, pc              @ at 0x8000
        \\        add   r1, pc, #4          @ at 0x8004
        \\        ldr   r2, [pc, #-4]       @ at 0x8008: the word at 0x800c
        \\        swi   0x42
    , "");
    defer ran.board.deinit();
    try expectEqual(@as(u32, 0x8008), ran.cpu.r[0]);
    try expectEqual(@as(u32, 0x8010), ran.cpu.r[1]);
    try expectEqual(@as(u32, 0xef000042), ran.cpu.r[2]);
}

test "a fault changes nothing, so the instruction can run again" {
    var ran = try runProgram(
        \\        ldr   r1, =0x200000       @ beyond our RAM
        \\        mov   r0, #7
        \\        str   r0, [r1, #4]!
        \\        swi   0
    , "");
    defer ran.board.deinit();
    try expectEqual(Event{ .fault = .{ .addr = 0x200004, .access = .write } }, ran.event.?);
    try expectEqual(@as(u32, 0x8008), ran.cpu.r[PC]); // still at the store
    try expectEqual(@as(u32, 0x200000), ran.cpu.r[1]); // no writeback happened
    // "Fix" the problem the way an operating system would, and carry on.
    ran.cpu.r[1] = 0x9000 - 4;
    try expectEqual(Event{ .swi = 0 }, ran.cpu.run(&ran.board, 10).?);
    try expectEqual(@as(u32, 7), std.mem.readInt(u32, ran.board.ram[0x9000..][0..4], .little));
    try expectEqual(@as(u32, 0x9000), ran.cpu.r[1]);
}

test "undefined instructions, unaligned words, runaway programs" {
    var ran = try runProgram(".word 0xe7f000f0", "");
    try expectEqual(Event{ .undefined = 0xe7f000f0 }, ran.event.?);
    try expectEqual(@as(u32, 0x8000), ran.cpu.r[PC]);
    ran.board.deinit();
    ran = try runProgram("mov r1, #2\nldr r0, [r1]", "");
    try expectEqual(Event{ .fault = .{ .addr = 2, .access = .read } }, ran.event.?);
    ran.board.deinit();
    ran = try runProgram("mov r1, #2\nldrb r0, [r1]\nswi 0", ""); // a byte can live anywhere
    try expectEqual(Event{ .swi = 0 }, ran.event.?);
    ran.board.deinit();
    ran = try runProgram("spin: b spin", "");
    try expect(ran.event == null);
    ran.board.deinit();
    ran = try runProgram("mov pc, #0x100000", ""); // jump off the end of RAM
    try expectEqual(Event{ .fault = .{ .addr = 0x100000, .access = .execute } }, ran.event.?);
    ran.board.deinit();
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
/// The addresses of labels. Filled in by the caller (216 does it from the
/// labels in a file).
/// Where a name was used: the address of the word that used it, and
/// whether that word IS the name's address (a `.word`, or a constant in
/// the literal pool) or an instruction that reaches it relative to pc.
const SymbolUse = struct { name: []const u8, site: u32, absolute: bool };

const Symbols = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,
    /// After error.UndefinedSymbol: the name that wasn't found.
    missing: []const u8 = "",
    /// Only the assembler of an *object file* sets this (229). Then every
    /// lookup is written down, with `site` and `absolute`, which say
    /// what is being assembled; and a name nobody has defined is no
    /// error. It reads as 0, for the linker to fill in later.
    uses: ?*std.ArrayList(SymbolUse) = null,
    uses_alloc: std.mem.Allocator = undefined,
    site: u32 = 0,
    absolute: bool = false,

    fn get(sy: *Symbols, name: []const u8) !u32 {
        if (sy.uses) |uses| {
            try uses.append(sy.uses_alloc, .{ .name = name, .site = sy.site, .absolute = sy.absolute });
            return sy.map.get(name) orelse 0;
        }
        return sy.map.get(name) orelse {
            sy.missing = name;
            return error.UndefinedSymbol;
        };
    }
};

fn parseReg(name: []const u8) ?u4 {
    const named = [_]struct { []const u8, u4 }{ .{ "sp", 13 }, .{ "lr", 14 }, .{ "pc", 15 }, .{ "fp", 11 }, .{ "ip", 12 } };
    for (named) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    if (name.len < 2 or name[0] != 'r') return null;
    return std.fmt.parseInt(u4, name[1..], 10) catch null;
}

/// Reads operands, left to right.
const Scanner = struct {
    text: []const u8,
    at: usize = 0,

    /// The next character that isn't a space (0 at the end), not consumed.
    fn peek(sc: *Scanner) u8 {
        while (sc.at < sc.text.len and (sc.text[sc.at] == ' ' or sc.text[sc.at] == '\t')) sc.at += 1;
        return if (sc.at < sc.text.len) sc.text[sc.at] else 0;
    }

    /// Consumes `c` if it is next.
    fn eat(sc: *Scanner, c: u8) bool {
        if (sc.peek() != c) return false;
        sc.at += 1;
        return true;
    }

    fn need(sc: *Scanner, c: u8) !void {
        if (!sc.eat(c)) return error.BadOperand;
    }

    fn done(sc: *Scanner) bool {
        return sc.peek() == 0;
    }

    /// A run of letters, digits, '_', '.' and '$': a name or a number.
    fn word(sc: *Scanner) []const u8 {
        _ = sc.peek();
        const start = sc.at;
        while (sc.at < sc.text.len) : (sc.at += 1) {
            const c = sc.text[sc.at];
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '$') break;
        }
        return sc.text[start..sc.at];
    }

    fn reg(sc: *Scanner) !u4 {
        return parseReg(sc.word()) orelse error.BadRegister;
    }

    /// 12, -12, 0x1f, or a character like 'a'. Returned as 32 bits.
    fn number(sc: *Scanner) !u32 {
        if (sc.eat('\'')) {
            if (sc.at + 1 >= sc.text.len or sc.text[sc.at + 1] != '\'') return error.BadNumber;
            sc.at += 2;
            return sc.text[sc.at - 2];
        }
        const negative = sc.eat('-');
        const v = std.fmt.parseInt(u32, sc.word(), 0) catch return error.BadNumber;
        return if (negative) 0 -% v else v;
    }

    /// A number, or a symbol's address.
    fn value(sc: *Scanner, syms: *Symbols) !u32 {
        const c = sc.peek();
        if (std.ascii.isDigit(c) or c == '-' or c == '\'') return sc.number();
        const name = sc.word();
        if (name.len == 0) return error.BadOperand;
        return syms.get(name);
    }
};

const Kind = union(enum) {
    data: Op,
    mul,
    mem: struct { load: bool, byte: bool },
    branch: struct { link: bool },
    swi,
};

const Mnemonic = struct { kind: Kind, s: bool = false, cond: Cond = .al };

const bases = [_]struct { []const u8, Kind }{
    .{ "and", .{ .data = .@"and" } },
    .{ "eor", .{ .data = .eor } },
    .{ "sub", .{ .data = .sub } },
    .{ "rsb", .{ .data = .rsb } },
    .{ "add", .{ .data = .add } },
    .{ "adc", .{ .data = .adc } },
    .{ "sbc", .{ .data = .sbc } },
    .{ "rsc", .{ .data = .rsc } },
    .{ "tst", .{ .data = .tst } },
    .{ "teq", .{ .data = .teq } },
    .{ "cmp", .{ .data = .cmp } },
    .{ "cmn", .{ .data = .cmn } },
    .{ "orr", .{ .data = .orr } },
    .{ "mov", .{ .data = .mov } },
    .{ "bic", .{ .data = .bic } },
    .{ "mvn", .{ .data = .mvn } },
    .{ "mul", .mul },
    .{ "ldrb", .{ .mem = .{ .load = true, .byte = true } } },
    .{ "strb", .{ .mem = .{ .load = false, .byte = true } } },
    .{ "ldr", .{ .mem = .{ .load = true, .byte = false } } },
    .{ "str", .{ .mem = .{ .load = false, .byte = false } } },
    .{ "bl", .{ .branch = .{ .link = true } } },
    .{ "b", .{ .branch = .{ .link = false } } },
    .{ "swi", .swi },
    .{ "svc", .swi }, // the modern name
};

fn parseCond(text: []const u8) ?Cond {
    if (std.mem.eql(u8, text, "hs")) return .cs; // "higher or same": another name for carry set
    if (std.mem.eql(u8, text, "lo")) return .cc;
    return std.meta.stringToEnum(Cond, text);
}

/// base name, then an optional "s", then an optional condition.
fn parseMnemonic(text: []const u8) ?Mnemonic {
    for (bases) |base| {
        if (!std.mem.startsWith(u8, text, base[0])) continue;
        var m: Mnemonic = .{ .kind = base[1] };
        var rest = text[base[0].len..];
        // Only data-processing instructions and mul can set the flags.
        const may_set_flags = m.kind == .data or m.kind == .mul;
        if (may_set_flags and rest.len > 0 and rest[0] == 's') {
            m.s = true;
            rest = rest[1..];
        }
        if (rest.len > 0) {
            // Whatever is left must be a condition. If it isn't, this
            // base name was the wrong guess: try the next one.
            m.cond = parseCond(rest) orelse continue;
        }
        return m;
    }
    return null;
}

/// How a constant shift amount is stored in 5 bits. lsl goes from 0 to 31.
/// The others go from 1 to 32 (a shift right by 0 would do nothing, so the
/// encoding 0 is reused to mean 32); ror stops at 31.
fn shiftAmount(kind: Shift, n: u32) !u5 {
    const max: u32 = switch (kind) {
        .lsl, .ror => 31,
        .lsr, .asr => 32,
    };
    if (n > max or (n == 0 and kind != .lsl)) return error.BadShift;
    return @truncate(n);
}

const Operand2 = struct { imm: bool, bits: u12 };

/// After the register rm: nothing, or ", lsl #n", or ", lsl rs".
fn parseShift(sc: *Scanner, rm: u4) !u12 {
    if (!sc.eat(',')) return shiftedReg(rm, .lsl, 0); // a plain register is "shifted left by 0"
    const kind = std.meta.stringToEnum(Shift, sc.word()) orelse return error.BadShift;
    if (sc.eat('#')) return shiftedReg(rm, kind, try shiftAmount(kind, try sc.number()));
    return shiftedByReg(rm, kind, try sc.reg());
}

fn parseOperand2(sc: *Scanner) !Operand2 {
    if (sc.eat('#')) {
        const v = try sc.number();
        return .{ .imm = true, .bits = encodeImm(v) orelse return error.ImmediateDoesNotFit };
    }
    return .{ .imm = false, .bits = try parseShift(sc, try sc.reg()) };
}

fn encodeData(sc: *Scanner, m: Mnemonic, op: Op) !u32 {
    switch (op) {
        .mov, .mvn => {
            const rd = try sc.reg();
            try sc.need(',');
            const op2 = try parseOperand2(sc);
            return dataProc(m.cond, op, m.s, rd, 0, op2.imm, op2.bits);
        },
        .tst, .teq, .cmp, .cmn => {
            const rn = try sc.reg();
            try sc.need(',');
            const op2 = try parseOperand2(sc);
            return dataProc(m.cond, op, true, 0, rn, op2.imm, op2.bits);
        },
        else => {
            const rd = try sc.reg();
            try sc.need(',');
            const rn = try sc.reg();
            try sc.need(',');
            const op2 = try parseOperand2(sc);
            return dataProc(m.cond, op, m.s, rd, rn, op2.imm, op2.bits);
        },
    }
}

/// The offset part of an address: #n, or rm, -rm, rm with a shift.
const Offset = union(enum) {
    imm: i32,
    reg: struct { up: bool, bits: u12 },
};

fn parseOffset(sc: *Scanner) !Offset {
    if (sc.eat('#')) return .{ .imm = @bitCast(try sc.number()) };
    const up = !sc.eat('-');
    return .{ .reg = .{ .up = up, .bits = try parseShift(sc, try sc.reg()) } };
}

fn encodeOffset(cond: Cond, m: Mem, offset: Offset) !u32 {
    switch (offset) {
        .imm => |n| {
            if (n < -4095 or n > 4095) return error.OffsetTooFar;
            return memImm(cond, m, n);
        },
        .reg => |r| return memReg(cond, m, r.up, r.bits),
    }
}

fn encodeMem(sc: *Scanner, cond: Cond, load: bool, byte: bool, addr: u32, syms: *Symbols) !u32 {
    var m: Mem = .{ .load = load, .byte = byte, .rd = try sc.reg(), .rn = 0 };
    try sc.need(',');
    if (!sc.eat('[')) {
        // A label: the word stored there. Its address is written as a
        // distance from pc, which reads as this instruction's address + 8.
        const target = try sc.value(syms);
        m.rn = PC;
        return encodeOffset(cond, m, .{ .imm = @bitCast(target -% (addr +% 8)) });
    }
    m.rn = try sc.reg();
    if (sc.eat(']')) {
        if (!sc.eat(',')) return memImm(cond, m, 0); // [rn]
        // [rn], offset: use rn as it is, then add the offset to it
        m.pre = false;
        return encodeOffset(cond, m, try parseOffset(sc));
    }
    // [rn, offset] or [rn, offset]!
    try sc.need(',');
    const offset = try parseOffset(sc);
    try sc.need(']');
    m.writeback = sc.eat('!');
    return encodeOffset(cond, m, offset);
}

/// Assembles one instruction, which will live at address `addr`.
fn encodeLine(line: []const u8, addr: u32, syms: *Symbols) !u32 {
    var sc: Scanner = .{ .text = line };
    const m = parseMnemonic(sc.word()) orelse return error.UnknownMnemonic;
    const encoded = switch (m.kind) {
        .data => |op| try encodeData(&sc, m, op),
        .mul => blk: {
            const rd = try sc.reg();
            try sc.need(',');
            const rm = try sc.reg();
            try sc.need(',');
            break :blk mulInsn(m.cond, m.s, rd, rm, try sc.reg());
        },
        .mem => |k| try encodeMem(&sc, m.cond, k.load, k.byte, addr, syms),
        .branch => |k| branch(m.cond, k.link, addr, try sc.value(syms)),
        .swi => blk: {
            _ = sc.eat('#');
            const n = try sc.number();
            if (n > 0xffffff) return error.BadNumber;
            break :blk swiInsn(m.cond, @intCast(n));
        },
    };
    if (!sc.done()) return error.BadOperand;
    return encoded;
}
/// The line without its comment: from `@` or `//` to the end, unless it
/// is inside quotes.
fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (c == '\\') i += 1 else if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '@' or (c == '/' and i + 1 < line.len and line[i + 1] == '/')) {
            return line[0..i];
        }
    }
    return line;
}

const Labelled = struct { name: []const u8, rest: []const u8 };

/// If the text starts with "name:", the name and what follows it.
fn takeLabel(text: []const u8) ?Labelled {
    var sc: Scanner = .{ .text = text };
    const name = sc.word();
    if (name.len == 0 or sc.at >= text.len or text[sc.at] != ':') return null;
    return .{ .name = name, .rest = std.mem.trim(u8, text[sc.at + 1 ..], " \t") };
}

/// The lines of a file, without comments or surrounding spaces.
const Lines = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    number: usize = 0,

    fn init(source: []const u8) Lines {
        return .{ .it = std.mem.splitScalar(u8, source, '\n') };
    }

    fn next(l: *Lines) ?[]const u8 {
        const line = l.it.next() orelse return null;
        l.number += 1;
        return std.mem.trim(u8, stripComment(line), " \t\r");
    }
};

const Directive = enum { word, byte, ascii, asciz, p2align, balign, space, equ, ltorg, ignored };

fn parseDirective(name: []const u8) ?Directive {
    const table = [_]struct { []const u8, Directive }{
        .{ ".word", .word },
        .{ ".long", .word },
        .{ ".byte", .byte },
        .{ ".ascii", .ascii },
        .{ ".asciz", .asciz },
        .{ ".string", .asciz },
        .{ ".align", .p2align },
        .{ ".balign", .balign },
        .{ ".space", .space },
        .{ ".skip", .space },
        .{ ".equ", .equ },
        .{ ".set", .equ },
        .{ ".ltorg", .ltorg },
        .{ ".pool", .ltorg },
        .{ ".global", .ignored },
        .{ ".globl", .ignored },
        .{ ".text", .ignored },
        .{ ".data", .ignored },
        .{ ".section", .ignored },
        .{ ".type", .ignored },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// `addr`, moved up to the next multiple of `to` (a power of two).
fn alignUp(addr: u32, to: u32) u32 {
    return (addr + to - 1) & ~(to - 1);
}

/// How many comma-separated things follow. (The comma in ',' is a
/// character, not a separator.)
fn countItems(sc: *Scanner) u32 {
    const rest = sc.text[sc.at..];
    var count: u32 = 1;
    for (rest, 0..) |c, i| {
        const quoted = i > 0 and i + 1 < rest.len and rest[i - 1] == '\'' and rest[i + 1] == '\'';
        if (c == ',' and !quoted) count += 1;
    }
    return count;
}

/// The bytes of a quoted string, with \n, \t, \r, \0, \\ and \" decoded.
fn parseString(alloc: std.mem.Allocator, sc: *Scanner) ![]u8 {
    try sc.need('"');
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    while (sc.at < sc.text.len and sc.text[sc.at] != '"') : (sc.at += 1) {
        var c = sc.text[sc.at];
        if (c == '\\') {
            sc.at += 1;
            if (sc.at >= sc.text.len) return error.BadString;
            c = switch (sc.text[sc.at]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '0' => 0,
                '\\', '"' => sc.text[sc.at],
                else => return error.BadString,
            };
        }
        try out.append(alloc, c);
    }
    if (sc.at >= sc.text.len) return error.BadString;
    sc.at += 1;
    return out.toOwnedSlice(alloc);
}

const Literal = struct { head: []const u8, expr: []const u8 };

/// If the statement is a wish, "ldr r0, =something": the part before the
/// `=` and the something.
fn takeLiteral(text: []const u8) ?Literal {
    const comma = std.mem.indexOfScalar(u8, text, ',') orelse return null;
    const after = std.mem.trimStart(u8, text[comma + 1 ..], " \t");
    if (after.len == 0 or after[0] != '=') return null;
    return .{ .head = text[0 .. comma + 1], .expr = after[1..] };
}

/// What pass 1 learns.
const Layout = struct {
    syms: Symbols = .{},
    /// The address of each literal-pool word, in the order the wishes
    /// appear in the file.
    literals: std.ArrayList(u32) = .empty,
    end: u32 = 0,

    fn deinit(lay: *Layout, alloc: std.mem.Allocator) void {
        lay.syms.map.deinit(alloc);
        lay.literals.deinit(alloc);
    }
};

/// Pass 1: where is everything? `line` follows along, for error messages.
fn layout(alloc: std.mem.Allocator, source: []const u8, base: u32, line: *usize) !Layout {
    var lay: Layout = .{};
    errdefer lay.deinit(alloc);
    var addr = base;
    var waiting: u32 = 0; // wishes since the last pool
    var lines = Lines.init(source);
    while (lines.next()) |full| {
        line.* = lines.number;
        var text = full;
        while (takeLabel(text)) |l| {
            if (lay.syms.map.contains(l.name)) return error.DuplicateLabel;
            try lay.syms.map.put(alloc, l.name, addr);
            text = l.rest;
        }
        if (text.len == 0) continue;
        var sc: Scanner = .{ .text = text };
        const first = sc.word();
        if (first.len == 0 or first[0] != '.') {
            // an instruction
            if (takeLiteral(text) != null) waiting += 1;
            addr += 4;
            continue;
        }
        switch (parseDirective(first) orelse return error.UnknownDirective) {
            .word => addr += 4 * countItems(&sc),
            .byte => addr += countItems(&sc),
            .ascii, .asciz => |d| {
                const bytes = try parseString(alloc, &sc);
                defer alloc.free(bytes);
                addr += @intCast(bytes.len + @intFromBool(d == .asciz));
            },
            .p2align => addr = alignUp(addr, @as(u32, 1) << @intCast(if (sc.done()) 2 else try sc.number())),
            .balign => addr = alignUp(addr, try sc.number()),
            .space => addr += try sc.number(),
            .equ => {
                const name = sc.word();
                try sc.need(',');
                try lay.syms.map.put(alloc, name, try sc.number());
            },
            .ltorg => {
                addr = try placePool(alloc, &lay, addr, waiting);
                waiting = 0;
            },
            .ignored => {},
        }
    }
    lay.end = try placePool(alloc, &lay, addr, waiting);
    return lay;
}

/// Gives each of the `waiting` wishes a word, starting at the next
/// multiple of 4 from addr. Returns the address after the pool.
fn placePool(alloc: std.mem.Allocator, lay: *Layout, addr: u32, waiting: u32) !u32 {
    if (waiting == 0) return addr;
    var at = alignUp(addr, 4);
    for (0..waiting) |_| {
        try lay.literals.append(alloc, at);
        at += 4;
    }
    return at;
}

/// An assembled program: its bytes, and where its labels ended up.
const Program = struct {
    code: []u8,
    base: u32,
    syms: Symbols,

    fn deinit(p: *Program, alloc: std.mem.Allocator) void {
        alloc.free(p.code);
        p.syms.map.deinit(alloc);
    }

    fn word(p: *const Program, addr: u32) u32 {
        return std.mem.readInt(u32, p.code[addr - p.base ..][0..4], .little);
    }
};

fn appendWord(alloc: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    // ARM here is little-endian: the least significant byte comes first.
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(alloc, &bytes);
}

fn padTo(alloc: std.mem.Allocator, out: *std.ArrayList(u8), size: usize) !void {
    while (out.items.len < size) try out.append(alloc, 0);
}

/// Assembles `source` to run at address `base`. If it fails and
/// `err_line` isn't null, the line number of the mistake is put there.
fn assemble(alloc: std.mem.Allocator, source: []const u8, base: u32, err_line: ?*usize) !Program {
    return assembleNoting(alloc, source, base, err_line, null);
}

/// assemble(), for a file that is only part of a program (229): with a
/// list in `uses`, every use of a name is added to it, and names that
/// aren't defined in this file are let through.
fn assembleNoting(alloc: std.mem.Allocator, source: []const u8, base: u32, err_line: ?*usize, uses: ?*std.ArrayList(SymbolUse)) !Program {
    var line: usize = 0;
    defer if (err_line) |e| {
        e.* = line;
    };
    var lay = try layout(alloc, source, base, &line);
    defer lay.literals.deinit(alloc);
    errdefer lay.syms.map.deinit(alloc);
    lay.syms.uses = uses;
    lay.syms.uses_alloc = alloc;

    // Pass 2: the bytes. The address of the next byte is base + out.items.len.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var wishes: std.ArrayList([]const u8) = .empty; // what each pool word should hold
    defer wishes.deinit(alloc);
    var granted: usize = 0; // pool words written so far
    var lines = Lines.init(source);
    while (lines.next()) |full| {
        line = lines.number;
        var text = full;
        while (takeLabel(text)) |l| text = l.rest;
        if (text.len == 0) continue;
        var sc: Scanner = .{ .text = text };
        const first = sc.word();
        const addr: u32 = base + @as(u32, @intCast(out.items.len));
        lay.syms.site = addr;
        lay.syms.absolute = false;
        if (first.len == 0 or first[0] != '.') {
            if (takeLiteral(text)) |lit| {
                // "ldr r0, =x" becomes "ldr r0, <address of its pool word>",
                // which 215 encodes as a pc-relative load.
                const pool_word = lay.literals.items[wishes.items.len];
                try wishes.append(alloc, lit.expr);
                var buf: [128]u8 = undefined;
                const rewritten = std.fmt.bufPrint(&buf, "{s} {d}", .{ lit.head, pool_word }) catch return error.LineTooLong;
                try appendWord(alloc, &out, try encodeLine(rewritten, addr, &lay.syms));
            } else {
                try appendWord(alloc, &out, try encodeLine(text, addr, &lay.syms));
            }
            continue;
        }
        switch (parseDirective(first).?) {
            .word => while (true) {
                lay.syms.site = base + @as(u32, @intCast(out.items.len));
                lay.syms.absolute = true;
                try appendWord(alloc, &out, try sc.value(&lay.syms));
                if (!sc.eat(',')) break;
            },
            .byte => while (true) {
                try out.append(alloc, @truncate(try sc.number()));
                if (!sc.eat(',')) break;
            },
            .ascii, .asciz => |d| {
                const bytes = try parseString(alloc, &sc);
                defer alloc.free(bytes);
                try out.appendSlice(alloc, bytes);
                if (d == .asciz) try out.append(alloc, 0);
            },
            .p2align => try padTo(alloc, &out, alignUp(addr, @as(u32, 1) << @intCast(if (sc.done()) 2 else try sc.number())) - base),
            .balign => try padTo(alloc, &out, alignUp(addr, try sc.number()) - base),
            .space => try padTo(alloc, &out, out.items.len + try sc.number()),
            .ltorg => granted = try writePool(alloc, &out, base, &lay, wishes.items, granted),
            .equ, .ignored => continue,
        }
        if (!sc.done()) return error.BadOperand;
    }
    _ = try writePool(alloc, &out, base, &lay, wishes.items, granted);
    std.debug.assert(base + out.items.len == lay.end); // the two passes must agree
    return .{ .code = try out.toOwnedSlice(alloc), .base = base, .syms = lay.syms };
}

/// Writes the pool words for the wishes not granted yet. Returns how
/// many have been granted now.
fn writePool(alloc: std.mem.Allocator, out: *std.ArrayList(u8), base: u32, lay: *Layout, wishes: []const []const u8, granted: usize) !usize {
    for (wishes[granted..], granted..) |expr, k| {
        try padTo(alloc, out, lay.literals.items[k] - base);
        var sc: Scanner = .{ .text = expr };
        lay.syms.site = lay.literals.items[k];
        lay.syms.absolute = true;
        try appendWord(alloc, out, try sc.value(&lay.syms));
        if (!sc.done()) return error.BadOperand;
    }
    return wishes.len;
}
