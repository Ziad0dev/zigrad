//
// ─── Exercise 213: a UART that listens, and memory-mapped pins ────────
//
// Receiving is the harder half. The sender's clock is not ours: its bits
// arrive whenever they arrive, and each lasts only *about* CLKS_PER_BIT of
// our cycles. So the receiver is a little state machine:
//
//   IDLE   wait for the wire to fall: maybe a start bit
//   START  wait HALF a bit, to the middle of the start bit. Still low?
//          Then it's real (a shorter dip was noise: back to IDLE).
//   DATA   every CLKS_PER_BIT cycles we are at the middle of the next
//          data bit: sample it. Eight times.
//   STOP   one more bit time. The wire must be high again; then pulse
//          `valid` for one cycle, with the byte on `data`.
//
// Sampling in the middle is what makes this robust: the two clocks may
// disagree by a few percent, and after ten bits we are still inside the
// right bit. (That is also why a frame is short. A longer one would
// drift off the end.)
//
// Bits arrive least significant first, so each new bit enters `data` at
// the TOP and pushes the older ones down: after eight of them the first
// to arrive sits at bit 0.
//
// A state machine in Verilog is a `case` on a state register:
//
//     case (state)
//       IDLE: if (rx == 0) state <= START;
//       ...
//     endcase
//
// With both halves you have a serial port. The second half of this
// exercise wires them into the classic first test of any new board, an
// echo: every byte that arrives is sent straight back. And it makes
// received bytes DO something: '1' turns an LED on, '0' turns it off.
// That is the whole idea of *memory-mapped I/O*, which the CPU will use
// from 220 on: a device is some registers, and software controls it by
// writing values into them. Here the "software" is whoever is typing.
//
// YOUR TASK: the half-bit wait, the DATA state, and the echo's wiring.
//
const std = @import("std");

/// How many cycles START waits before checking the wire again, counting
/// from 0 like every counter here: the last cycle of HALF a bit.
const half_bit = ???;

/// The DATA state. On the last cycle of a bit time: restart clk_count,
/// shift `rx` into the top of `data`, and either move to STOP (this was
/// bit 7) or count the bit. On other cycles, count the cycle.
const data_state = ???;

const uart_rx_module =
    \\module uart_rx #(parameter CLKS_PER_BIT = 434) (
    \\  input clk,
    \\  input rx,                // the serial wire
    \\  output reg [7:0] data,   // the byte received...
    \\  output reg valid         // ...when this is high, for one cycle
    \\);
    \\  localparam IDLE = 0, START = 1, DATA = 2, STOP = 3;
    \\  reg [1:0] state;
    \\  reg [15:0] clk_count;
    \\  reg [2:0] bit_index;
    \\  initial begin state = IDLE; clk_count = 0; bit_index = 0; data = 0; valid = 0; end
    \\  always @(posedge clk) begin
    \\    valid <= 0;   // unless a later line says otherwise
    \\    case (state)
    \\      IDLE: begin
    \\        clk_count <= 0;
    \\        bit_index <= 0;
    \\        if (rx == 0) state <= START;
    \\      end
    \\      START: begin
    \\        if (clk_count ==
++ " " ++ half_bit ++ ") begin\n" ++
    \\          clk_count <= 0;
    \\          state <= (rx == 0) ? DATA : IDLE;
    \\        end else begin
    \\          clk_count <= clk_count + 1;
    \\        end
    \\      end
    \\      DATA: begin
    \\
++ data_state ++
    \\
    \\      end
    \\      STOP: begin
    \\        if (clk_count == CLKS_PER_BIT - 1) begin
    \\          valid <= rx;   // no stop bit, no byte
    \\          state <= IDLE;
    \\        end else begin
    \\          clk_count <= clk_count + 1;
    \\        end
    \\      end
    \\    endcase
    \\  end
    \\endmodule
    \\
;

/// The echo board: a receiver, a transmitter and an LED. Give the
/// transmitter the received byte, and start it when a byte is valid.
/// Then the LED: on each clock edge, if a valid byte is "1" the LED
/// becomes 1, and if it is "0" it becomes 0. (Verilog reads a string
/// like "1" as the number of its ASCII code, 8'h31.)
const echo_wiring = ???;

const echo_module =
    \\module echo #(parameter CLKS_PER_BIT = 434) (input clk, input rx, output tx, output reg led);
    \\  wire [7:0] data;
    \\  wire valid, busy;
    \\  initial led = 0;
    \\  uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) receiver(clk, rx, data, valid);
    \\  // uart_tx's ports, in order: (clk, start, data, tx, busy)
    \\
