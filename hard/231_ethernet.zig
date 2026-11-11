// HARD MODE (zig build -Dhard): no blanks to fill in. Every function
// marked ??? has lost its whole body: write it, from its doc comment,
// its signature and the tests. The gentler version of this file is in
// exercises/, and the answer in solutions/.
//
// ─── Exercise 231: Ethernet, and a checksum in gates ──────────────────
//
// The serial port moves ten bytes a millisecond to one neighbour. To
// load an operating system quickly, and later to talk to the world, the
// computer needs a network, and the bottom of nearly every network is
// Ethernet. What goes down the wire is a *frame*:
//
//   preamble   7 bytes 0x55, then 0xd5. On the wire (each byte goes low
//              bit first) that is 1010...1011: a rhythm the receiver
//              locks its clock to, and a final "11" that says "now".
//   to, from   two 6-byte addresses (the "MAC addresses" printed on
//              every network card)
//   type       2 bytes: what the payload is. 0x0800 means an IP packet.
//   payload    46 to 1500 bytes. Shorter ones are padded with zeros
//              (so that every frame is at least 64 bytes with its
//              check: a rule left over from when a frame had to be long
//              enough to collide with).
//   check      4 bytes: a CRC-32 of everything from `to` on
//
// The CRC is the interesting part, because it shows hardware and
// software thinking differently about the same sum. A CRC treats the
// whole message as one enormous binary number and takes the remainder
// of dividing it by a fixed 33-bit constant, in arithmetic where adding
// has no carries: it is just XOR. Long division, one bit at a time:
//
//     for each bit of the message:
//         does the incoming bit differ from the register's low bit?
//         shift the register right one place
//         if it did: XOR the constant 0xEDB88320 into the register
//
// In software that's a loop, eight turns per byte. In hardware it is a
// 32-bit shift register with a few XOR gates on it, that keeps up with
// the wire at any speed, which is the reason this checksum was chosen.
// Ethernet starts the register at all ones, and sends the inverse of
// the final value, low bit first.
//
// It catches every burst of damaged bits up to 32 long. (It is no
// protection against anyone damaging the frame on purpose: a CRC is easy
// to fix up afterwards. That takes a cryptographic hash.)
//
// The transmitter below is a state machine like 212's: IDLE, PREAMBLE,
// DATA, CHECK. The test sends frames through it and compares every bit
// with the frame your Zig builds.
//
// YOUR TASK: the CRC, in Zig and in Verilog; the padding; and the
// transmitter's CHECK state.
//
const std = @import("std");

/// CRC-32, as Ethernet (and zip, and png) computes it.
fn crc32(bytes: []const u8) u32 {
    ???; // write this function's body
}

const min_payload = 46;

/// A whole frame, from the destination address to the check, without
/// the preamble. The caller frees it.
fn ethFrame(alloc: std.mem.Allocator, to: [6]u8, from: [6]u8, ether_type: u16, payload: []const u8) ![]u8 {
    ???; // write this function's body
}

/// One step of the CRC register, in Verilog: the value `crc` will have
/// after the bit `data_bit` has gone by. (`a ? b : c`, `^` and `>>` are
/// as in C; the constant is written 32'hEDB88320.)
const crc_step = ???;

/// The CHECK state: 32 cycles. Each sends the inverse of the register's
/// low bit and shifts the register down one place, so the next bit is
/// in position. `count` counts the cycles, from 0; after the last one
/// the state is IDLE again.
const check_state = ???;

