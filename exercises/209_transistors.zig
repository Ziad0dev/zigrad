//
// ─── Exercise 209: so about those transistors ─────────────────────────
//
// Part VII: from the transistor to the web browser. Parts I–VI built
// tinygrad down to kernels on a GPU. This part keeps going down, and then
// all the way back up: gates, a UART, a CPU, an assembler, a C compiler, a
// linker, a libc, an operating system, a file system, TCP, and a web
// browser, each one built on the ones before. It follows George Hotz's
// outline "From the Transistor to the Web Browser"
// (github.com/geohot/fromthetransistor), section by section.
//
// Chapter 42: cheating our way past the transistor. A transistor here is
// a switch with three wires. Voltage on the *gate* decides whether the
// other two are connected:
//
//   nMOS: conducts when its gate is HIGH (1). Good at pulling a wire to 0.
//   pMOS: conducts when its gate is LOW (0).  Good at pulling a wire to 1.
//
// CMOS logic builds every gate from two networks of them. The *pull-up*
// network, all pMOS, connects the output to the supply (1). The
// *pull-down* network, all nMOS, connects it to ground (0):
//
//        VDD ──┬──────┬──          NAND(a, b): the two pMOS are in
//         a ─o[p]  b ─o[p]         PARALLEL (either one pulls up), the
//              ├──────┴── out      two nMOS in SERIES (both are needed
//         a ──[n]                  to pull down). So out is 0 only when
//         b ──[n]                  a and b are both 1.
//        GND ──┘
//
// Exactly one network must conduct for every input. Both: a short circuit
// from supply to ground. Neither: the output floats at whatever charge it
// had. The trick that guarantees it: the two networks are *duals*.
// Series in one is parallel in the other, and pMOS conduct on the
// opposite gate value, so by De Morgan one is on exactly when the other
// is off.
//
// NAND is *universal*: every other gate, and so every computer, can be
// wired from NANDs alone. The rest of this exercise does that, up to a
// 4-bit adder: 240 transistors that can add.
//
// YOUR TASK: the pMOS, the NAND and NOR networks, and the gates built
// from NANDs.
//
const std = @import("std");

/// Does an nMOS transistor conduct, given its gate?
fn nmos(gate: bool) bool {
    return gate;
}

/// Does a pMOS transistor conduct?
fn pmos(gate: bool) bool {
    return ???;
}

const Wire = enum { low, high, floating, short };

/// What the output wire does, given whether each network conducts.
fn drive(pull_up: bool, pull_down: bool) Wire {
    if (pull_up and pull_down) return .short;
    if (pull_up) return .high;
    if (pull_down) return .low;
    return .floating;
}

/// An inverter: one pMOS up, one nMOS down, the same input on both gates.
fn notCmos(a: bool) Wire {
    return drive(pmos(a), nmos(a));
}

/// NAND: pMOS in parallel, nMOS in series (the picture above).
fn nandCmos(a: bool, b: bool) Wire {
    const pull_up = ???;
    const pull_down = ???;
    return drive(pull_up, pull_down);
}

/// NOR is NAND's mirror image: out is 1 only when a and b are both 0.
/// Which network is in series now?
fn norCmos(a: bool, b: bool) Wire {
    const pull_up = ???;
    const pull_down = ???;
    return drive(pull_up, pull_down);
}

// From here on, a wire is just a bool, and the only gate we may use is:

var nands_used: usize = 0;

fn nand(a: bool, b: bool) bool {
    nands_used += 1;
    return nandCmos(a, b) == .high;
}

/// NOT from one NAND: what do you get when both inputs are the same wire?
fn not(a: bool) bool {
    return ???;
}

/// AND is NAND, inverted.
fn andGate(a: bool, b: bool) bool {
    return ???;
}

/// OR, by De Morgan: a or b = not(not a and not b).
fn orGate(a: bool, b: bool) bool {
    return ???;
}

/// XOR from four NANDs. With m = nand(a, b):
///     xor = nand(nand(a, m), nand(b, m))
/// (When a and b are both 1, m is 0 and both inner NANDs give 1.)
fn xor(a: bool, b: bool) bool {
    const m = nand(a, b);
    return ???;
}

const SumCarry = struct { sum: bool, carry: bool };

/// Adds three bits. The sum bit is the XOR of all three. There is a carry
/// when at least two are 1: a and b both, or the carry in together with
/// exactly one of a and b.
fn fullAdder(a: bool, b: bool, carry_in: bool) SumCarry {
    const ab = xor(a, b);
    return .{
        .sum = ???,
        .carry = ???,
    };
}

/// A 4-bit ripple-carry adder: four full adders, each one's carry feeding
/// the next. The result has 5 bits: the last carry is bit 4.
fn add4(a: u4, b: u4) u5 {
    var out: u5 = 0;
    var carry = false;
    for (0..4) |i| {
        const bit: u2 = @intCast(i);
        const fa = fullAdder((a >> bit) & 1 == 1, (b >> bit) & 1 == 1, carry);
        if (fa.sum) out |= @as(u5, 1) << bit;
        carry = ???;
    }
    if (carry) out |= 1 << 4;
    return out;
}

/// How many transistors `nands` NAND gates cost. Count them in the picture.
fn transistors(nands: usize) usize {
    return ???;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const bools = [_]bool{ false, true };

test "CMOS gates: one network conducts, never both, never neither" {
    try expectEqual(Wire.high, notCmos(false));
    try expectEqual(Wire.low, notCmos(true));
    for (bools) |a| for (bools) |b| {
        try expectEqual(if (a and b) Wire.low else Wire.high, nandCmos(a, b));
        try expectEqual(if (a or b) Wire.low else Wire.high, norCmos(a, b));
    };
}

test "every gate from NAND" {
    for (bools) |a| {
        try expectEqual(!a, not(a));
        for (bools) |b| {
            try expectEqual(a and b, andGate(a, b));
            try expectEqual(a or b, orGate(a, b));
            try expectEqual(a != b, xor(a, b));
        }
    }
}

test "the full adder counts ones" {
    for (bools) |a| for (bools) |b| for (bools) |c| {
        const ones = @as(u2, @intFromBool(a)) + @intFromBool(b) + @intFromBool(c);
        const fa = fullAdder(a, b, c);
        try expectEqual(ones & 1 == 1, fa.sum);
        try expectEqual(ones >= 2, fa.carry);
    };
}

test "240 transistors that can add" {
    for (0..16) |a| for (0..16) |b| {
        try expectEqual(@as(u5, @intCast(a + b)), add4(@intCast(a), @intCast(b)));
    };
    nands_used = 0;
    _ = add4(7, 9);
    // four full adders: two XORs (4 NANDs each), two ANDs (2 each) and an OR (3) apiece
    try expectEqual(4 * 15, nands_used);
    try expectEqual(240, transistors(nands_used));
    // A real cell library does better, with a full adder designed as ONE
    // CMOS gate pair of 28 transistors instead of 15 NANDs.
}
