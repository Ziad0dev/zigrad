//
// ─── Exercise 232: a bootloader, in C ─────────────────────────────────
//
// The boot ROM (223) is 28 instructions that trust the cable completely.
// That was the right size for something that can never be changed. But
// it means that one flipped bit on the wire gives a program that crashes
// somewhere, sometime, and nobody knows why.
//
// The cure is the standard one: keep the unchangeable part tiny, and
// have it load a *second stage* that is ordinary software and can be as
// careful as it likes. This exercise is that second stage, a bootloader.
// It is the first real program for your computer that isn't assembly.
//
//     power on -> boot ROM -> (cable) -> bootloader -> (cable) -> program
//                 at 0                   at 0x8000               at 0x4000
//
// The bootloader's protocol adds what the ROM's lacked, a check, and a
// way to say that it failed:
//
//     the sender:   4 bytes   n, low byte first
//                   n bytes   the program
//                   4 bytes   the CRC-32 of those n bytes (231)
//     the answer:   "K"       it arrived whole; the program is running
//                   "N"       it did not: send it again
//
// (The outline loads the kernel over Ethernet at this point. Ours keeps
// the serial cable and borrows Ethernet's checksum, which is the part
// with an idea in it.)
//
// Writing 231's CRC again in C teaches one thing about the language you
// built: your `int` is signed, so `>>` copies the sign bit in from the
// left (227 compiles it to `asr`). The CRC wants zeros to come in. C
// programmers write `unsigned` for that; this compiler has no such
// type, so the bit is cleared by hand: (crc >> 1) & 0x7fffffff.
//
// And one thing about C itself: it can't jump to an address. The last
// step, "run what I just loaded", is three words of assembly, linked in.
//
// The tests run the whole chain on the emulator, and once on the Verilog
// computer: the ROM receives the bootloader, the bootloader receives a
// damaged program and refuses it, receives it again, and runs it.
//
// YOUR TASK: three pieces of the bootloader, in C.
//
const std = @import("std");

//@export bootloader
/// get_word(): the next four bytes from the cable (getchar() gives one),
/// as one number, low byte first.
//⟪
const boot_get_word =
    \\int get_word() {
    \\    int w = 0;
    \\    for (int shift = 0; shift < 32; shift += 8) w = w | (getchar() << shift);
    \\    return w;
    \\}
    \\
;
//|||
const boot_get_word = ???;
//⟫

/// Inside crc32(), for each byte, after the byte has been XORed into
/// `crc`: eight times, note the low bit, shift right by one WITH A ZERO
/// COMING IN, and if the noted bit was 1, XOR in 0xedb88320.
//⟪
const boot_crc_bits =
    \\        for (int k = 0; k < 8; k++) {
    \\            int low = crc & 1;
    \\            crc = (crc >> 1) & 0x7fffffff;
    \\            if (low) crc = crc ^ 0xedb88320;
    \\        }
    \\
;
//|||
const boot_crc_bits = ???;
//⟫

/// The body of main's loop: read the length; read that many bytes to
/// `load`; read the check. If crc32(load, n) equals it, leave the loop
/// (break). Otherwise answer 'N' and go round again.
//⟪
const boot_receive =
    \\        int n = get_word();
    \\        for (int i = 0; i < n; i++) load[i] = getchar();
    \\        int check = get_word();
    \\        if (crc32(load, n) == check) break;
    \\        putchar('N');
    \\
;
//|||
const boot_receive = ???;
//⟫

/// The bootloader's functions.
const boot_lib_c =
    \\int *uart = (int *)0x10000000;
    \\int putchar(int c) {
    \\    while ((uart[1] & 1) == 0) ;
    \\    uart[0] = c;
    \\    return c;
    \\}
    \\int getchar() {
    \\    while ((uart[1] & 2) == 0) ;
    \\    return uart[2];
    \\}
    \\
++ boot_get_word ++
    \\int crc32(char *p, int n) {
    \\    int crc = -1;                     /* all ones */
    \\    for (int i = 0; i < n; i++) {
    \\        crc = crc ^ p[i];             /* the whole byte at once: its bits meet the low 8 in turn */
    \\
++ boot_crc_bits ++
    \\    }
    \\    return ~crc;
    \\}
    \\
;

const boot_main_c =
    \\int main() {
    \\    char *load = (char *)0x4000;
    \\    while (1) {
    \\
++ boot_receive ++
    \\    }
    \\    putchar('K');
    \\    jump(load);
    \\    return 0;
    \\}
    \\
;

/// What C can't say.
const boot_jump_s =
    \\jump:   mov   pc, r0
    \\
