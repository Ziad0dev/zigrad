//
// ─── Exercise 222: a computer ─────────────────────────────────────────
//
// A processor with a bus and nothing on it is not a computer yet. This
// exercise puts things on the bus: 64 KB of RAM, and the UART from 212
// and 213, at the addresses 218's emulator has had them all along. A
// chip that holds a processor together with its memory and devices is a
// *system on a chip*, a SoC, and the module below is one.
//
// The glue is *address decoding*: look at the address on the bus, and
// decide who it is for.
//
//     0x00000000 ...   RAM
//     0x10000000       write: send this byte
//     0x10000004       read:  bit 0 = ready to send, bit 1 = a byte has arrived
//     0x10000008       read:  the byte that arrived (reading it takes it)
//
// Only the top of the address is compared. Anything whose top four bits
// are 0001 is the UART, and bits 3..2 pick the register. (So the UART
// also answers at 0x10000010, and at 0x1fffff00: comparing fewer bits is
// fewer gates, and nothing else lives there.)
//
// Each register is a few gates between the bus and the device:
//
//   send     a write to register 0 raises the transmitter's `start` for
//            that one cycle, with the bus's low byte as its data
//   status   reads as two wires: is the transmitter idle, and is a
//            received byte waiting
//   receive  uart_rx only *pulses* `valid` for a cycle (213), and the
//            processor is surely busy elsewhere in that cycle. So the
//            SoC catches the byte in a register, rx_byte, and remembers
//            in rx_have that it has one. Reading register 2 clears
//            rx_have: the byte has been taken.
//
// Reads answer the way the RAM does, one cycle after the address, so the
// processor needn't know who answered.
//
// Now the difference between an emulator and hardware shows. In 218,
// sending a byte took no time. Here it takes ten bit times, and a byte
// written while the last one is still going out is simply lost. So
// software must be polite: read the status register until bit 0 says
// "ready" and only then write. That loop is `putc` below, the first
// *device driver* of this course. `getc` is its twin, and yours.
//
// The tests run each program twice: on the SoC in the simulator, reading
// the answer off the `tx` wire with 212's decoder, and on 218's emulator.
//
// YOUR TASK: the decoding, the UART's registers, and getc.
//
const std = @import("std");

//@export soc
/// Is the address on the bus (`addr`, 32 bits) the UART's?
const uart_selected = ⟪"(addr[31:28] == 4'b0001)"|||???⟫;

/// The transmitter's `start`: the UART is selected (`sel_uart`), the
/// register (`uart_reg`) is number 0, and the processor is writing the
/// low byte (strobe 0 of `wstrb`).
const start_sending = ⟪"sel_uart && uart_reg == 0 && wstrb[0]"|||???⟫;

/// The status register, 32 bits: `rx_have` at bit 1, "the transmitter
/// is not busy" (`tx_busy`) at bit 0, zeros above.
const status_word = ⟪"{30'b0, rx_have, !tx_busy}"|||???⟫;

/// Inside the clocked block: the receive register. When the processor is
/// `taking` the byte, rx_have drops. When the receiver has a new one
/// (`rx_valid`, with the byte on `rx_data`), it goes into rx_byte and
/// rx_have rises. In that order: if both happen in the same cycle, the
/// new byte must not be forgotten.
//⟪
const receive_register =
    \\    if (taking) rx_have <= 0;
    \\    if (rx_valid) begin
    \\      rx_byte <= rx_data;
    \\      rx_have <= 1;
    \\    end
;
//|||
const receive_register = ???;
//⟫

const soc_module =
    \\module soc #(parameter CLKS_PER_BIT = 4) (
    \\  input clk, input reset,
    \\  input rx, output tx,        // the serial port
    \\  output halted
    \\);
    \\  wire [31:0] addr, wdata;
    \\  wire [3:0] wstrb;
    \\  wire retired;
    \\  reg [31:0] ram [0:16383];   // 64 KB, as 32-bit words
    \\  reg [31:0] ram_q;           // what the RAM read
    \\  reg [31:0] uart_q;          // what the UART's registers read
    \\  reg uart_answers;           // which of the two the processor asked
    \\
    \\  // address decoding
    \\  wire sel_uart =
