//
// ─── Exercise 219: the same arithmetic, in gates ──────────────────────
//
// Now the processor as a circuit. It gets built the way 217 and 218 were,
// arithmetic first, and it gets checked the way real chips are: against
// the software model. Every test here feeds the same inputs to your
// Verilog and to your Zig from 217, and wants the same answers.
//
// Three boxes of *combinational* logic: no clock, no memory, outputs that
// just follow the inputs (after the signals have settled, 210).
//
//   arm_cond     flags + a condition  ->  should this instruction run?
//   arm_alu      a, b, an opcode      ->  result and new flags
//   arm_shifter  value, kind, amount  ->  shifted value and carry out
//
// Combinational Verilog is written as `always @*`: "whenever any input
// changes, work the outputs out again". Inside it, `=` (not `<=`) assigns,
// and the lines DO run in order, like software, as a description of one
// big tangle of gates:
//
//     always @* begin
//       y = a;                      a default...
//       if (invert) y = ~a;         ...overridden: this is a multiplexer
//     end
//
// One rule above all: every output must be assigned on EVERY path. An
// output that some path leaves alone has to remember its old value, and
// the synthesis tool will quietly build a memory element (a "latch")
// where you wanted plain gates. Defaults at the top are the usual cure.
//
// The ALU is designed around 217's observation: ONE adder does all the
// arithmetic, by choosing what goes into it. `x` and `w` are its inputs:
//
//     add  x = a, w = b,  carry in 0        sub  x = a, w = ~b, carry in 1
//     adc  x = a, w = b,  carry in C        sbc  x = a, w = ~b, carry in C
//     rsb  x = b, w = ~a, carry in 1        rsc  x = b, w = ~a, carry in C
//
// The adder is 33 bits wide, so the carry out is simply bit 32:
//     sum = {1'b0, x} + {1'b0, w} + carry_in;
//
// Verilog you need: `a[31]` is one bit, `a[7:0]` a range. `{32{bit}}` is
// the bit repeated 32 times. `>>` shifts in zeros. `$signed(v) >>> n` is
// the arithmetic shift, when it is a statement's whole right-hand side.
// `==`, `!=`, `&&`, `||`, `!` are as in C, and `c ? a : b` too.
//
// YOUR TASK: the six comparing conditions, the adder's inputs and flags,
// and two of the shifter's four shifts.
//
const std = @import("std");

/// hi, ls, ge, lt, gt, le (conditions 8 to 13): 217's table, as Verilog.
const cond_cases = ???;

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
const adder_inputs = ???;

/// The result and flags of an arithmetic operation, from the 33-bit sum.
/// Overflow (217): the result's sign differs from the sign of BOTH adder
/// inputs. `^` is XOR, on single bits here.
const adder_flags = ???;

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
const right_shifts = ???;

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

const ta = std.testing.allocator;

/// Runs a bench whose `initial` block is `body`, around the three modules.
fn runBench(comptime wires: []const u8, body: []const u8) ![]u8 {
    const source = try std.mem.concat(ta, u8, &.{ datapath_modules, "module bench;\n", wires, "  initial begin\n", body, "    $finish;\n  end\nendmodule\n" });
    defer ta.free(source);
    return simulateOrSkip(ta, source);
}

/// Compares the simulator's lines with the model's, and says which test
/// case went wrong.
fn expectSameLines(want: []const u8, got: []const u8, cases: []const u8) !void {
    var w = std.mem.splitScalar(u8, want, '\n');
    var g = std.mem.splitScalar(u8, got, '\n');
    var c = std.mem.splitScalar(u8, cases, '\n');
    while (w.next()) |want_line| {
        const got_line = g.next() orelse "";
        const case = c.next() orelse "";
        if (!std.mem.eql(u8, want_line, got_line)) {
            std.debug.print("\ncase:{s}\n  the Zig model says   {s}\n  the Verilog says     {s}\n", .{ case, want_line, got_line });
            return error.TestExpectedEqual;
        }
    }
}

fn b01(x: bool) u8 {
    return @intFromBool(x);
}

