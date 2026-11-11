//
// ─── Exercise 238: a disk, down one wire ──────────────────────────────
//
// Everything this computer knows vanishes when the power goes. It needs
// storage, and the cheapest storage there is, an SD card, will talk to
// anything that can wiggle four wires. The protocol is SPI:
//
//     sck    a clock, made by us (the *master*)
//     mosi   our data to the card,  one bit per clock tick
//     miso   the card's data to us, one bit per clock tick
//     cs     "I am talking to YOU" (low while we talk; not modelled here)
//
// SPI has no start bits and no baud rates, because the clock travels
// with the data. And every transfer is an *exchange*: while our eight
// bits go out on mosi, eight bits come in on miso, whether either side
// had anything to say or not. To "read" a byte, send 0xff and see what
// came back. The timing ("mode 0", which is what SD cards speak):
//
//                 ___     ___     ___
//     sck    ____|   |___|   |___|   |___     both sides SAMPLE on the
//     mosi   X bit 7  X bit 6  X bit 5  X     rising edge, and CHANGE
//                                              their data on the falling one
//
// Most significant bit first. That is all of the hardware: a shift
// register, again (212, 231).
//
// On top of it, the card speaks in *commands*: six bytes,
//
//     01cccccc   the command number, after the bits 0 and 1
//     4 bytes    an argument, big end first
//     xxxxxxx1   a 7-bit CRC of the five bytes before, and a final 1
//
// and answers each with a status byte, R1, whose top bit is 0 (so it
// can't be mistaken for the 0xff of an idle wire). The commands we use:
//
//     CMD0   reset. R1 = 0x01: "idle, not ready yet"
//     CMD1   start up. Repeat until R1 = 0x00: ready.
//     CMD17  read one 512-byte block. The argument is its BYTE address.
//            After R1 = 0x00 the card takes its time (0xff, 0xff, ...),
//            then sends 0xfe, "here it comes", the 512 bytes, and two
//            CRC bytes that nobody checks.
//     CMD24  write a block: the mirror image.
//
// A *block device* is anything that can read and write numbered blocks
// like this. Disks, SSDs, SD cards: the file system (239) will not care
// which.
//
// The first half of this exercise is the SPI master, in Verilog, tested
// against a little slave in the bench. The second half is the driver,
// in Zig, against a model of a card.
//
// YOUR TASK: the two edges of the shift register; the CRC and the
// command frame; and reading a block.
//
const std = @import("std");

/// At a RISING edge of sck: the bit on `miso` is shifted into `rx` from
/// the right, so that after eight of them the first to arrive is on top.
const spi_rising = ???;

/// At a FALLING edge: the bit just sent is done with. Shift `shift` one
/// place left (mosi is its top bit, so that brings the next bit out),
/// and count the bit as sent in `bits_left`.
const spi_falling = ???;

const spi_module =
    \\module spi_master #(parameter HALF = 2) (   // clock cycles per half period of sck
    \\  input clk,
    \\  input start,          // raise for one cycle to exchange a byte
    \\  input [7:0] tx,       // the byte to send
    \\  input miso,
    \\  output reg sck,
    \\  output mosi,
    \\  output busy,
    \\  output reg [7:0] rx   // the byte that came back, once busy is low again
    \\);
    \\  reg [7:0] shift;
    \\  reg [3:0] bits_left;
    \\  reg [7:0] count;
    \\  initial begin sck = 0; shift = 0; bits_left = 0; count = 0; rx = 0; end
    \\  assign busy = (bits_left != 0);
    \\  assign mosi = shift[7];
    \\  always @(posedge clk) begin
    \\    if (!busy) begin
    \\      if (start) begin
    \\        shift <= tx;
    \\        bits_left <= 8;
    \\        count <= 0;
    \\      end
    \\    end else if (count == HALF - 1) begin
    \\      count <= 0;
    \\      sck <= ~sck;
    \\      if (!sck) begin
    \\        // sck is about to rise
    \\
