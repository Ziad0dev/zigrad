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

//@export arm_emu
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
        return if (n == PC) ⟪pc +% 8|||???⟫ else cpu.r[n];
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
        const bytes: i32 = ⟪@as(i32, words) * 4|||???⟫;
        if (bit(insn, 24)) cpu.r[LR] = ⟪pc +% 4|||???⟫; // bl: where to come back to
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
        const addr = ⟪if (pre) moved else base|||???⟫;
        // rn itself changes for [rn], #n and for [rn, #n]!
        const updates_rn = ⟪!pre or writeback|||???⟫;

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
                4 => return 1 | @as(u32, @intFromBool(⟪b.uart_in.len > 0|||???⟫)) << 1,
                8 => {
                    if (b.uart_in.len == 0) return 0;
                    const byte = b.uart_in[0];
                    b.uart_in = ⟪b.uart_in[1..]|||???⟫; // reading the register takes the byte
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
        if (addr == uart_base) return b.uart_out.append(b.alloc, ⟪@truncate(value)|||???⟫);
        if (size == 1) {
            if (addr >= b.ram.len) return error.NoDevice;
            b.ram[addr] = @truncate(value);
            return;
        }
        if (addr % 4 != 0 or @as(usize, addr) + 4 > b.ram.len) return error.NoDevice;
        std.mem.writeInt(u32, b.ram[addr..][0..4], value, .little);
    }
};
//@end

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

//@include arm_enc
//@include arm_alu
//@include arm_asm_line
//@include arm_asm