;

const program_address: u32 = 0x4000;

/// The bootloader, linked to run where the boot ROM puts it. The caller
/// frees it.
fn buildBootloader(gpa: std.mem.Allocator) ![]u8 {
    return buildProgram(gpa, &.{ boot_lib_c, boot_main_c }, &.{boot_jump_s}, load_address);
}

/// What the sender sends to make the bootloader run `code`: the length,
/// the bytes, the check. The caller frees it.
fn checkedPacket(alloc: std.mem.Allocator, code: []const u8) ![]u8 {
    const packet = try alloc.alloc(u8, code.len + 8);
    std.mem.writeInt(u32, packet[0..4], @intCast(code.len), .little);
    @memcpy(packet[4..][0..code.len], code);
    std.mem.writeInt(u32, packet[4 + code.len ..][0..4], crc32(code), .little);
    return packet;
}
//@end

const ta = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "the CRC in C agrees with the CRC in Zig" {
    const image = try buildProgram(ta, &.{
        boot_lib_c,
        \\int main() {
        \\    if (crc32("", 0) != 0) return 1;
        \\    if (crc32("a", 1) != 0xe8b7be43) return 2;
        \\    return crc32("123456789", 9);
        \\}
    }, &.{}, 0);
    defer ta.free(image);
    const ran = try runImage(ta, image, "");
    defer ta.free(ran.output);
    try expectEqual(@as(u32, 0xcbf43926), ran.result);
}

test "get_word" {
    const image = try buildProgram(ta, &.{ boot_lib_c, "int main() { return get_word() - get_word(); }" }, &.{}, 0);
    defer ta.free(image);
    const ran = try runImage(ta, image, &.{ 0x78, 0x56, 0x34, 0x92, 1, 0, 0, 0 });
    defer ta.free(ran.output);
    try expectEqual(@as(u32, 0x92345677), ran.result);
}

const payload_s =
    \\        mov   r1, #0x10000000
    \\        ldr   r4, =text
    \\next:   ldrb  r0, [r4], #1
    \\        cmp   r0, #0
    \\        swieq 0
    \\        bl    putc
    \\        b     next
    \\text:   .asciz "up\n"
    \\        .align 2
    \\
++ putc_asm;

const Chain = struct {
    rom: Program,
    /// Everything the far end sends, from power-on.
    cable: []u8,

    fn deinit(c: *Chain) void {
        c.rom.deinit(ta);
        ta.free(c.cable);
    }
};

/// The ROM, and a cable that carries: the bootloader (for the ROM), then
/// the payload `damaged_copies` times with one bit flipped, then the
/// payload whole.
fn chain(damaged_copies: usize) !Chain {
    var rom = try assemble(ta, bootrom_asm, 0, null);
    errdefer rom.deinit(ta);
    const bootloader = try buildBootloader(ta);
    defer ta.free(bootloader);
    var payload = try assemble(ta, payload_s, program_address, null);
    defer payload.deinit(ta);
    const first = try bootPacket(ta, bootloader);
    defer ta.free(first);
    const good = try checkedPacket(ta, payload.code);
    defer ta.free(good);
    var cable: std.ArrayList(u8) = .empty;
    errdefer cable.deinit(ta);
    try cable.appendSlice(ta, first);
    for (0..damaged_copies) |n| {
        try cable.appendSlice(ta, good);
        // somewhere in the program's bytes, a different place each time
        cable.items[cable.items.len - good.len + 4 + 7 * (n + 1)] ^= 0x04;
    }
    try cable.appendSlice(ta, good);
    return .{ .rom = rom, .cable = try cable.toOwnedSlice(ta) };
}

test "the chain, on the emulator" {
    var clean = try chain(0);
    defer clean.deinit();
    const out = try runOnEmulator(ta, clean.rom.code, clean.cable);
    defer ta.free(out);
    try expectEqualStrings("!Kup\n", out); // the ROM's "!", the bootloader's "K", the program

    var noisy = try chain(3);
    defer noisy.deinit();
    const again = try runOnEmulator(ta, noisy.rom.code, noisy.cable);
    defer ta.free(again);
    try expectEqualStrings("!NNNKup\n", again);
}

test "the chain, on the computer you built" {
    var noisy = try chain(1);
    defer noisy.deinit();
    const out = try runOnSocPaced(ta, noisy.rom.code, noisy.cable, true);
    defer ta.free(out);
    try expectEqualStrings("!NKup\n", out);
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include c_lex
//@include c_expr
//@include c_parse
//@include c_gen
//@include c_lower
//@include linker
//@include ethernet
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
//@include bootrom
