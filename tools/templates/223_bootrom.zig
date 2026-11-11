//
// ─── Exercise 223: the first program ──────────────────────────────────
//
// Every program so far got into memory by magic: the test bench wrote it
// there before the clock started. A real board has no bench. When power
// arrives, its RAM holds nothing, and the processor starts fetching at
// address 0 anyway. Something has to be there already.
//
// That something is the *boot ROM*: a small program that is part of the
// hardware. On an FPGA, the starting contents of a block RAM are baked
// into the same image that configures the gates, so "the first 40 words
// of memory hold the boot ROM" is as much a part of the design as the
// adder is.
//
// And a boot ROM has one job: get a bigger program from somewhere, and
// run it. Ours gets it from the serial port, the only door this computer
// has. The far end of the cable sends
//
//     4 bytes    how long the program is, low byte first
//     n bytes    the program
//
// and the ROM puts those bytes into RAM from address 0x8000 upward,
// answers "!" so the sender knows it all arrived, and jumps to 0x8000.
// From then on, trying a new program means sending it down the cable:
// no rebuilding the hardware. (Your PC does the same dance with more
// steps: the ROM on the motherboard loads a bootloader from the disk,
// which loads the operating system. Chapter 45 adds our second step.)
//
// "Low byte first": a 32-bit number goes down a byte-wide wire as four
// bytes, and both ends must agree on the order. ARM and x86 keep numbers
// in memory low byte first too, *little-endian*, which is why `.word`
// and the length here look the same on the wire.
//
// The ROM is ARM assembly, and writing it is the exercise. Each piece is
// pasted between others, so end each with a newline (a last `\\` line
// with nothing on it), or its last instruction runs into the next line's
// label. (A program of length 0 isn't allowed: the copy loop runs once
// before it checks.) What you have:
//
//     bl getc              the next byte from the cable, in r0 (222)
//     bl putc              sends r0
//     orr rd, rn, rm, lsl rs    a register shifted by a REGISTER (215)
//     strb rd, [rn], #1    store a byte, then step the pointer (218)
//
// The tests run the ROM on your Verilog SoC, with the simulator's bench
// playing the far end of the cable, and on 218's emulator. The outline
// this part follows says of the boot ROM: "cross test in QEMU". This is
// that, with the emulator being our own.
//
// With this, the hardware is finished: from two kinds of transistor to a
// computer that boots. Everything from here on is software for it.
//
// YOUR TASK: the three pieces of the boot ROM.
//
const std = @import("std");

//@export bootrom
/// The byte that just arrived is in r0. Put it into the length, r4, at
/// the place r5 says: r5 is 0 for the first byte, 8 for the second, and
/// so on. Then move r5 on by a byte, and go round again (the loop's
/// label is `length`) unless r5 has reached 32. Four instructions.
//⟪
const rom_length =
    \\        orr   r4, r4, r0, lsl r5
    \\        add   r5, r5, #8
    \\        cmp   r5, #32
    \\        bne   length
    \\
;
//|||
const rom_length = ???;
//⟫

/// The byte that just arrived is in r0. Store it where r7 points, and
/// step r7 to the next byte. One fewer byte is still to come (r4): go
/// round again (the label is `copy`) unless that was the last. Three
/// instructions.
//⟪
const rom_copy =
    \\        strb  r0, [r7], #1
    \\        subs  r4, r4, #1
    \\        bne   copy
    \\
;
//|||
const rom_copy = ???;
//⟫

/// Run the program: r6 holds its address. One instruction.
//⟪
const rom_jump =
    \\        mov   pc, r6
    \\
;
//|||
const rom_jump = ???;
//⟫

/// The boot ROM. r1: the UART. r4: the length, then the bytes still to
/// come. r6: where the program starts. r7: where the next byte goes.
const bootrom_asm =
    \\boot:   mov   r1, #0x10000000
    \\        mov   r4, #0
    \\        mov   r5, #0
    \\length: bl    getc
    \\
++ rom_length ++
    \\        mov   r6, #0x8000
    \\        mov   r7, r6
    \\copy:   bl    getc
    \\
++ rom_copy ++
    \\        mov   r0, #33             @ "!"
    \\        bl    putc
    \\
++ rom_jump ++ putc_asm ++ getc_asm;

const load_address: u32 = 0x8000;

/// What the far end of the cable sends to make the ROM run `code`: the
/// length, then the bytes. The caller frees it.
fn bootPacket(alloc: std.mem.Allocator, code: []const u8) ![]u8 {
    const packet = try alloc.alloc(u8, 4 + code.len);
    std.mem.writeInt(u32, packet[0..4], @intCast(code.len), .little);
    @memcpy(packet[4..], code);
    return packet;
}
//@end

const ta = std.testing.allocator;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

fn assembleOrSay(source: []const u8, base: u32) !Program {
    var line_no: usize = 0;
    return assemble(ta, source, base, &line_no) catch |err| {
        std.debug.print("assembling failed on line {d}: {s}\n", .{ line_no, @errorName(err) });
        return err;
    };
}

/// Boots the ROM, sends it `source` (assembled to run at 0x8000) and
/// then `input`, on the emulator and on the SoC, and wants `output` from
/// both.
fn expectBoots(comptime source: []const u8, input: []const u8, output: []const u8) !void {
    var rom = try assembleOrSay(bootrom_asm, 0);
    defer rom.deinit(ta);
    var prog = try assembleOrSay(source, load_address);
    defer prog.deinit(ta);
    const packet = try bootPacket(ta, prog.code);
    defer ta.free(packet);
    const cable = try std.mem.concat(ta, u8, &.{ packet, input });
    defer ta.free(cable);

    const emulated = try runOnEmulator(ta, rom.code, cable);
    defer ta.free(emulated);
    try expectEqualStrings(output, emulated);
    const real = try runOnSoc(ta, rom.code, cable);
    defer ta.free(real);
    try expectEqualStrings(output, real);
}

test "the ROM fits in 40 instructions" {
    var rom = try assembleOrSay(bootrom_asm, 0);
    defer rom.deinit(ta);
    try expect(rom.code.len <= 40 * 4);
}

test "hello, world, sent down the cable" {
    try expectBoots(
        \\        mov   r1, #0x10000000
        \\        ldr   r4, =text
        \\next:   ldrb  r0, [r4], #1
        \\        cmp   r0, #0
        \\        swieq 0
        \\        bl    putc
        \\        b     next
        \\text:   .asciz "Hello, world!\n"
        \\        .align 2
        \\
    ++ putc_asm, "", "!Hello, world!\n");
}

test "a program longer than 255 bytes, which then reads the cable itself" {
    // The table makes the program over 400 bytes long, so the length's
    // second byte matters. What follows the program on the cable is its input.
    try expectBoots(
        \\        mov   r1, #0x10000000
        \\        ldr   r4, =table
        \\read:   bl    getc
        \\        cmp   r0, #10             @ a newline: done
        \\        swieq 0
        \\        sub   r0, r0, #97         @ "a" is 0
        \\        ldrb  r0, [r4, r0]
        \\        bl    putc
        \\        b     read
        \\
    ++ putc_asm ++ getc_asm ++
        \\table:  .ascii "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        \\        .space 350
    , "shout\n", "!SHOUT");
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
//@include soc
//@include getc_asm