++ "        " ++ spi_rising ++ "\n" ++
    \\      end else begin
    \\        // sck is about to fall
    \\
++ spi_falling ++
    \\
    \\      end
    \\    end else begin
    \\      count <= count + 1;
    \\    end
    \\  end
    \\endmodule
    \\
;

/// The SD card's 7-bit CRC: long division like 231's, but most
/// significant bit first, with the constant 0x09, in a 7-bit register.
fn crc7(bytes: []const u8) u7 {
    var crc: u7 = 0;
    for (bytes) |byte| {
        for (0..8) |k| {
            const bit_in: u1 = @truncate(byte >> @intCast(7 - k));
            const top: u1 = @truncate(crc >> 6);
            crc <<= 1;
            if (???) crc ^= 0x09;
        }
    }
    return crc;
}

/// The six bytes of a command.
fn sdCommand(cmd: u6, arg: u32) [6]u8 {
    var frame_bytes: [6]u8 = undefined;
    frame_bytes[0] = ???;
    std.mem.writeInt(u32, frame_bytes[1..5], arg, ???);
    frame_bytes[5] = @as(u8, crc7(frame_bytes[0..5])) << 1 | 1;
    return frame_bytes;
}

const block_size = 512;

/// Sends a command and returns the card's R1. `spi` is anything with
/// exchange(byte) u8. The card may send up to 8 bytes of 0xff first.
fn sdSend(spi: anytype, cmd: u6, arg: u32) u8 {
    for (sdCommand(cmd, arg)) |byte| _ = spi.exchange(byte);
    for (0..8) |_| {
        const r1 = spi.exchange(0xff);
        if (r1 & 0x80 == 0) return r1;
    }
    return 0xff;
}

/// Wakes the card up.
fn sdInit(spi: anytype) !void {
    // a card wants to see 74 clock ticks before the first command
    for (0..10) |_| _ = spi.exchange(0xff);
    if (sdSend(spi, 0, 0) != 0x01) return error.NoCard;
    for (0..100) |_| {
        if (sdSend(spi, 1, 0) == 0x00) return;
    }
    return error.CardNotReady;
}

/// Reads block number `block`.
fn sdReadBlock(spi: anytype, block: u32, out: *[block_size]u8) !void {
    // the card counts in bytes
    if (sdSend(spi, 17, ???) != 0x00) return error.ReadRefused;
    // wait for the start token, but not forever
    var tries: usize = 0;
    while (spi.exchange(0xff) != ???) {
        tries += 1;
        if (tries == 100) return error.NoData;
    }
    for (out) |*byte| byte.* = ???;
    _ = spi.exchange(0xff); // the two CRC bytes
    _ = spi.exchange(0xff);
}

/// Writes block number `block`.
fn sdWriteBlock(spi: anytype, block: u32, data: *const [block_size]u8) !void {
    if (sdSend(spi, 24, block * block_size) != 0x00) return error.WriteRefused;
    _ = spi.exchange(0xfe);
    for (data) |byte| _ = spi.exchange(byte);
    _ = spi.exchange(0xff);
    _ = spi.exchange(0xff);
    // the card answers xxx00101 for "accepted"
    if (spi.exchange(0xff) & 0x1f != 0x05) return error.WriteFailed;
}