++ echo_wiring ++
    \\
    \\endmodule
    \\
;

// The bench plays the far end of the cable: it wiggles `rx` with its own
// timing, BIT clock cycles per bit, which a test can set a little off.
const rx_bench =
    \\module bench;
    \\  parameter BIT = 8;
    \\  reg clk = 0;
    \\  reg rx = 1;
    \\  wire [7:0] data;
    \\  wire valid;
    \\  uart_rx #(.CLKS_PER_BIT(8)) dut(clk, rx, data, valid);
    \\  always #1 clk = ~clk;
    \\  always @(posedge clk) if (valid) $display("got %h", data);
    \\  task send(input [7:0] b, input stop);
    \\    integer k;
    \\    begin
    \\      rx = 0; repeat (BIT) @(negedge clk);
    \\      for (k = 0; k < 8; k = k + 1) begin rx = b[k]; repeat (BIT) @(negedge clk); end
    \\      rx = stop; repeat (BIT) @(negedge clk);
    \\      rx = 1;
    \\    end
    \\  endtask
    \\  initial #20000 $finish;   // a broken design must not run forever
    \\  initial begin
    \\    repeat (3) @(negedge clk);
    \\    send(8'h41, 1);
    \\    send(8'ha5, 1);
    \\    send(8'h00, 1);
    \\    send(8'hff, 1);
    \\    rx = 0; repeat (2) @(negedge clk); rx = 1;   // a glitch: not a start bit
    \\    repeat (100) @(negedge clk);
    \\    send(8'h37, 0);                               // a frame with no stop bit
    \\    rx = 1; repeat (20) @(negedge clk);
    \\    send(8'h5a, 1);
    \\    repeat (20) @(negedge clk);
    \\    $finish;
    \\  end
    \\endmodule
    \\
;

const echo_bench =
    \\module bench;
    \\  reg clk = 0;
    \\  reg rx = 1;
    \\  wire tx, led;
    \\  echo #(.CLKS_PER_BIT(4)) dut(clk, rx, tx, led);
    \\  always #1 clk = ~clk;
    \\  always @(negedge clk) $write("%b", tx);
    \\  always @(led) $display("\nled %b", led);
    \\  task send(input [7:0] b);
    \\    integer k;
    \\    begin
    \\      rx = 0; repeat (4) @(negedge clk);
    \\      for (k = 0; k < 8; k = k + 1) begin rx = b[k]; repeat (4) @(negedge clk); end
    \\      rx = 1; repeat (4) @(negedge clk);
    \\      // The echo has nowhere to keep a byte that arrives while it is
    \\      // still sending the last one (a real UART has a small queue),
    \\      // so this sender pauses between bytes.
    \\      repeat (8) @(negedge clk);
    \\    end
    \\  endtask
    \\  initial #20000 $finish;   // a broken design must not run forever
    \\  initial begin
    \\    send("h"); send("i"); send("1"); send("0"); send("1");
    \\    repeat (60) @(negedge clk);
    \\    $write("\n");
    \\    $finish;
    \\  end
    \\endmodule
    \\
;

const ta = std.testing.allocator;

/// The bench with its sender's bit time changed.
fn benchWithBit(comptime bit: []const u8) []const u8 {
    return uart_rx_module ++ "module top; bench #(.BIT(" ++ bit ++ ")) b(); endmodule\n" ++ rx_bench;
}

test "receiving bytes, ignoring a glitch and a broken frame" {
    const out = try simulateOrSkip(ta, benchWithBit("8"));
    defer ta.free(out);
    try std.testing.expectEqualStrings("got 41\ngot a5\ngot 00\ngot ff\ngot 5a\n", out);
}

test "a sender whose clock runs 4% fast still gets through" {
    // The sender's bits last 24 of our cycles where we expect 25. By the
    // stop bit we sample 10 cycles early, and are still inside the bit.
    const src = comptime blk: {
        var s: []const u8 = uart_rx_module ++ rx_bench;
        s = replace(s, "uart_rx #(.CLKS_PER_BIT(8))", "uart_rx #(.CLKS_PER_BIT(25))");
        break :blk s ++ "module top; bench #(.BIT(24)) b(); endmodule\n";
    };
    const out = try simulateOrSkip(ta, src);
    defer ta.free(out);
    try std.testing.expectEqualStrings("got 41\ngot a5\ngot 00\ngot ff\ngot 5a\n", out);
}

fn replace(comptime s: []const u8, comptime from: []const u8, comptime to: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, s, from).?;
    return s[0..at] ++ to ++ s[at + from.len ..];
}

test "the echo board" {
    const out = try simulateOrSkip(ta, uart_tx_module ++ uart_rx_module ++ echo_module ++ echo_bench);
    defer ta.free(out);
    // the bench prints the tx waveform, interrupted by a line whenever the LED changes
    var wave: std.ArrayList(u8) = .empty;
    defer wave.deinit(ta);
    var leds: std.ArrayList(u8) = .empty;
    defer leds.deinit(ta);
    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "led ")) {
            try leds.append(ta, line[4]);
        } else try wave.appendSlice(ta, line);
    }
    const echoed = try decodeUart(ta, wave.items, 4);
    defer ta.free(echoed);
    try std.testing.expectEqualStrings("hi101", echoed);
    try std.testing.expectEqualStrings("0101", leds.items); // off at power-up, then 1, 0, 1
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
    const ran = try std.process.run(alloc, io, .{ .argv = &.{ "vvp", "-n", vvp_path }, .cwd = .{ .path = dir } });
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
/// The 10-bit frame for `data`, sent from bit 0 upward.
const frame = "{1'b1, data, 1'b0}";

/// While busy, on each clock edge: count this bit's cycles. On the bit's
/// last cycle (clk_count == CLKS_PER_BIT - 1) restart the count, shift the
/// frame one place down (bringing a 1 in at the top), and count the bit as
/// sent. Otherwise just count the cycle.
const shift_body =
    \\      if (clk_count == CLKS_PER_BIT - 1) begin
    \\        clk_count <= 0;
    \\        shift <= {1'b1, shift[9:1]};
    \\        bits_left <= bits_left - 1;
    \\      end else begin
    \\        clk_count <= clk_count + 1;
    \\      end
;

const uart_tx_module =
    \\module uart_tx #(parameter CLKS_PER_BIT = 434) (
    \\  input clk,
    \\  input start,        // raise for one cycle to send `data`
    \\  input [7:0] data,
    \\  output tx,          // the serial wire
    \\  output busy         // high while a frame is going out
    \\);
    \\  reg [9:0] shift;
    \\  reg [3:0] bits_left;
    \\  reg [15:0] clk_count;
    \\  initial begin shift = 10'h3ff; bits_left = 0; clk_count = 0; end
    \\  assign busy = (bits_left != 0);
    \\  assign tx = busy ? shift[0] : 1'b1;
    \\  always @(posedge clk) begin
    \\    if (!busy) begin
    \\      if (start) begin
    \\        shift <=
++ " " ++ frame ++ ";\n" ++
    \\        bits_left <= 10;
    \\        clk_count <= 0;
    \\      end
    \\    end else begin
    \\
++ shift_body ++
    \\
    \\    end
    \\  end
    \\endmodule
    \\
;
/// Reads the bytes off a serial waveform: one character per clock cycle,
/// '1' for high. A receiver has no clock from the sender. It waits for
/// the wire to fall, and from that moment takes each bit's value at the
/// MIDDLE of the bit, where it is furthest from both edges.
fn decodeUart(alloc: std.mem.Allocator, wave: []const u8, clks_per_bit: usize) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(alloc);
    var i: usize = 0;
    while (i < wave.len) {
        if (wave[i] == '1') { // idle
            i += 1;
            continue;
        }
        // The start bit begins at cycle i. Bit k of the data comes k + 1
        // bits later; its middle is another half bit in.
        var byte: u8 = 0;
        for (0..8) |k| {
            const middle = i + (k + 1) * clks_per_bit + clks_per_bit / 2;
            if (middle >= wave.len) return error.Truncated;
            if (wave[middle] == '1') byte |= @as(u8, 1) << @intCast(k);
        }
        const stop = i + 9 * clks_per_bit + clks_per_bit / 2;
        if (stop >= wave.len) return error.Truncated;
        if (wave[stop] != '1') return error.BadStopBit;
        try bytes.append(alloc, byte);
        i = stop + 1; // the rest of the stop bit is idle time
    }
    return bytes.toOwnedSlice(alloc);
}
