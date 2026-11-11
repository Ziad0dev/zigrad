//
// ─── Exercise 220: a processor, in gates ──────────────────────────────
//
// 218's loop, as a circuit. The registers are flip-flops; 219's three
// boxes are the logic between them; and a small state machine (213)
// walks through the loop, one state per clock cycle:
//
//   FETCH   put pc on the memory's address wires. The memory is a block
//           RAM, the kind an FPGA has: it answers on the NEXT clock edge.
//   EXEC    the instruction is now on the memory's data wires. Decode it
//           (that's just naming groups of its bits), let the shifter and
//           the ALU work on it, and at the clock edge at the end of the
//           cycle, store the results: registers, flags, the next pc.
//           Then back to FETCH.
//
// Notice what "decode" and "execute" are in hardware. Nothing happens in
// sequence inside EXEC. The instruction's bits fan out through wires to
// the register file, the shifter and the ALU, all at once; every possible
// result (the ALU's, the multiplier's, the branch target) is computed
// every cycle, whether it's wanted or not; and the `if`s at the bottom
// merely choose which of them the flip-flops will keep.
//
// The parts, in the module below:
//
//   r[0..14], pc, fn fz fc fv    the state. r15 is not stored: an
//                                instruction that reads it gets pc + 8.
//   insn, rn, rd, rs, rm         the instruction, and its register numbers
//   is_swi, is_branch, ...       what kind it is
//   pass                         does its condition hold? (arm_cond)
//   sh_out, sh_carry             operand 2, out of the barrel shifter
//   alu_y, alu_n, ...            the ALU's result and flags
//   product, target              the multiplier's result; where a branch goes
//
// Loads and stores need a third state, and are the next exercise. Until
// then, this processor stops when it meets one.
//
// The test is *co-simulation*. Each program runs on your Verilog CPU in
// the simulator, and in your Zig emulator from 218, and after EVERY
// instruction all 16 registers and the flags must be the same. When they
// aren't, the test tells you which instruction, and which register.
//
// YOUR TASK: a branch's target, and what EXEC stores for a branch and
// for a data-processing instruction.
//
const std = @import("std");

//@export v_cpu
/// Where a branch goes: pc + 8 + the offset in WORDS (bits 23..0, signed).
/// Widen it to 32 bits with copies of its sign bit, insn[23], on top
/// ({6{bit}} is six copies), and two zero bits below (that's "times 4").
const branch_target = ⟪"pc + 8 + {{6{insn[23]}}, insn[23:0], 2'b00}"|||???⟫;

/// EXEC, for a branch whose condition holds. `bl` (bit 24 of the
/// instruction) first saves the return address in r[14]. The defaults
/// just above this in the module already said `pc <= pc + 4`: a later
/// `<=` to the same register wins (211).
//⟪
const exec_branch =
    \\              if (insn[24]) r[14] <= pc + 4;
    \\              pc <= target;
;
//|||
const exec_branch = ???;
//⟫

/// EXEC, for a data-processing instruction. If it has the S bit, the four
/// flags take the ALU's (alu_n, alu_z, alu_c, alu_v). If the operation
/// produces a result (alu_writes; cmp and friends don't), alu_y goes to
/// register rd, and when rd is 15 that means: into pc.
//⟪
const exec_data =
    \\              if (s_bit) begin
    \\                fn <= alu_n; fz <= alu_z; fc <= alu_c; fv <= alu_v;
    \\              end
    \\              if (alu_writes) begin
    \\                if (rd == 15) pc <= alu_y;
    \\                else r[rd] <= alu_y;
    \\              end
;
//|||
const exec_data = ???;
//⟫

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
//@end

/// This exercise's CPU: the bus only ever fetches, and a load or store
/// stops the processor.
const cpu_without_memory = cpuSource(
    \\  assign mem_addr = pc;
    \\  assign mem_wdata = 0;
    \\  assign mem_wstrb = 0;
,
    \\              halted <= 1; retired <= 0; pc <= pc;
,
    \\          state <= FETCH;
);

//@export cosim
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
//@end

//@export cpu_fuzz
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
//@end

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "count to ten, two clock cycles per instruction" {
    const result = try cosim(cpu_without_memory,
        \\        mov   r0, #0
        \\loop:   add   r0, r0, #1
        \\        cmp   r0, #10
        \\        bne   loop
        \\        swi   0
    );
    try expectEqual(@as(usize, 1 + 3 * 10), result.instructions);
    // FETCH and EXEC for each, and the swi's own two
    try expectEqual(2 * result.instructions + 2, result.cycles);
}

test "conditions, shifts and flags" {
    _ = try cosim(cpu_without_memory,
        \\        mvn   r0, #41             @ -42
        \\        cmp   r0, #0
        \\        rsblt r0, r0, #0          @ runs
        \\        cmp   r0, #0
        \\        rsblt r0, r0, #0          @ doesn't
        \\        mov   r1, #0x80000000
        \\        movs  r2, r1, lsl #1      @ carry out, zero
        \\        movs  r3, r1, asr #31     @ all ones
        \\        mov   r4, #33
        \\        movs  r5, r3, lsr r4      @ by a register, past 32
        \\        adds  r6, r3, #1          @ carry, no overflow
        \\        adc   r7, r7, #0
        \\        .word 0xe1b08060          @ movs r8, r0, rrx: "ror #0", through the carry
        \\        subs  r9, r1, #1          @ overflow
        \\        orrvs r9, r9, #0xff000000
        \\        teq   r0, r0
        \\        andeq r10, r3, r0, lsl #4
        \\        mul   r11, r0, r0
        \\        muls  r12, r11, r1
        \\        swi   0
    );
}

test "calling a function and coming back" {
    const result = try cosim(cpu_without_memory,
        \\        mov   r0, #3
        \\        bl    triple
        \\        bl    triple
        \\        add   r1, pc, #0          @ pc reads as this address + 8
        \\        swi   0
        \\triple: add   r0, r0, r0, lsl #1
        \\        mov   pc, lr
    );
    try expectEqual(@as(usize, 8), result.instructions);
}

test "a thousand random instructions, five times" {
    for (0..5) |seed| {
        const source = try randomProgram(std.testing.allocator, 220 + seed, 1000, false);
        defer std.testing.allocator.free(source);
        const result = try cosim(cpu_without_memory, source);
        try expectEqual(@as(usize, 1008), result.instructions);
    }
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include verilog_sim
//@include arm_enc
//@include arm_alu
//@include arm_asm_line
//@include arm_asm
//@include arm_emu
//@include v_datapath