const eth_tx_module =
    \\module eth_tx(
    \\  input clk,
    \\  input start,              // raise for one cycle: send frame[0 .. length - 1]
    \\  input [10:0] length,
    \\  output reg tx_en,         // high while tx_bit is part of a frame
    \\  output reg tx_bit
    \\);
    \\  reg [7:0] frame [0:1535]; // filled in by whoever wants to send
    \\  localparam IDLE = 0, PREAMBLE = 1, DATA = 2, CHECK = 3;
    \\  reg [1:0] state;
    \\  reg [10:0] byte_index;
    \\  reg [2:0] bit_index;
    \\  reg [5:0] count;
    \\  reg [31:0] crc;
    \\  initial begin state = IDLE; tx_en = 0; tx_bit = 0; end
    \\  wire data_bit = frame[byte_index][bit_index];
    \\  always @(posedge clk) begin
    \\    case (state)
    \\      IDLE: begin
    \\        tx_en <= 0;
    \\        count <= 0;
    \\        if (start) state <= PREAMBLE;
    \\      end
    \\      PREAMBLE: begin
    \\        // 64 bits: 1010...10, except that the last one is a 1 too
    \\        tx_en <= 1;
    \\        tx_bit <= ~count[0] | (count == 63);
    \\        count <= count + 1;
    \\        if (count == 63) begin
    \\          state <= DATA;
    \\          byte_index <= 0;
    \\          bit_index <= 0;
    \\          crc <= 32'hFFFFFFFF;
    \\        end
    \\      end
    \\      DATA: begin
    \\        tx_bit <= data_bit;
    \\        crc <=
++ " " ++ crc_step ++ ";\n" ++
    \\        bit_index <= bit_index + 1;
    \\        if (bit_index == 7) begin
    \\          byte_index <= byte_index + 1;
    \\          if (byte_index == length - 1) begin
    \\            state <= CHECK;
    \\            count <= 0;
    \\          end
    \\        end
    \\      end
    \\      CHECK: begin
    \\
++ check_state ++
    \\
    \\      end
    \\    endcase
    \\  end
    \\endmodule
    \\
;

/// The bytes of a bit stream ('0' and '1' characters), low bit first.
fn bitsToBytes(alloc: std.mem.Allocator, bits: []const u8) ![]u8 {
    if (bits.len % 8 != 0) return error.NotWholeBytes;
    const out = try alloc.alloc(u8, bits.len / 8);
    for (out, 0..) |*byte, n| {
        byte.* = 0;
        for (0..8) |k| {
            if (bits[n * 8 + k] == '1') byte.* |= @as(u8, 1) << @intCast(k);
        }
    }
    return out;
}

/// A received frame (without preamble): is its check right? The payload
/// (still with any padding) if so.
fn ethCheck(frame_bytes: []const u8) ![]const u8 {
    if (frame_bytes.len < 14 + min_payload + 4) return error.FrameTooShort;
    const body = frame_bytes[0 .. frame_bytes.len - 4];
    if (std.mem.readInt(u32, frame_bytes[body.len..][0..4], .little) != crc32(body)) return error.BadCheck;
    return body[14..];
}

const ta = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

test "CRC-32" {
    // the value every CRC-32 implementation is checked with
    try expectEqual(@as(u32, 0xcbf43926), crc32("123456789"));
    try expectEqual(@as(u32, 0), crc32(""));
    try expectEqual(@as(u32, 0xd202ef8d), crc32(&.{0}));
    var prng = std.Random.DefaultPrng.init(231);
    var buf: [300]u8 = undefined;
    for (0..20) |n| {
        prng.random().bytes(&buf);
        try expectEqual(std.hash.Crc32.hash(buf[0 .. n * 15]), crc32(buf[0 .. n * 15]));
    }
}

const mac_a = [6]u8{ 0x02, 0, 0, 0, 0, 0x0a };
const mac_b = [6]u8{ 0x02, 0, 0, 0, 0, 0x0b };

