// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 211: blinking an LED ────────────────────────────────────
//
// Chapter 43: bringup. What language is hardware coded in? Verilog. It
// looks like C and isn't. A Verilog file doesn't describe steps to run:
// it describes a circuit, and everything in it happens at once.
//
//   module blink(input clk, output reg led);   a box with pins
//     reg [31:0] count;                         32 flip-flops (210)
//     wire done = (count == 9);                 a wire, driven by LUTs
//     always @(posedge clk) begin               on every rising clock edge:
//       count <= count + 1;                       what each flip-flop
//     end                                         will hold NEXT
//   endmodule
//
// `<=` is the *non-blocking* assignment. Every right-hand side in every
// `always @(posedge clk)` block, in every module, is worked out from the
// values the flip-flops hold just BEFORE the edge. Then they all change
// together. So
//
//     a <= b;
//     b <= a;
//
// swaps a and b: both lines read the old values, in whatever order they
// are written. That is the same rule as tick() in 210. If two `<=` in one
// block assign the same register, the later one wins, which is how
// "count up, but restart at the limit" is usually written.
//
// The exercises in this part that say "Verilog" hold real Verilog, in Zig
// strings, and run it in a real simulator, Icarus Verilog (`iverilog`;
// it's in this repo's `nix develop` shell, and in most package managers).
// Without it, these tests are skipped. George Hotz's outline suggests
// Verilator, which compiles Verilog to C++ and is much faster; everything
// here is plain synthesizable Verilog that it accepts too.
//
// A board's clock is fast: at 50 MHz, an LED toggled every cycle just
// looks dim. To blink it you count clock cycles, and toggle only when
// the count reaches a limit.
//
// YOUR TASK: the swap, and the body of the blinker.
//
const std = @import("std");

/// What happens to a and b on each clock edge: they trade values.
const swap_body =
    \\    a <= b;
    \\    b <= a;
;

const swap_module =
    \\module swap(input clk, output reg [7:0] a, output reg [7:0] b);
    \\  initial begin a = 8'd3; b = 8'd7; end
    \\  always @(posedge clk) begin
    \\
++ swap_body ++
    \\
    \\  end
    \\endmodule
    \\
;

/// On each clock edge: count up. When `count` is HALF - 1, this is the
/// HALF-th cycle: go back to 0 and flip the LED (`~led` is NOT led).
/// Verilog's if/else looks like C's, with begin ... end for braces.
const blink_body =
    \\    if (count == HALF - 1) begin
    \\      count <= 0;
    \\      led <= ~led;
    \\    end else begin
    \\      count <= count + 1;
    \\    end
;

const blink_module =
    \\module blink #(parameter HALF = 25000000) (input clk, output reg led);
    \\  reg [31:0] count;
    \\  initial begin count = 0; led = 0; end
    \\  always @(posedge clk) begin
    \\
++ blink_body ++
    \\
    \\  end
    \\endmodule
    \\
;

// A *testbench* is Verilog that is never built into hardware. It exists
// to drive a design's pins in simulation and print what comes out. `#1`
// waits one time unit, so this clock rises every 2.
const swap_bench =
    \\module bench;
    \\  reg clk = 0;
    \\  wire [7:0] a, b;
    \\  swap dut(clk, a, b);
    \\  always #1 clk = ~clk;
    \\  integer i;
    \\  initial begin
    \\    for (i = 0; i < 3; i = i + 1) begin
    \\      @(negedge clk);
    \\      $display("%0d %0d", a, b);
    \\    end
    \\    $finish;
    \\  end
    \\endmodule
    \\
;

const blink_bench =
    \\module bench;
    \\  reg clk = 0;
    \\  wire led;
    \\  blink #(.HALF(3)) dut(clk, led);
    \\  always #1 clk = ~clk;
    \\  integer i;
    \\  initial begin
    \\    for (i = 0; i < 16; i = i + 1) begin
    \\      @(negedge clk);
    \\      $write("%b", led);
    \\    end
    \\    $write("\n");
    \\    $finish;
    \\  end
    \\endmodule
    \\
;

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

const ta = std.testing.allocator;

test "non-blocking assignments swap" {
    const out = try simulateOrSkip(ta, swap_module ++ swap_bench);
    defer ta.free(out);
    try std.testing.expectEqualStrings("7 3\n3 7\n7 3\n", out);
}

test "three cycles off, three cycles on" {
    const out = try simulateOrSkip(ta, blink_module ++ blink_bench);
    defer ta.free(out);
    try std.testing.expectEqualStrings("0011100011100011\n", out);
}
