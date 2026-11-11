// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 210: lookup tables, and a chip you can rewire ───────────
//
// We can't etch transistors at home, and every project in this part has
// to build on the last one. The cheat: an FPGA, a chip full of generic
// logic whose wiring is decided by a file you load into it.
//
// Its building block is the *lookup table*. A LUT4 has four inputs and
// one output, and 16 bits of configuration memory: one stored answer for
// each of the 2^4 possible inputs. The inputs, read as a 4-bit number,
// pick which stored bit comes out (inside, that's a 16-to-1 multiplexer,
// which 209 could build from NANDs). So one LUT4 can be ANY function of
// four bits. AND, XOR, "is this number prime": all cost the same, and all
// are equally fast. Designing logic becomes filling in truth tables.
//
// A *logic cell* adds one flip-flop, a 1-bit memory that copies its input
// on the clock's rising edge, and a switch that picks whether the cell
// outputs the LUT's answer directly or the flip-flop's remembered one.
// Between the cells, more configuration bits steer each LUT input to a
// pin or to another cell's output. All those bits together are the
// *bitstream*. Change the bitstream and the same chip is a UART, or a
// CPU. (An iCE40 HX8K, a common hobby FPGA, has 7,680 such cells.)
//
// Nobody writes bitstreams by hand. A hardware description language says
// what the circuit should do, and a synthesis tool chooses the LUT
// contents and the routing. That language is the next chapter. Here, you
// are the synthesis tool.
//
// YOUR TASK: evaluate and fill a LUT, simulate a clock tick, and
// configure three cells into a counter.
//
const std = @import("std");

/// The output of a LUT4 with configuration `config` on inputs `in`
/// (input 0 is bit 0 of `in`): the stored bit number `in`.
fn lutEval(config: u16, in: u4) bool {
    return (config >> in) & 1 == 1;
}

/// The configuration that makes a LUT4 compute f: its truth table.
fn lutFor(f: *const fn (u4) bool) u16 {
    var config: u16 = 0;
    for (0..16) |i| {
        if (f(@intCast(i))) config |= @as(u16, 1) << @intCast(i);
    }
    return config;
}

/// Where a LUT input comes from: a pin of the chip, another cell's
/// output, or a constant.
const Source = union(enum) { pin: usize, cell: usize, zero, one };

/// One logic cell's share of the bitstream.
const Cell = struct {
    lut: u16,
    inputs: [4]Source = .{ .zero, .zero, .zero, .zero },
    /// true: output the flip-flop. false: output the LUT directly.
    registered: bool = false,
};

const max_cells = 8;

const Fpga = struct {
    cells: []const Cell, // the bitstream
    lut_out: [max_cells]bool = @splat(false), // each LUT's answer
    ff: [max_cells]bool = @splat(false), // each flip-flop
    out: [max_cells]bool = @splat(false), // each cell's output wire

    fn read(f: *const Fpga, s: Source, pins: []const bool) bool {
        return switch (s) {
            .pin => |i| pins[i],
            .cell => |i| f.out[i],
            .zero => false,
            .one => true,
        };
    }

    /// Let the signals spread through the LUTs until nothing changes.
    /// (One pass per cell is enough for any wiring without a loop.)
    fn settle(f: *Fpga, pins: []const bool) void {
        for (0..f.cells.len) |_| {
            for (f.cells, 0..) |c, i| {
                var in: u4 = 0;
                for (c.inputs, 0..) |s, k| {
                    if (f.read(s, pins)) in |= @as(u4, 1) << @intCast(k);
                }
                f.lut_out[i] = lutEval(c.lut, in);
                f.out[i] = if (c.registered) f.ff[i] else f.lut_out[i];
            }
        }
    }

    /// One rising clock edge: every flip-flop copies its LUT's answer, all
    /// at the same instant, and then the new values spread.
    fn tick(f: *Fpga, pins: []const bool) void {
        f.settle(pins);
        for (f.cells, 0..) |c, i| {
            if (c.registered) f.ff[i] = f.lut_out[i];
        }
        f.settle(pins);
    }
};

// ── a full adder is two LUTs ──

fn ones(in: u4) u3 {
    return @popCount(in);
}

fn sumBit(in: u4) bool {
    return ones(in & 0b111) & 1 == 1;
}

fn carryBit(in: u4) bool {
    return ones(in & 0b111) >= 2;
}