test "conditions: all 15, on all 16 flag settings" {
    var body: std.Io.Writer.Allocating = .init(ta);
    defer body.deinit();
    var want: std.Io.Writer.Allocating = .init(ta);
    defer want.deinit();
    for (0..15) |cond| for (0..16) |f| {
        const flags: Flags = .{ .n = f & 8 != 0, .z = f & 4 != 0, .c = f & 2 != 0, .v = f & 1 != 0 };
        try body.writer.print("    cond = {d}; {{n, z, c, v}} = {d}; #1 $display(\"%b\", pass);\n", .{ cond, f });
        try want.writer.print("{d}\n", .{b01(condPasses(@enumFromInt(cond), flags))});
    };
    const got = try runBench(
        \\  reg [3:0] cond; reg n, z, c, v; wire pass;
        \\  arm_cond dut(cond, n, z, c, v, pass);
        \\
    , body.written());
    defer ta.free(got);
    try expectSameLines(want.written(), got, body.written());
}

test "the ALU against 217's alu()" {
    var prng = std.Random.DefaultPrng.init(219);
    const rand = prng.random();
    const interesting = [_]u32{ 0, 1, 2, 0x7fffffff, 0x80000000, 0x80000001, 0xfffffffe, 0xffffffff };
    var body: std.Io.Writer.Allocating = .init(ta);
    defer body.deinit();
    var want: std.Io.Writer.Allocating = .init(ta);
    defer want.deinit();
    for (0..16) |op| for (0..60) |i| {
        const a = if (i % 3 == 0) interesting[rand.uintLessThan(usize, interesting.len)] else rand.int(u32);
        const b = if (i % 4 < 2) interesting[rand.uintLessThan(usize, interesting.len)] else rand.int(u32);
        const before: Flags = .{ .c = rand.boolean(), .v = rand.boolean() };
        const shifter_carry = rand.boolean();
        try body.writer.print("    op = {d}; a = 32'h{x}; b = 32'h{x}; c_in = {d}; v_in = {d}; sc = {d}; #1 $display(\"%h %b%b%b%b %b\", y, n, z, c, v, writes);\n", .{ op, a, b, b01(before.c), b01(before.v), b01(shifter_carry) });
        const r = alu(@enumFromInt(op), a, b, before, shifter_carry);
        try want.writer.print("{x:0>8} {d}{d}{d}{d} {d}\n", .{ r.value, b01(r.flags.n), b01(r.flags.z), b01(r.flags.c), b01(r.flags.v), b01(r.writes) });
    };
    const got = try runBench(
        \\  reg [3:0] op; reg [31:0] a, b; reg c_in, v_in, sc;
        \\  wire [31:0] y; wire n, z, c, v, writes;
        \\  arm_alu dut(op, a, b, c_in, v_in, sc, y, n, z, c, v, writes);
        \\
    , body.written());
    defer ta.free(got);
    try expectSameLines(want.written(), got, body.written());
}

test "the shifter against 217's barrelShift() and shiftByImmediate()" {
    var prng = std.Random.DefaultPrng.init(2190);
    const rand = prng.random();
    var body: std.Io.Writer.Allocating = .init(ta);
    defer body.deinit();
    var want: std.Io.Writer.Allocating = .init(ta);
    defer want.deinit();
    const amounts = [_]u8{ 0, 1, 2, 7, 8, 15, 16, 30, 31, 32, 33, 34, 63, 64, 65, 128, 255 };
    for (0..4) |kind| for (amounts) |amount| for (0..2) |from_insn| for (0..6) |i| {
        if (from_insn == 1 and amount > 31) continue;
        const value = switch (i) {
            0 => 0x80000001,
            1 => 0x7ffffffe,
            else => rand.int(u32),
        };
        const carry = rand.boolean();
        try body.writer.print("    kind = {d}; value = 32'h{x}; amount = {d}; from_insn = {d}; c_in = {d}; #1 $display(\"%h %b\", out, c_out);\n", .{ kind, value, amount, from_insn, b01(carry) });
        const k: Shift = @enumFromInt(kind);
        const r = if (from_insn == 1) shiftByImmediate(k, value, @intCast(amount), carry) else barrelShift(k, value, amount, carry);
        try want.writer.print("{x:0>8} {d}\n", .{ r.value, b01(r.carry) });
    };
    const got = try runBench(
        \\  reg [1:0] kind; reg [31:0] value; reg [7:0] amount; reg from_insn, c_in;
        \\  wire [31:0] out; wire c_out;
        \\  arm_shifter dut(kind, value, amount, from_insn, c_in, out, c_out);
        \\
    , body.written());
    defer ta.free(got);
    try expectSameLines(want.written(), got, body.written());
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