test "a frame" {
    const short = try ethFrame(ta, mac_b, mac_a, 0x0800, "hi");
    defer ta.free(short);
    try expectEqual(@as(usize, 64), short.len);
    try expectEqualSlices(u8, &mac_b, short[0..6]);
    try expectEqualSlices(u8, &mac_a, short[6..12]);
    try expectEqualSlices(u8, &.{ 0x08, 0x00, 'h', 'i', 0, 0 }, short[12..18]);
    try expectEqual(std.hash.Crc32.hash(short[0..60]), std.mem.readInt(u32, short[60..64], .little));
    try expectEqualSlices(u8, short[14..60], try ethCheck(short));

    const long = try ethFrame(ta, mac_b, mac_a, 0x0806, "x" ** 100);
    defer ta.free(long);
    try expectEqual(@as(usize, 14 + 100 + 4), long.len);
    try expectEqual(@as(usize, 100), (try ethCheck(long)).len);
    const exact = try ethFrame(ta, mac_b, mac_a, 0x0800, "y" ** 46);
    defer ta.free(exact);
    try expectEqual(@as(usize, 64), exact.len);
    try expectError(error.FrameTooLong, ethFrame(ta, mac_b, mac_a, 0x0800, "z" ** 1501));

    // one flipped bit anywhere, and the check fails
    for ([_]usize{ 0, 13, 14, 59, 60, 63 }) |where| {
        short[where] ^= 0x10;
        try expectError(error.BadCheck, ethCheck(short));
        short[where] ^= 0x10;
    }
    try expectError(error.FrameTooShort, ethCheck(short[0..63]));
    // A curiosity that receivers use: run the CRC over the frame AND its
    // check, and the answer is always the same number.
    try expectEqual(@as(u32, 0x2144df1c), crc32(short));
    try expectEqual(@as(u32, 0x2144df1c), crc32(long));
}

/// Sends `frame_bytes` (without their last 4 bytes: the transmitter
/// makes its own check) through eth_tx, twice, and returns the bits it
/// sent each time.
fn transmit(alloc: std.mem.Allocator, frame_bytes: []const u8) ![]u8 {
    var bench: std.Io.Writer.Allocating = .init(alloc);
    defer bench.deinit();
    try bench.writer.writeAll(eth_tx_module ++
        \\module bench;
        \\  reg clk = 0;
        \\  reg start = 0;
        \\  reg [10:0] length;
        \\  wire tx_en, tx_bit;
        \\  eth_tx dut(clk, start, length, tx_en, tx_bit);
        \\  always #1 clk = ~clk;
        \\  always @(negedge clk) if (tx_en) $write("%b", tx_bit);
        \\  initial #100000 $finish;
        \\  initial begin
        \\
    );
    const body = frame_bytes[0 .. frame_bytes.len - 4];
    for (body, 0..) |byte, n| try bench.writer.print("    dut.frame[{d}] = 8'h{x};\n", .{ n, byte });
    try bench.writer.print("    length = {d};\n", .{body.len});
    try bench.writer.writeAll(
        \\    repeat (2) begin
        \\      @(negedge clk); start = 1;
        \\      @(negedge clk); start = 0;
        \\      @(negedge tx_en);
        \\      $write("\n");
        \\      repeat (3) @(negedge clk);
        \\    end
        \\    $finish;
        \\  end
        \\endmodule
        \\
    );
    return simulateOrSkip(alloc, bench.written());
}

test "the transmitter, bit for bit" {
    var prng = std.Random.DefaultPrng.init(2310);
    var payload: [200]u8 = undefined;
    prng.random().bytes(&payload);
    for ([_]usize{ 2, 46, 200 }) |len| {
        const want = try ethFrame(ta, mac_b, mac_a, 0x0800, payload[0..len]);
        defer ta.free(want);
        const out = try transmit(ta, want);
        defer ta.free(out);
        var sent = std.mem.tokenizeScalar(u8, out, '\n');
        // twice: the second frame must not be confused by what the first left behind
        for (0..2) |_| {
            const bits = sent.next() orelse return error.NothingSent;
            try expectEqual((8 + want.len) * 8, bits.len);
            try std.testing.expectEqualStrings("10" ** 31 ++ "11", bits[0..64]);
            const got = try bitsToBytes(ta, bits[64..]);
            defer ta.free(got);
            try expectEqualSlices(u8, want, got);
            _ = try ethCheck(got);
        }
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