// ── a counter is one LUT function, three times ──

/// The next value of one counter bit. Input 0 is the bit's current value.
/// Inputs 1, 2 and 3 are "enable" and the lower bits of the counter
/// (unused ones are wired to .one). A bit of a binary counter flips
/// exactly when everything below it is 1: 0111 + 1 = 1000.
fn counterBit(in: u4) bool {
    const current = in & 1 == 1;
    const flip = in >> 1 == 0b111;
    return current != flip;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "a LUT is a truth table" {
    const and4: u16 = 0x8000; // only input 1111 gives 1
    try expect(lutEval(and4, 0b1111));
    try expect(!lutEval(and4, 0b0111));
    try expectEqual(@as(u16, 0xAAAA), lutFor(&struct {
        fn f(in: u4) bool {
            return in & 1 == 1; // just input 0
        }
    }.f));
    try expectEqual(@as(u16, 0x9696), lutFor(&sumBit));
    try expectEqual(@as(u16, 0xE8E8), lutFor(&carryBit));
}

test "a full adder in two cells" {
    const abc: [4]Source = .{ .{ .pin = 0 }, .{ .pin = 1 }, .{ .pin = 2 }, .zero };
    var fpga: Fpga = .{ .cells = &.{
        .{ .lut = lutFor(&sumBit), .inputs = abc },
        .{ .lut = lutFor(&carryBit), .inputs = abc },
    } };
    for (0..8) |v| {
        const pins = [_]bool{ v & 1 != 0, v & 2 != 0, v & 4 != 0 };
        fpga.settle(&pins);
        const total: usize = @popCount(v);
        try expectEqual(total & 1 == 1, fpga.out[0]);
        try expectEqual(total >= 2, fpga.out[1]);
    }
}

test "combinational cells settle through each other, in any order" {
    // cell 0 = NOT cell 1, cell 1 = NOT pin 0: listed "backwards"
    const inv = lutFor(&struct {
        fn f(in: u4) bool {
            return in & 1 == 0;
        }
    }.f);
    var fpga: Fpga = .{ .cells = &.{
        .{ .lut = inv, .inputs = .{ .{ .cell = 1 }, .zero, .zero, .zero } },
        .{ .lut = inv, .inputs = .{ .{ .pin = 0 }, .zero, .zero, .zero } },
    } };
    fpga.settle(&.{true});
    try expect(fpga.out[0] and !fpga.out[1]);
    fpga.settle(&.{false});
    try expect(!fpga.out[0] and fpga.out[1]);
}

test "three cells that count" {
    const lut = lutFor(&counterBit);
    const enable: Source = .{ .pin = 0 };
    var fpga: Fpga = .{ .cells = &.{
        .{ .lut = lut, .registered = true, .inputs = .{ .{ .cell = 0 }, enable, .one, .one } },
        .{ .lut = lut, .registered = true, .inputs = .{ .{ .cell = 1 }, enable, .{ .cell = 0 }, .one } },
        .{ .lut = lut, .registered = true, .inputs = .{ .{ .cell = 2 }, enable, .{ .cell = 0 }, .{ .cell = 1 } } },
    } };
    const value = struct {
        fn of(f: *const Fpga) usize {
            return @as(usize, @intFromBool(f.out[0])) + 2 * @as(usize, @intFromBool(f.out[1])) + 4 * @as(usize, @intFromBool(f.out[2]));
        }
    }.of;
    for (0..20) |i| {
        try expectEqual(i % 8, value(&fpga));
        fpga.tick(&.{true});
    }
    // enable low: the clock ticks and nothing moves
    const before = value(&fpga);
    fpga.tick(&.{false});
    fpga.tick(&.{false});
    try expectEqual(before, value(&fpga));
}

test "a flip-flop only changes on the tick" {
    // one registered cell that copies pin 0
    var fpga: Fpga = .{ .cells = &.{
        .{ .lut = 0xAAAA, .registered = true, .inputs = .{ .{ .pin = 0 }, .zero, .zero, .zero } },
    } };
    fpga.settle(&.{true});
    try expect(!fpga.out[0]); // the pin changed, the output hasn't
    fpga.tick(&.{true});
    try expect(fpga.out[0]);
    fpga.settle(&.{false});
    try expect(fpga.out[0]); // remembered
}
