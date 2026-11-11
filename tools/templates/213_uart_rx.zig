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

//@export v_uart_rx
/// How many cycles START waits before checking the wire again, counting
/// from 0 like every counter here: the last cycle of HALF a bit.
const half_bit = ⟪"CLKS_PER_BIT / 2 - 1"|||???⟫;

/// The DATA state. On the last cycle of a bit time: restart clk_count,
/// shift `rx` into the top of `data`, and either move to STOP (this was
/// bit 7) or count the bit. On other cycles, count the cycle.
//⟪
const data_state =
    \\          if (clk_count == CLKS_PER_BIT - 1) begin
    \\            clk_count <= 0;
    \\            data <= {rx, data[7:1]};
    \\            if (bit_index == 7) state <= STOP;
    \\            else bit_index <= bit_index + 1;
    \\          end else begin
    \\            clk_count <= clk_count + 1;
    \\          end
;
//|||
const data_state = ???;
//⟫

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
//@end

/// The echo board: a receiver, a transmitter and an LED. Give the
/// transmitter the received byte, and start it when a byte is valid.
/// Then the LED: on each clock edge, if a valid byte is "1" the LED
/// becomes 1, and if it is "0" it becomes 0. (Verilog reads a string
/// like "1" as the number of its ASCII code, 8'h31.)
//⟪
const echo_wiring =
    \\  uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) transmitter(clk, valid, data, tx, busy);
    \\  always @(posedge clk) begin
    \\    if (valid && data == "1") led <= 1;
    \\    if (valid && data == "0") led <= 0;
    \\  end
;
//|||
const echo_wiring = ???;
//⟫

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
    \\    send("1"); send("h"); send("1"); send("k"); send("0"); send("k");
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
    // The sender's bits last 24 of our cycles where we expect 25. We
    // sample the middle of each bit by OUR clock, so we fall a cycle
    // further behind with every bit: by the stop bit, which the sender
    // holds from cycle 216 to 240, we sample at about 237, 9 cycles late
    // and still inside the bit.
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
    try std.testing.expectEqualStrings("1h1k0k", echoed);
    // Off at power-up, on at the first "1", off at the "0". Every other
    // byte is echoed but leaves the LED alone: "h" and "k" aren't
    // commands (though "k", 0x6b, is odd), and the second "1" changes
    // nothing.
    try std.testing.expectEqualStrings("010", leds.items);
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include verilog_sim
//@include v_uart_tx
//@include uart_decode
