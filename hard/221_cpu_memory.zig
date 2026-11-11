//
// ─── Exercise 221: loads and stores, and a third state ────────────────
//
// 220's processor computes, but it can only reach its 15 registers. This
// exercise gives it the bus: `ldr`, `str` and their byte forms. With them
// it runs everything 218's emulator runs.
//
// First, WHERE. 218's loadStore(), as wires:
//
//   offset      12 bits of the instruction, or (bit 25) a shifted
//               register: the barrel shifter already has it on sh_out
//   moved       the base register plus (bit 23, U) or minus the offset
//   addr        [rn, #n] uses `moved`; [rn], #n uses rn as it was (bit 24, P)
//   updates_rn  rn becomes `moved` for [rn], #n and for [rn, #n]! (bit 21, W)
//
// A STORE fits in EXEC. While the instruction is being executed, the
// processor takes the bus away from pc: it puts `addr` on the address
// wires, the register's value on the data wires, and raises the write
// strobes. At the clock edge that ends the cycle, the memory takes it.
//
// The strobes are how a byte gets written into a memory made of 32-bit
// words: there are four of them, one per byte of the word, and only the
// raised ones are written. `strb` to address 0x1002 raises strobe 2 of
// the word at 0x1000. So that it needn't steer the byte, the processor
// puts it on all four byte lanes at once; the strobe picks the lane.
//
// A LOAD doesn't fit. EXEC can put the address on the bus, but a block
// RAM answers at the NEXT edge (220), and by then EXEC is over. So a
// load gets a state of its own:
//
//   EXEC    put addr on the bus. Store nothing: stay on this instruction
//           (keep pc, don't retire), and go to LOAD.
//   LOAD    the memory's answer is on mem_rdata now. This is the cycle
//           that finishes the instruction: rn and rd get their new
//           values, pc moves on, and the instruction retires.
//
// In LOAD the instruction is no longer on the memory's wires (the data
// is), which is what insn_q was for: EXEC saved a copy. Every decoded
// wire (rn, rd, addr, ...) reads the copy during LOAD, and since EXEC
// changed no register, they all still say what they said in EXEC.
//
// A byte load gets the whole word and picks its byte out: `loaded` below
// does that, and is ready for you to use.
//
// So instructions now take different times: a load three cycles, the
// rest two. Real ARM7s are like this too (their manuals count "S", "N"
// and "I" cycles per instruction).
//
// YOUR TASK: the address, the write strobes, and what EXEC and LOAD do.
//
const std = @import("std");

/// Which address a load or store uses: `moved` or the plain `rn_val`.
const mem_address = ???;

/// The four write strobes. When not `storing`: none. For a byte
/// (`is_byte`): only the one for the byte the address's two low bits
/// name, which is 4'b0001 shifted left by them. For a word: all four.
const write_strobes = ???;

/// EXEC, for a load or store whose condition holds. The defaults above
/// it said: state <= FETCH, retired <= 1, pc <= pc + 4.
/// A load (`is_load`) overrides all three and changes no register.
/// A store is finished here; the bus wiring below does the storing
/// itself, and what is left for EXEC is rn, if `updates_rn`.
const exec_load_store = ???;

/// The LOAD state. rn first, if `updates_rn`; then `loaded` goes to rd
/// (so that when they are the same register, the load wins). As in 220,
/// rd == 15 means pc; otherwise pc moves on by 4. Then the instruction
/// is done: retire it, and back to FETCH.
const load_cycle = ???;