++ " " ++ uart_selected ++ ";\n" ++
    \\  wire [1:0] uart_reg = addr[3:2];
    \\
    \\  arm_cpu cpu(clk, reset, addr, wdata, wstrb, uart_answers ? uart_q : ram_q, halted, retired);
    \\
    \\  // the UART and its registers
    \\  wire tx_busy, rx_valid;
    \\  wire [7:0] rx_data;
    \\  reg [7:0] rx_byte;
    \\  reg rx_have;
    \\  initial rx_have = 0;
    \\  wire tx_start =
++ " " ++ start_sending ++ ";\n" ++
    \\  uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) transmitter(clk, tx_start, wdata[7:0], tx, tx_busy);
    \\  uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) receiver(clk, rx, rx_data, rx_valid);
    \\  // The bus has no "read" wire. An address with no write strobes is a read.
    \\  wire taking = sel_uart && uart_reg == 2 && wstrb == 0;
    \\
    \\  always @(posedge clk) begin
    \\    ram_q <= ram[addr[15:2]];
    \\    if (!sel_uart) begin
    \\      if (wstrb[0]) ram[addr[15:2]][7:0] <= wdata[7:0];
    \\      if (wstrb[1]) ram[addr[15:2]][15:8] <= wdata[15:8];
    \\      if (wstrb[2]) ram[addr[15:2]][23:16] <= wdata[23:16];
    \\      if (wstrb[3]) ram[addr[15:2]][31:24] <= wdata[31:24];
    \\    end
    \\    uart_answers <= sel_uart;
    \\    case (uart_reg)
    \\      1: uart_q <=
++ " " ++ status_word ++ ";\n" ++
    \\      2: uart_q <= {24'b0, rx_byte};
    \\      default: uart_q <= 0;
    \\    endcase
    \\
++ receive_register ++
    \\
    \\  end
    \\endmodule
    \\
;

// The bench: the SoC, a far end of the serial cable that sends `input`,
// and the tx wire printed once per clock cycle.
const soc_bench_head =
    \\module bench;
    \\  parameter PACED = 0;
    \\  reg clk = 0;
    \\  reg reset = 1;
    \\  reg rx = 1;
    \\  wire tx, halted;
    \\  soc #(.CLKS_PER_BIT(4)) dut(clk, reset, rx, tx, halted);
    \\  always #1 clk = ~clk;
    \\  always @(negedge clk) if (!reset) $write("%b", tx);
    \\  task send(input [7:0] b);
    \\    integer k;
    \\    begin
    \\      // A paced sender waits until the last byte has been taken. (Real
    \\      // serial ports have a wire for this: "request to send".)
    \\      if (PACED) while (dut.rx_have) @(negedge clk);
    \\      rx = 0; repeat (4) @(negedge clk);
    \\      for (k = 0; k < 8; k = k + 1) begin rx = b[k]; repeat (4) @(negedge clk); end
    \\      rx = 1; repeat (8) @(negedge clk);   // the stop bit, and a breath
    \\    end
    \\  endtask
    \\  integer i;
    \\  initial #4000000 begin $display("\ntimeout"); $finish; end
    \\  initial begin
    \\    for (i = 0; i < 16384; i = i + 1) dut.ram[i] = 0;
    \\    for (i = 0; i < 15; i = i + 1) dut.cpu.r[i] = 0;
    \\
;

const soc_bench_tail =
    \\    wait (halted);
    \\    repeat (50) @(negedge clk);   // let the last byte leave
    \\    $write("\n");
    \\    $finish;
    \\  end
    \\endmodule
    \\
;

/// Puts `image` in the SoC's RAM at address 0, lets it run until a swi
/// while `input` arrives on the serial port, and returns the bytes it
/// sent. The caller frees them.
fn runOnSoc(gpa: std.mem.Allocator, image: []const u8, input: []const u8) ![]u8 {
    return runOnSocPaced(gpa, image, input, false);
}

/// runOnSoc(), where the sender can be told to wait for each byte to be
/// taken before it sends the next: for programs too slow to keep up.
fn runOnSocPaced(gpa: std.mem.Allocator, image: []const u8, input: []const u8, paced: bool) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var bench: std.Io.Writer.Allocating = .init(alloc);
    try bench.writer.writeAll(soc_bench_head);
    var at: usize = 0;
    while (at < image.len) : (at += 4) {
        var word: [4]u8 = @splat(0);
        const n = @min(4, image.len - at);
        @memcpy(word[0..n], image[at..][0..n]);
        try bench.writer.print("    dut.ram[{d}] = 32'h{x};\n", .{ at / 4, std.mem.readInt(u32, &word, .little) });
    }
    try bench.writer.writeAll("    repeat (2) @(negedge clk);\n    reset = 0;\n");
    for (input) |byte| try bench.writer.print("    send(8'h{x});\n", .{byte});
    try bench.writer.writeAll(soc_bench_tail);
    const top: []const u8 = if (paced) "module top; bench #(.PACED(1)) b(); endmodule\n" else "";
    const out = try simulateOrSkip(alloc, try std.mem.concat(alloc, u8, &.{ datapath_modules, arm_cpu, uart_tx_module, uart_rx_module, soc_module, top, bench.written() }));
    if (std.mem.indexOf(u8, out, "timeout") != null) return error.SocTimeout;
    return decodeUart(gpa, std.mem.trim(u8, out, "\n"), 4);
}

