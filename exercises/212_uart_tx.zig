//
// ─── Exercise 212: a UART that talks ──────────────────────────────────
//
// The first thing any new computer needs is a way to say something. The
// oldest and simplest is the serial port: one wire, one bit at a time. A
// UART ("universal asynchronous receiver/transmitter") sends each byte as
// a *frame* of ten bits:
//
//   idle  start   d0   d1   d2   d3   d4   d5   d6   d7   stop  idle
//   ────┐      ┌────┐                        ┌────┐      ┌─────────
//       └──────┘    └────────────────────────┘    └──────┘
//          0     1    0    0    0    0    0    1     0     1      'A' = 0x41
//
// The wire rests HIGH. A LOW *start bit* says "a byte is coming". Then
// the 8 data bits, least significant first, then a HIGH *stop bit*, so
// that the next start bit is a visible fall. There is no clock wire
// ("asynchronous"): both ends just agree on how long a bit lasts. At
// 115200 baud on a 50 MHz clock that is 50,000,000 / 115,200 ≈ 434 clock
// cycles per bit. In these tests it's 2, to keep the waveforms short.
//
// The transmitter is a shift register (flip-flops in a row, each handing
// its bit to the next) and two counters. When `start` is raised it loads
// the whole frame, stop bit on top and start bit at the bottom, and then
// shifts it out of the bottom, one place every CLKS_PER_BIT cycles.
//
// Verilog you need: {a, b, c} glues wires together into a wider one, the
// first on top. 1'b1 is a 1-bit-wide binary 1. shift[9:1] is bits 9 down
// to 1.
//
// YOUR TASK: the frame, the shifting, and (in Zig) a decoder that reads a
// byte back off the wire the way a receiver must.
//
const std = @import("std");

/// The 10-bit frame for `data`, sent from bit 0 upward.
const frame = ???;

/// While busy, on each clock edge: count this bit's cycles. On the bit's
/// last cycle (clk_count == CLKS_PER_BIT - 1) restart the count, shift the
/// frame one place down (bringing a 1 in at the top), and count the bit as
/// sent. Otherwise just count the cycle.
const shift_body = ???;

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

const tx_bench =
    \\module bench;
    \\  reg clk = 0;
    \\  reg start = 0;
    \\  reg [7:0] data = 0;
    \\  wire tx, busy;
    \\  uart_tx #(.CLKS_PER_BIT(2)) dut(clk, start, data, tx, busy);
    \\  always #1 clk = ~clk;
    \\  always @(negedge clk) $write("%b", tx);   // the waveform, one character per cycle
    \\  task send(input [7:0] b);
    \\    begin
    \\      @(negedge clk); data = b; start = 1;
    \\      @(negedge clk); start = 0;
    \\      while (busy) @(negedge clk);
    \\    end
    \\  endtask
    \\  initial #2000 $finish;   // a broken design must not run forever
    \\  initial begin
    \\    send(8'h41);
    \\    send(8'ha5);
    \\    repeat (2) @(negedge clk);
    \\    $write("\n");
    \\    $finish;
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
            const middle = ???;
            if (middle >= wave.len) return error.Truncated;
            if (wave[middle] == '1') byte |= ???;
        }
        const stop = i + 9 * clks_per_bit + clks_per_bit / 2;
        if (stop >= wave.len) return error.Truncated;
        if (wave[stop] != '1') return error.BadStopBit;
        try bytes.append(alloc, byte);
        i = stop + 1; // the rest of the stop bit is idle time
    }
    return bytes.toOwnedSlice(alloc);
}

const ta = std.testing.allocator;

test "decoding a waveform by hand" {
    // 'A' = 0x41 = 0100_0001, at 2 cycles per bit: start, 1 0 0 0 0 0 1 0, stop
    const out = try decodeUart(ta, "111" ++ "00" ++ "11" ++ "00" ++ "00" ++ "00" ++ "00" ++ "00" ++ "11" ++ "00" ++ "11" ++ "1", 2);
    defer ta.free(out);
    try std.testing.expectEqualStrings("A", out);
    // at 4 cycles per bit, the same wire reads differently: timing is the protocol
    const slow = try decodeUart(ta, "1" ++ "0000" ++ "1111" ++ "0000" ** 5 ++ "1111" ++ "0000" ++ "1111", 4);
    defer ta.free(slow);
    try std.testing.expectEqualStrings("A", slow);
    // A sloppy sender: its start bit runs two cycles long, so every later
    // edge is late. The middle of each bit is still the right value.
    const late = try decodeUart(ta, "1" ++ "000000" ++ "1111" ++ "0000" ** 5 ++ "1111" ++ "0000" ++ "1111", 4);
    defer ta.free(late);
    try std.testing.expectEqualStrings("A", late);
    try std.testing.expectError(error.BadStopBit, decodeUart(ta, "0" ** 20 ++ "1", 2));
    try std.testing.expectError(error.Truncated, decodeUart(ta, "1100110", 2));
}

test "the transmitter's waveform" {
    const wave = try simulateOrSkip(ta, uart_tx_module ++ tx_bench);
    defer ta.free(wave);
    const trimmed = std.mem.trim(u8, wave, "\n");
    // exactly: idle, then 0x41 as above, the wire resting high in between
    try std.testing.expect(std.mem.startsWith(u8, trimmed, "1" ++ "00" ++ "11" ++ "0000000000" ++ "11" ++ "00" ++ "11"));
    const bytes = try decodeUart(ta, trimmed, 2);
    defer ta.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x41, 0xa5 }, bytes);
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