/// A model of an SD card on the other end of the wire. `disk` is its
/// contents, a multiple of 512 bytes.
const SdCard = struct {
    disk: []u8,
    ready_after: u8 = 2,
    ready: bool = false,
    command: [6]u8 = undefined,
    have: usize = 0,
    /// what it will send next
    reply: [block_size + 8]u8 = undefined,
    reply_len: usize = 0,
    reply_at: usize = 0,
    /// a write in progress: the address, and how many bytes have arrived (the token first)
    writing: ?u32 = null,
    written: usize = 0,
    /// how many bytes went over the wire, for the curious
    exchanged: usize = 0,

    fn say(card: *SdCard, bytes: []const u8) void {
        @memcpy(card.reply[0..bytes.len], bytes);
        card.reply_len = bytes.len;
        card.reply_at = 0;
    }

    fn exchange(card: *SdCard, mosi: u8) u8 {
        card.exchanged += 1;
        if (card.reply_at < card.reply_len) {
            card.reply_at += 1;
            return card.reply[card.reply_at - 1];
        }
        if (card.writing) |addr| {
            if (card.written == 0 and mosi != 0xfe) return 0xff; // waiting for the token
            card.written += 1;
            if (card.written >= 2 and card.written <= block_size + 1) card.disk[addr + card.written - 2] = mosi;
            if (card.written == block_size + 3) {
                card.writing = null;
                card.say(&.{0xe5}); // accepted
            }
            return 0xff;
        }
        if (card.have == 0 and mosi & 0xc0 != 0x40) return 0xff; // idle
        card.command[card.have] = mosi;
        card.have += 1;
        if (card.have < 6) return 0xff;
        card.have = 0;
        const cmd = card.command[0] & 0x3f;
        const arg = std.mem.readInt(u32, card.command[1..5], .big);
        if (card.command[5] != @as(u8, crc7(card.command[0..5])) << 1 | 1) {
            card.say(&.{ 0xff, 0x09 }); // CRC error
        } else if (cmd == 0) {
            card.ready = false;
            card.ready_after = 2;
            card.say(&.{ 0xff, 0x01 });
        } else if (cmd == 1) {
            if (card.ready_after > 0) card.ready_after -= 1 else card.ready = true;
            card.say(&.{ 0xff, @intFromBool(!card.ready) });
        } else if (!card.ready or (cmd != 17 and cmd != 24)) {
            card.say(&.{ 0xff, 0x05 }); // illegal command
        } else if (arg % block_size != 0 or arg + block_size > card.disk.len) {
            card.say(&.{ 0xff, 0x41 }); // address error
        } else if (cmd == 17) {
            card.say(&.{ 0xff, 0x00, 0xff, 0xff, 0xff, 0xfe });
            @memcpy(card.reply[6..][0..block_size], card.disk[arg..][0..block_size]);
            card.reply_len = 6 + block_size + 2;
        } else {
            card.say(&.{ 0xff, 0x00 });
            card.writing = arg;
            card.written = 0;
        }
        return 0xff;
    }
};

const ta = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