/// The same image and input on 218's emulator: what it sent, and how it
/// ended. The caller frees the bytes.
fn runOnEmulator(gpa: std.mem.Allocator, image: []const u8, input: []const u8) ![]u8 {
    var board = try Board.init(gpa, 0x10000);
    defer board.deinit();
    board.load(0, image);
    board.uart_in = input;
    var cpu: Cpu = .{};
    const event = cpu.run(&board, 1_000_000) orelse return error.EmulatorTimeout;
    if (event != .swi) return error.EmulatorStopped;
    return gpa.dupe(u8, board.uart_out.items);
}

/// r0 = the byte to send, r1 = the UART's address. Waits until the
/// transmitter is ready. Changes r2.
const putc_asm =
    \\putc:   ldr   r2, [r1, #4]        @ the status register
    \\        tst   r2, #1              @ ready to send?
    \\        beq   putc                @ not yet: ask again
    \\        str   r0, [r1]
    \\        mov   pc, lr
    \\
;
//@end

//@export getc_asm
/// r1 = the UART's address. Waits until a byte has arrived, and returns
/// it in r0. Changes r2. Five lines, like putc, starting with the label
/// `getc:`.
//⟪
const getc_asm =
    \\getc:   ldr   r2, [r1, #4]
    \\        tst   r2, #2
    \\        beq   getc
    \\        ldr   r0, [r1, #8]
    \\        mov   pc, lr
    \\
;
//|||
const getc_asm = ???;
//⟫
//@end

const ta = std.testing.allocator;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Assembles and runs `source` both ways.
fn expectOutputs(comptime source: []const u8, input: []const u8, on_soc: []const u8, on_emulator: []const u8) !void {
    var line_no: usize = 0;
    var prog = assemble(ta, source, 0, &line_no) catch |err| {
        std.debug.print("assembling failed on line {d}: {s}\n", .{ line_no, @errorName(err) });
        return err;
    };
    defer prog.deinit(ta);
    const emulated = try runOnEmulator(ta, prog.code, input);
    defer ta.free(emulated);
    try expectEqualStrings(on_emulator, emulated);
    const real = try runOnSoc(ta, prog.code, input);
    defer ta.free(real);
    try expectEqualStrings(on_soc, real);
}

test "hello, world" {
    const hello =
        \\        mov   r1, #0x10000000     @ the UART
        \\        ldr   r4, =text
        \\next:   ldrb  r0, [r4], #1
        \\        cmp   r0, #0
        \\        swieq 0
        \\        bl    putc
        \\        b     next
        \\text:   .asciz "Hello, world!\n"
        \\        .align 2
        \\
    ++ putc_asm;
    try expectOutputs(hello, "", "Hello, world!\n", "Hello, world!\n");
}

test "impolite software loses bytes, but only on hardware" {
    try expectOutputs(
        \\        mov   r1, #0x10000000
        \\        mov   r0, #65
        \\        str   r0, [r1]            @ "A"
        \\        mov   r0, #66
        \\        str   r0, [r1]            @ "B", while the A is still on the wire
        \\        swi   0
    , "", "A", "AB");
}

test "a line comes in, and goes back out reversed" {
    const reverse =
        \\        mov   r1, #0x10000000
        \\        ldr   r4, =buffer
        \\        mov   r5, r4
        \\read:   bl    getc
        \\        cmp   r0, #10             @ a newline ends the line
        \\        beq   reply
        \\        strb  r0, [r5], #1
        \\        b     read
        \\reply:  cmp   r5, r4
        \\        beq   done
        \\        ldrb  r0, [r5, #-1]!
        \\        bl    putc
        \\        b     reply
        \\done:   mov   r0, #10
        \\        bl    putc
        \\        swi   0
        \\
    ++ putc_asm ++ getc_asm ++
        \\buffer: .space 64
    ;
    try expectOutputs(reverse, "stressed\n", "desserts\n", "desserts\n");
    try expectOutputs(reverse, "\n", "\n", "\n");
}

test "only a write of the low byte of register 0 sends" {
    // Stores to the status and receive registers, a store to byte 1 of
    // register 0, and a load from register 0: none of them may send. Then
    // one real send. (On the SoC only: the emulator's UART stops a
    // program that does these odd things.)
    var line: usize = 0;
    var prog = try assemble(ta,
        \\        mov   r1, #0x10000000
        \\        mov   r0, #88             @ "X"
        \\        str   r0, [r1, #4]
        \\        str   r0, [r1, #8]
        \\        strb  r0, [r1, #1]
        \\        ldr   r2, [r1]
        \\        mov   r0, #89             @ "Y"
        \\        bl    putc
        \\        swi   0
        \\
    ++ putc_asm, 0, &line);
    defer prog.deinit(ta);
    const sent = try runOnSoc(ta, prog.code, "");
    defer ta.free(sent);
    try expectEqualStrings("Y", sent);
}

test "a byte that arrives just as the last one is taken is kept" {
    // The program does nothing but read the receive register. The bench
    // waits for a cycle in which it is doing so, and makes a new byte
    // arrive in that very cycle: rx_have must end up 1.
    var line: usize = 0;
    var prog = try assemble(ta,
        \\        mov   r1, #0x10000000
        \\again:  ldr   r0, [r1, #8]
        \\        b     again
    , 0, &line);
    defer prog.deinit(ta);
    var bench: std.Io.Writer.Allocating = .init(ta);
    defer bench.deinit();
    try bench.writer.writeAll(soc_bench_head);
    var at: usize = 0;
    while (at < prog.code.len) : (at += 4) try bench.writer.print("    dut.ram[{d}] = 32'h{x};\n", .{ at / 4, std.mem.readInt(u32, prog.code[at..][0..4], .little) });
    try bench.writer.writeAll(
        \\    repeat (2) @(negedge clk);
        \\    reset = 0;
        \\    repeat (10) @(negedge clk);
        \\    while (!dut.taking) @(negedge clk);
        \\    force dut.rx_valid = 1;
        \\    force dut.rx_data = 8'h5a;
        \\    @(negedge clk);
        \\    release dut.rx_valid;
        \\    release dut.rx_data;
        \\    $display("\nhave %b byte %h", dut.rx_have, dut.rx_byte);
        \\    $finish;
        \\  end
        \\endmodule
        \\
    );
    const source = try std.mem.concat(ta, u8, &.{ datapath_modules, arm_cpu, uart_tx_module, uart_rx_module, soc_module, bench.written() });
    defer ta.free(source);
    const out = try simulateOrSkip(ta, source);
    defer ta.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "have 1 byte 5a") != null);
}

test "a byte that nobody has taken yet waits in its register" {
    // The program is busy for a long time before it first looks: two
    // bytes have arrived by then, and with one register only the second
    // is still there. (The emulator's UART is kinder than a real one
    // here too: it queues everything.)
    try expectOutputs(
        \\        mov   r1, #0x10000000
        \\        mov   r3, #100
        \\busy:   subs  r3, r3, #1
        \\        bne   busy
        \\        ldr   r6, [r1, #4]        @ status: ready to send, and a byte waiting
        \\        add   r0, r6, #48
        \\        bl    putc
        \\        bl    getc
        \\        bl    putc
        \\        ldr   r6, [r1, #4]        @ status: it has been taken
        \\        and   r6, r6, #2
        \\        add   r0, r6, #48
        \\        bl    putc
        \\        swi   0
        \\
    ++ putc_asm ++ getc_asm, "xy", "3y0", "3x2");
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include verilog_sim
//@include v_uart_tx
//@include v_uart_rx
//@include uart_decode
//@include arm_enc
//@include arm_alu
//@include arm_asm_line
//@include arm_asm
//@include arm_emu
//@include v_datapath
//@include v_cpu
//@include v_cpu_mem