const bus_wiring =
    \\  // a load or a store: where, and what
    \\  wire is_load = insn[20];
    \\  wire is_byte = insn[22];
    \\  wire [31:0] offset = insn[25] ? sh_out : {20'b0, insn[11:0]};
    \\  wire [31:0] moved = insn[23] ? rn_val + offset : rn_val - offset;
    \\  wire updates_rn = !insn[24] || insn[21];
    \\  wire [31:0] addr =
++ " " ++ mem_address ++ ";\n" ++
    \\  // During EXEC of a load or store, the bus is the instruction's. Otherwise it fetches.
    \\  wire on_bus = (state == EXEC) && pass && is_mem;
    \\  wire storing = on_bus && !is_load;
    \\  assign mem_addr = on_bus ? addr : pc;
    \\  assign mem_wdata = is_byte ? {4{rd_val[7:0]}} : rd_val;
    \\  assign mem_wstrb =
++ " " ++ write_strobes ++ ";\n" ++
    \\  // what a load gets: the word, or one byte of it, with zeros above
    \\  wire [7:0] loaded_byte = mem_rdata >> {addr[1:0], 3'b000};
    \\  wire [31:0] loaded = is_byte ? {24'b0, loaded_byte} : mem_rdata;
    \\
;

/// The finished processor.
const arm_cpu = cpuSource(bus_wiring, exec_load_store, load_cycle);

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "a store takes two cycles, a load three" {
    const result = try cosim(arm_cpu,
        \\        mov   r1, #0x1000
        \\        mov   r0, #42
        \\        str   r0, [r1]
        \\        ldr   r2, [r1]
        \\        ldreq r3, [r1]            @ not run (Z is clear): two cycles, like anything skipped
        \\        swi   0
    );
    try expectEqual(@as(usize, 5), result.instructions);
    // two each, one more for the load, and the swi's own two
    try expectEqual(@as(usize, 2 * 5 + 1 + 2), result.cycles);
}

test "summing an array: three addressing modes" {
    _ = try cosim(arm_cpu,
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
        \\        ldr   r9, [r8]
        \\        ldr   r10, [r8, #-12]       @ numbers[3], from the other side
        \\        ldr   r6, [r6]              @ rn and rd the same: the load wins
        \\        swi   0
        \\numbers: .word 0x102, 0x304, 0x506, 0x708
        \\result: .word 0
    );
}

test "bytes: reversing a string in place" {
    _ = try cosim(arm_cpu,
        \\        ldr   r0, =text
        \\        add   r1, r0, #6            @ the last letter
        \\swap:   ldrb  r2, [r0]
        \\        ldrb  r3, [r1]
        \\        strb  r3, [r0], #1
        \\        strb  r2, [r1], #-1
        \\        cmp   r0, r1
        \\        blo   swap
        \\        ldr   r4, =text
        \\        ldr   r5, [r4]              @ "kcab", if every byte went to its own place
        \\        ldr   r6, [r4, #4]          @ "sdr" and the 0
        \\        ldr   r7, [r4, #8]          @ the neighbours are untouched
        \\        ldr   r8, [r4, #-4]
        \\        swi   0
        \\        .word 0x11223344
        \\text:   .asciz "drsback"
        \\        .word 0x55667788
    );
}

test "a stack: recursion, and returning by loading pc" {
    const result = try cosim(arm_cpu,
        \\        mov   sp, #0x10000
        \\        mov   r0, #6
        \\        bl    sum_to
        \\        swi   0
        \\@ sum_to(n) = n + sum_to(n - 1), and sum_to(0) = 0
        \\sum_to: cmp   r0, #0
        \\        moveq pc, lr
        \\        str   lr, [sp, #-4]!        @ push
        \\        str   r0, [sp, #-4]!
        \\        sub   r0, r0, #1
        \\        bl    sum_to
        \\        ldr   r1, [sp], #4          @ pop
        \\        add   r0, r0, r1
        \\        ldr   pc, [sp], #4          @ pop straight into pc: return
    );
    // 3 at the top, 9 for each of the six calls that recurse, 2 for the one that doesn't
    try expectEqual(@as(usize, 3 + 6 * 9 + 2), result.instructions);
}

test "a thousand random instructions with loads and stores, five times" {
    for (0..5) |seed| {
        const source = try randomProgram(std.testing.allocator, 221 + seed, 1000, true);
        defer std.testing.allocator.free(source);
        const result = try cosim(arm_cpu, source);
        try expectEqual(@as(usize, 1011), result.instructions);
    }
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

/// Runs Verilog source in Icarus Verilog and returns everything the
/// simulation printed. error.NoSimulator when iverilog isn't installed.
fn simulate(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa); // for everything but the result
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "design.v", .data = source });
    var dir_buf: [4096]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const v_path = try std.fs.path.join(alloc, &.{ dir, "design.v" });
    const vvp_path = try std.fs.path.join(alloc, &.{ dir, "design.vvp" });
    // 1. compile the design for the simulator...
    const compiled = std.process.run(alloc, io, .{
        .argv = &.{ "iverilog", "-g2012", "-o", vvp_path, v_path },
    }) catch |err| return if (err == error.FileNotFound) error.NoSimulator else err;
    if (compiled.term != .exited or compiled.term.exited != 0) {
        std.debug.print("iverilog failed:\n{s}\n", .{compiled.stderr});
        return error.VerilogError;
    }
    // 2. ...and run it. -n: stop at $finish instead of asking what to do.
    // A design can run forever (a bench that never reaches $finish, a
    // loop of gates that never settles), so give it a minute; run() stops
    // the simulator when the time is up.
    const minute: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } };
    const ran = std.process.run(alloc, io, .{
        .argv = &.{ "vvp", "-n", vvp_path },
        .cwd = .{ .path = dir },
        .timeout = minute.toDeadline(io),
    }) catch |err| {
        if (err == error.Timeout) std.debug.print("the simulation was still running after a minute: does it reach $finish?\n", .{});
        return err;
    };
    if (ran.term != .exited or ran.term.exited != 0) {
        std.debug.print("vvp failed:\n{s}\n{s}\n", .{ ran.stdout, ran.stderr });
        return error.SimulationFailed;
    }
    // Icarus announces "$finish called at ..." on stdout: leave that line out.
    var kept: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, ran.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "$finish called") != null) continue;
        try kept.appendSlice(alloc, line);
        if (lines.peek() != null) try kept.append(alloc, '\n');
    }
    return gpa.dupe(u8, kept.items);
}

/// simulate(), for a test: skips the test when there is no simulator.
fn simulateOrSkip(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    return simulate(gpa, source) catch |err| return if (err == error.NoSimulator) error.SkipZigTest else err;
}
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
/// hi, ls, ge, lt, gt, le (conditions 8 to 13): 217's table, as Verilog.
const cond_cases =
    \\      8: pass = c && !z;
    \\      9: pass = !c || z;
    \\      10: pass = (n == v);
    \\      11: pass = (n != v);
    \\      12: pass = !z && (n == v);
    \\      13: pass = z || (n != v);
;

const cond_module =
    \\module arm_cond(input [3:0] cond, input n, input z, input c, input v, output reg pass);
    \\  always @* begin
    \\    case (cond)
    \\      0: pass = z;
    \\      1: pass = !z;
    \\      2: pass = c;
    \\      3: pass = !c;
    \\      4: pass = n;
    \\      5: pass = !n;
    \\      6: pass = v;
    \\      7: pass = !v;
    \\
++ cond_cases ++
    \\
    \\      14: pass = 1;
    \\      default: pass = 0;
    \\    endcase
    \\  end
    \\endmodule
    \\
;

/// What goes into the adder for each subtracting operation. The defaults
/// (x = a, w = b, carry_in = 0) are already right for ADD and CMN, and
/// ADC is done for you. `begin ... end` groups several statements.
const adder_inputs =
    \\      SUB, CMP: begin w = ~b; carry_in = 1; end
    \\      SBC: begin w = ~b; carry_in = c_in; end
    \\      RSB: begin x = b; w = ~a; carry_in = 1; end
    \\      RSC: begin x = b; w = ~a; carry_in = c_in; end
;

/// The result and flags of an arithmetic operation, from the 33-bit sum.
/// Overflow (217): the result's sign differs from the sign of BOTH adder
/// inputs. `^` is XOR, on single bits here.
const adder_flags =
    \\      y = sum[31:0];
    \\      c = sum[32];
    \\      v = (x[31] ^ y[31]) & (w[31] ^ y[31]);
;

const alu_module =
    \\module arm_alu(
    \\  input [3:0] op, input [31:0] a, input [31:0] b,
    \\  input c_in, input v_in,      // the C and V flags before
    \\  input shifter_carry,         // the barrel shifter's carry out
    \\  output reg [31:0] y, output n, output z, output reg c, output reg v,
    \\  output writes                // 0 for tst, teq, cmp, cmn
    \\);
    \\  localparam AND = 0, EOR = 1, SUB = 2, RSB = 3, ADD = 4, ADC = 5, SBC = 6, RSC = 7,
    \\             TST = 8, TEQ = 9, CMP = 10, CMN = 11, ORR = 12, MOV = 13, BIC = 14, MVN = 15;
    \\  reg [31:0] x, w;      // the adder's two inputs
    \\  reg carry_in;
    \\  reg arithmetic;
    \\  reg [32:0] sum;
    \\  always @* begin
    \\    x = a; w = b; carry_in = 0; arithmetic = 1;
    \\    case (op)
    \\      ADD, CMN: begin end
    \\      ADC: carry_in = c_in;
    \\
++ adder_inputs ++
    \\
    \\      default: arithmetic = 0;
    \\    endcase
    \\    sum = {1'b0, x} + {1'b0, w} + {32'b0, carry_in};
    \\    if (arithmetic) begin
    \\
++ adder_flags ++
    \\
    \\    end else begin
    \\      case (op)
    \\        AND, TST: y = a & b;
    \\        EOR, TEQ: y = a ^ b;
    \\        ORR: y = a | b;
    \\        MOV: y = b;
    \\        BIC: y = a & ~b;
    \\        default: y = ~b;       // MVN
    \\      endcase
    \\      c = shifter_carry;
    \\      v = v_in;
    \\    end
    \\  end
    \\  assign n = y[31];
    \\  assign z = (y == 0);
    \\  assign writes = (op[3:2] != 2'b10);   // opcodes 8 to 11 only set flags
    \\endmodule
    \\
;

/// Shifts right by n, where n is 1 to 255 (0 was dealt with above).
/// LSR: zeros come in. Below 32 the last bit out is value[n - 1]; at
/// exactly 32 it is value[31]; beyond that it's 0. The result is 0 from
/// 32 up.
/// ASR: copies of the sign bit come in. From 32 up, the result is the
/// sign bit 32 times and the carry is the sign bit.
/// LSL, just above in the module, is the pattern to follow.
const right_shifts =
    \\        LSR: begin
    \\          out = (n < 32) ? value >> n : 0;
    \\          c_out = (n <= 32) ? value[n - 1] : 0;
    \\        end
    \\        ASR: begin
    \\          if (n < 32) begin
    \\            out = $signed(value) >>> n;
    \\            c_out = value[n - 1];
    \\          end else begin
    \\            out = {32{value[31]}};
    \\            c_out = value[31];
    \\          end
    \\        end
;

const shifter_module =
    \\module arm_shifter(
    \\  input [1:0] kind, input [31:0] value, input [7:0] amount,
    \\  input from_insn,   // the amount is an instruction's 5-bit field, where 0 is special
    \\  input c_in, output reg [31:0] out, output reg c_out
    \\);
    \\  localparam LSL = 0, LSR = 1, ASR = 2, ROR = 3;
    \\  reg [7:0] n;
    \\  always @* begin
    \\    n = amount;
    \\    if (from_insn && amount == 0 && (kind == LSR || kind == ASR)) n = 32;
    \\    out = value;       // the defaults: a shift by 0 changes nothing
    \\    c_out = c_in;
    \\    if (from_insn && amount == 0 && kind == ROR) begin
    \\      out = {c_in, value[31:1]};   // rrx: one place right, through the carry
    \\      c_out = value[0];
    \\    end else if (n != 0) begin
    \\      case (kind)
    \\        LSL: begin
    \\          out = (n < 32) ? value << n : 0;
    \\          c_out = (n <= 32) ? value[32 - n] : 0;
    \\        end
    \\
++ right_shifts ++
    \\
    \\        ROR: begin
    \\          out = (value >> n[4:0]) | (value << (6'd32 - n[4:0]));
    \\          c_out = out[31];
    \\        end
    \\      endcase
    \\    end
    \\  end
    \\endmodule
    \\
;

const datapath_modules = cond_module ++ alu_module ++ shifter_module;
/// Where a branch goes: pc + 8 + the offset in WORDS (bits 23..0, signed).
/// Widen it to 32 bits with copies of its sign bit, insn[23], on top
/// ({6{bit}} is six copies), and two zero bits below (that's "times 4").
const branch_target = "pc + 8 + {{6{insn[23]}}, insn[23:0], 2'b00}";

/// EXEC, for a branch whose condition holds. `bl` (bit 24 of the
/// instruction) first saves the return address in r[14]. The defaults
/// just above this in the module already said `pc <= pc + 4`: a later
/// `<=` to the same register wins (211).
const exec_branch =
    \\              if (insn[24]) r[14] <= pc + 4;
    \\              pc <= target;
;

/// EXEC, for a data-processing instruction. If it has the S bit, the four
/// flags take the ALU's (alu_n, alu_z, alu_c, alu_v). If the operation
/// produces a result (alu_writes; cmp and friends don't), alu_y goes to
/// register rd, and when rd is 15 that means: into pc.
const exec_data =
    \\              if (s_bit) begin
    \\                fn <= alu_n; fz <= alu_z; fc <= alu_c; fv <= alu_v;
    \\              end
    \\              if (alu_writes) begin
    \\                if (rd == 15) pc <= alu_y;
    \\                else r[rd] <= alu_y;
    \\              end
;

const cpu_part1 =
    \\module arm_cpu(
    \\  input clk, input reset,
    \\  output [31:0] mem_addr,     // the bus: which address,
    \\  output [31:0] mem_wdata,    // what to write there,
    \\  output [3:0] mem_wstrb,     // which of the word's four bytes to write (0: none),
    \\  input [31:0] mem_rdata,     // and what the memory read (one cycle later)
    \\  output reg halted,          // stopped at a swi
    \\  output reg retired          // high for one cycle after each finished instruction
    \\);
    \\  localparam FETCH = 0, EXEC = 1, LOAD = 2;
    \\  reg [1:0] state;
    \\  reg [31:0] r [0:14];
    \\  reg [31:0] pc;
    \\  reg fn, fz, fc, fv;
    \\  reg [31:0] insn_q;          // the instruction, kept for a LOAD cycle
    \\  wire [31:0] insn = (state == EXEC) ? mem_rdata : insn_q;
    \\
    \\  // decode: names for groups of bits
    \\  wire [3:0] rn = insn[19:16];
    \\  wire [3:0] rd = insn[15:12];
    \\  wire [3:0] rs = insn[11:8];
    \\  wire [3:0] rm = insn[3:0];
    \\  wire s_bit = insn[20];
    \\  wire is_swi = (insn[27:24] == 4'b1111);
    \\  wire is_branch = (insn[27:25] == 3'b101);
    \\  wire is_mul = (insn[27:22] == 6'b000000) && (insn[7:4] == 4'b1001);
    \\  wire is_dp = (insn[27:26] == 2'b00) && !is_mul;
    \\  wire is_mem = (insn[27:26] == 2'b01);
    \\
    \\  // the register file, read side. r15 reads as pc + 8.
    \\  wire [31:0] rn_val = (rn == 15) ? pc + 8 : r[rn];
    \\  wire [31:0] rd_val = (rd == 15) ? pc + 8 : r[rd];
    \\  wire [31:0] rs_val = (rs == 15) ? pc + 8 : r[rs];
    \\  wire [31:0] rm_val = (rm == 15) ? pc + 8 : r[rm];
    \\
    \\  wire pass;
    \\  arm_cond condition(insn[31:28], fn, fz, fc, fv, pass);
    \\
    \\  // Operand 2, through the barrel shifter. A constant is "8 bits,
    \\  // rotated right by twice the 4-bit rotate field": a ROR like any other.
    \\  wire dp_imm = is_dp && insn[25];
    \\  wire by_register = is_dp && !insn[25] && insn[4];
    \\  wire [31:0] sh_out;
    \\  wire sh_carry;
    \\  arm_shifter shifter(
    \\    dp_imm ? 2'd3 : insn[6:5],
    \\    dp_imm ? {24'b0, insn[7:0]} : rm_val,
    \\    dp_imm ? {3'b0, insn[11:8], 1'b0} : (by_register ? rs_val[7:0] : {3'b0, insn[11:7]}),
    \\    !dp_imm && !by_register,
    \\    fc, sh_out, sh_carry);
    \\
    \\  wire [31:0] alu_y;
    \\  wire alu_n, alu_z, alu_c, alu_v, alu_writes;
    \\  arm_alu alu(insn[24:21], rn_val, sh_out, fc, fv, sh_carry, alu_y, alu_n, alu_z, alu_c, alu_v, alu_writes);
    \\
    \\  wire [31:0] product = rm_val * rs_val;
    \\  wire [31:0] target =
++ " " ++ branch_target ++ ";\n\n";

const cpu_part2 =
    \\
    \\  always @(posedge clk) begin
    \\    retired <= 0;
    \\    if (reset) begin
    \\      pc <= 0; state <= FETCH; halted <= 0;
    \\      fn <= 0; fz <= 0; fc <= 0; fv <= 0;
    \\    end else if (!halted) begin
    \\      case (state)
    \\        FETCH: state <= EXEC;
    \\        EXEC: begin
    \\          // the defaults: this instruction is done, the next one follows it
    \\          insn_q <= mem_rdata;
    \\          state <= FETCH;
    \\          retired <= 1;
    \\          pc <= pc + 4;
    \\          if (pass) begin
    \\            if (is_swi) begin
    \\              halted <= 1; retired <= 0; pc <= pc;
    \\            end else if (is_branch) begin
    \\
++ exec_branch ++
    \\
    \\            end else if (is_mul) begin
    \\              r[rn] <= product;    // mul keeps its destination where rn usually is
    \\              if (s_bit) begin fn <= product[31]; fz <= (product == 0); end
    \\            end else if (is_dp) begin
    \\
++ exec_data ++
    \\
    \\            end else if (is_mem) begin
    \\
;

const cpu_part3 =
    \\
    \\            end else begin
    \\              halted <= 1; retired <= 0; pc <= pc;   // not an instruction we know
    \\            end
    \\          end
    \\        end
    \\        LOAD: begin
    \\
;

const cpu_part4 =
    \\
    \\        end
    \\        default: state <= FETCH;
    \\      endcase
    \\    end
    \\  end
    \\endmodule
    \\
;

/// The whole CPU, given the three pieces that deal with memory: the bus
/// wiring, what EXEC does for a load or store, and the LOAD state.
fn cpuSource(comptime bus: []const u8, comptime exec_mem: []const u8, comptime load_state: []const u8) []const u8 {
    return cpu_part1 ++ bus ++ cpu_part2 ++ exec_mem ++ cpu_part3 ++ load_state ++ cpu_part4;
}
// The bench: a clock, 64 KB of block RAM holding the program, and a line
// of text after every instruction, with pc, r0 to r14 and the flags.
const cosim_bench_head =
    \\module bench;
    \\  reg clk = 0;
    \\  reg reset = 1;
    \\  wire [31:0] addr, wdata;
    \\  wire [3:0] wstrb;
    \\  reg [31:0] rdata;
    \\  wire halted, retired;
    \\  reg [31:0] mem [0:16383];
    \\  arm_cpu dut(clk, reset, addr, wdata, wstrb, rdata, halted, retired);
    \\  always #1 clk = ~clk;
    \\  integer i;
    \\  integer cycles = 0;
    \\  always @(posedge clk) begin
    \\    rdata <= mem[addr[15:2]];   // a block RAM: the answer arrives at the next edge
    \\    if (wstrb[0]) mem[addr[15:2]][7:0] <= wdata[7:0];
    \\    if (wstrb[1]) mem[addr[15:2]][15:8] <= wdata[15:8];
    \\    if (wstrb[2]) mem[addr[15:2]][23:16] <= wdata[23:16];
    \\    if (wstrb[3]) mem[addr[15:2]][31:24] <= wdata[31:24];
    \\    if (!reset) cycles <= cycles + 1;
    \\  end
    \\  always @(posedge clk) if (retired)
    \\    $display("%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %b%b%b%b", dut.pc,
    \\      dut.r[0], dut.r[1], dut.r[2], dut.r[3], dut.r[4], dut.r[5], dut.r[6], dut.r[7],
    \\      dut.r[8], dut.r[9], dut.r[10], dut.r[11], dut.r[12], dut.r[13], dut.r[14],
    \\      dut.fn, dut.fz, dut.fc, dut.fv);
    \\  initial #4000000 begin $display("timeout"); $finish; end
    \\  initial begin
    \\    for (i = 0; i < 16384; i = i + 1) mem[i] = 0;
    \\    for (i = 0; i < 15; i = i + 1) dut.r[i] = 0;
    \\
;

const cosim_bench_tail =
    \\    repeat (2) @(negedge clk);
    \\    reset = 0;
    \\    wait (halted);
    \\    @(negedge clk);
    \\    $display("halted %0d", cycles);
    \\    $finish;
    \\  end
    \\endmodule
    \\
;

const Cosim = struct { instructions: usize, cycles: usize };

/// Runs the assembly `source` on the Verilog CPU and on 218's emulator,
/// from address 0, until a swi, and checks that they agree after every
/// instruction.
fn cosim(cpu_verilog: []const u8, source: []const u8) !Cosim {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var line_no: usize = 0;
    const prog = assemble(alloc, source, 0, &line_no) catch |err| {
        std.debug.print("assembling failed on line {d}: {s}\n", .{ line_no, @errorName(err) });
        return err;
    };

    var bench: std.Io.Writer.Allocating = .init(alloc);
    try bench.writer.writeAll(cosim_bench_head);
    var at: u32 = 0;
    while (at < prog.code.len) : (at += 4) try bench.writer.print("    mem[{d}] = 32'h{x};\n", .{ at / 4, prog.word(at) });
    try bench.writer.writeAll(cosim_bench_tail);
    const trace = try simulateOrSkip(alloc, try std.mem.concat(alloc, u8, &.{ datapath_modules, cpu_verilog, bench.written() }));

    var board = try Board.init(alloc, 0x10000);
    board.load(0, prog.code);
    var cpu: Cpu = .{};
    var lines = std.mem.tokenizeScalar(u8, trace, '\n');
    var count: usize = 0;
    while (true) : (count += 1) {
        const pc = cpu.r[PC];
        const insn = board.read(pc, 4) catch 0;
        const event = cpu.step(&board);
        const line = lines.next() orelse "(nothing: the simulation ended)";
        if (event != .ok) {
            // the emulator has reached the swi: so must the Verilog have
            if (std.mem.startsWith(u8, line, "halted ")) {
                return .{ .instructions = count, .cycles = try std.fmt.parseInt(usize, line["halted ".len..], 10) };
            }
            std.debug.print("\nafter {d} instructions the emulator stopped ({any}), but the Verilog CPU went on:\n  {s}\n", .{ count, event, line });
            return error.CpusDisagree;
        }
        // what the emulator says the state is now, in the bench's format
        var want: std.Io.Writer.Allocating = .init(alloc);
        try want.writer.print("{x:0>8}", .{cpu.r[PC]});
        for (cpu.r[0..15]) |value| try want.writer.print(" {x:0>8}", .{value});
        try want.writer.print(" {d}{d}{d}{d}", .{ @intFromBool(cpu.flags.n), @intFromBool(cpu.flags.z), @intFromBool(cpu.flags.c), @intFromBool(cpu.flags.v) });
        if (std.mem.eql(u8, want.written(), line)) continue;

        std.debug.print("\ninstruction {d}, the word 0x{x:0>8} at address 0x{x}: the CPUs disagree afterwards.\n", .{ count + 1, insn, pc });
        std.debug.print("            pc       r0       r1       r2       r3       r4       r5       r6       r7       r8       r9       r10      r11      r12      sp       lr       NZCV\n", .{});
        std.debug.print("  emulator  {s}\n  Verilog   {s}\n", .{ want.written(), line });
        return error.CpusDisagree;
    }
}
/// A random program of data-processing and multiply instructions, as
/// assembly source: `.word` lines, with a swi at the end. Registers r0 to
/// r7 are the playground.
fn randomProgram(alloc: std.mem.Allocator, seed: u64, count: usize, comptime with_memory: bool) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    // some starting values: constants that fit 8 bits anywhere, some inverted
    for (0..8) |reg| {
        try out.writer.print(" {s} r{d}, #0x{x}\n", .{ if (rand.boolean()) "mov" else "mvn", reg, std.math.rotr(u32, rand.int(u8), 2 * rand.uintLessThan(u32, 16)) });
    }
    if (with_memory) try out.writer.writeAll(" mov r8, #5\n mov r11, #0x4000\n mov r10, #0x8000\n");
    for (0..count) |_| {
        const cond: u32 = if (rand.uintLessThan(u8, 3) == 0) rand.uintLessThan(u32, 14) else 14;
        const reg = struct {
            fn pick(r: std.Random) u32 {
                return r.uintLessThan(u32, 8);
            }
        }.pick;
        var word: u32 = cond << 28;
        const roll = rand.uintLessThan(u8, 100);
        if (with_memory and roll < 30) {
            const load: u32 = rand.uintLessThan(u32, 2);
            const byte: u32 = rand.uintLessThan(u32, 2);
            word |= 1 << 26 | byte << 22 | load << 20 | reg(rand) << 12;
            switch (rand.uintLessThan(u8, 3)) {
                // [r11, #n]: a fixed base
                0 => word |= 1 << 24 | 1 << 23 | 11 << 16 | (if (byte == 1) rand.uintLessThan(u32, 1024) else 4 * rand.uintLessThan(u32, 256)),
                // [r11, r8, lsl #2]: r8 stays 5
                1 => word |= 1 << 25 | 1 << 24 | 1 << 23 | 11 << 16 | 2 << 7 | 8,
                // r10 wanders: [r10, #n]! and [r10], #n, up and down, in whole words
                else => {
                    const pre: u32 = rand.uintLessThan(u32, 2);
                    word |= pre << 24 | rand.uintLessThan(u32, 2) << 23 | pre << 21 | 10 << 16 | 4 * rand.uintLessThan(u32, 16);
                },
            }
        } else if (roll < 40) {
            const rd = reg(rand);
            var rm = reg(rand);
            if (rm == rd) rm = (rd + 1) % 8;
            word |= rand.uintLessThan(u32, 2) << 20 | rd << 16 | reg(rand) << 8 | 0b1001 << 4 | rm;
        } else {
            const op = rand.uintLessThan(u32, 16);
            const compare = op >= 8 and op <= 11;
            const s: u32 = if (compare) 1 else rand.uintLessThan(u32, 2);
            const rd: u32 = if (compare) 0 else reg(rand);
            const rn: u32 = if (op == 13 or op == 15) 0 else reg(rand);
            word |= op << 21 | s << 20 | rn << 16 | rd << 12;
            word |= switch (rand.uintLessThan(u8, 3)) {
                0 => 1 << 25 | rand.uintLessThan(u32, 4096), // a constant
                1 => rand.uintLessThan(u32, 32) << 7 | rand.uintLessThan(u32, 4) << 5 | reg(rand), // shifted by a constant
                else => reg(rand) << 8 | rand.uintLessThan(u32, 4) << 5 | 1 << 4 | reg(rand), // shifted by a register
            };
        }
        try out.writer.print(" .word 0x{x:0>8}\n", .{word});
    }
    try out.writer.writeAll(" swi 0\n");
    return out.toOwnedSlice();
}