test "the SPI master, against a slave that answers each byte with the inverse of the one before" {
    const out = try simulateOrSkip(ta, spi_module ++
        \\module bench;
        \\  reg clk = 0;
        \\  reg start = 0;
        \\  reg [7:0] tx = 0;
        \\  wire sck, mosi, busy;
        \\  wire [7:0] rx;
        \\  // the slave: samples mosi when sck rises, changes miso when it falls
        \\  reg [7:0] s_in = 0;
        \\  reg [7:0] s_out = 8'ha5;
        \\  reg [3:0] s_bits = 0;
        \\  wire miso = s_out[7];
        \\  always @(posedge sck) begin
        \\    s_in <= {s_in[6:0], mosi};
        \\    s_bits <= s_bits + 1;
        \\  end
        \\  always @(negedge sck) begin
        \\    if (s_bits == 8) begin
        \\      $display("slave got %h", s_in);
        \\      s_out <= ~s_in;
        \\      s_bits <= 0;
        \\    end else s_out <= {s_out[6:0], 1'b0};
        \\  end
        \\  spi_master #(.HALF(3)) dut(clk, start, tx, miso, sck, mosi, busy, rx);
        \\  always #1 clk = ~clk;
        \\  integer rises = 0;
        \\  always @(posedge sck) rises = rises + 1;
        \\  task exchange(input [7:0] b);
        \\    begin
        \\      @(negedge clk); tx = b; start = 1;
        \\      @(negedge clk); start = 0;
        \\      while (busy) @(negedge clk);
        \\      $display("master got %h, sck is %b after %0d ticks", rx, sck, rises);
        \\    end
        \\  endtask
        \\  initial #5000 $finish;
        \\  initial begin
        \\    exchange(8'h40);
        \\    exchange(8'h95);
        \\    exchange(8'hff);
        \\    exchange(8'h00);
        \\    exchange(8'h01);
        \\    $finish;
        \\  end
        \\endmodule
        \\
    );
    defer ta.free(out);
    try std.testing.expectEqualStrings(
        \\slave got 40
        \\master got a5, sck is 0 after 8 ticks
        \\slave got 95
        \\master got bf, sck is 0 after 16 ticks
        \\slave got ff
        \\master got 6a, sck is 0 after 24 ticks
        \\slave got 00
        \\master got 00, sck is 0 after 32 ticks
        \\slave got 01
        \\master got ff, sck is 0 after 40 ticks
        \\
    , out);
}

test "the CRC and the frame" {
    try expectEqual(@as(u7, 0x4a), crc7(&.{ 0x40, 0, 0, 0, 0 }));
    // the two command frames every SD driver author knows by heart
    try expectEqualSlices(u8, &.{ 0x40, 0x00, 0x00, 0x00, 0x00, 0x95 }, &sdCommand(0, 0));
    try expectEqualSlices(u8, &.{ 0x48, 0x00, 0x00, 0x01, 0xaa, 0x87 }, &sdCommand(8, 0x1aa));
    try expectEqualSlices(u8, &.{ 0x51, 0x12, 0x34, 0x56, 0x00 }, sdCommand(17, 0x12345600)[0..5]);
}

fn testDisk() ![]u8 {
    const disk = try ta.alloc(u8, 16 * block_size);
    for (disk, 0..) |*byte, n| byte.* = @truncate(n / block_size * 16 + n % 13);
    return disk;
}

test "reading blocks" {
    const disk = try testDisk();
    defer ta.free(disk);
    var card: SdCard = .{ .disk = disk };
    var block: [block_size]u8 = undefined;
    try expectError(error.ReadRefused, sdReadBlock(&card, 0, &block)); // not woken up yet
    try sdInit(&card);
    for ([_]u32{ 0, 1, 7, 15, 3 }) |n| {
        try sdReadBlock(&card, n, &block);
        try expectEqualSlices(u8, disk[n * block_size ..][0..block_size], &block);
    }
    try expectError(error.ReadRefused, sdReadBlock(&card, 16, &block)); // past the end
    // and the card is still in step afterwards
    try sdReadBlock(&card, 2, &block);
    try expectEqualSlices(u8, disk[2 * block_size ..][0..block_size], &block);
    // one block costs: 6 command bytes, 2 to the R1, 4 to the token, 512, 2 of CRC
    const before = card.exchanged;
    try sdReadBlock(&card, 2, &block);
    try expectEqual(@as(usize, 6 + 2 + 4 + 512 + 2), card.exchanged - before);
}

test "writing a block and reading it back" {
    const disk = try testDisk();
    defer ta.free(disk);
    const before = try ta.dupe(u8, disk);
    defer ta.free(before);
    var card: SdCard = .{ .disk = disk };
    try sdInit(&card);
    var block: [block_size]u8 = undefined;
    for (&block, 0..) |*byte, n| byte.* = @truncate(n * 7);
    try sdWriteBlock(&card, 5, &block);
    var back: [block_size]u8 = undefined;
    try sdReadBlock(&card, 5, &back);
    try expectEqualSlices(u8, &block, &back);
    // the neighbours are untouched
    try sdReadBlock(&card, 4, &back);
    try expectEqualSlices(u8, before[4 * block_size ..][0..block_size], &back);
    try sdReadBlock(&card, 6, &back);
    try expectEqualSlices(u8, before[6 * block_size ..][0..block_size], &back);
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
