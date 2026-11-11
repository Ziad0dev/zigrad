//
// ─── Exercise 235: a kernel, and its first system calls ───────────────
//
// 233 built the door between user and kernel mode. This exercise puts a
// kernel behind it: a small one, in C, compiled by your compiler, that
// runs one program in user mode and serves its requests.
//
// From the program's side a system call looks like a function:
//
//     syscall(1, 'x');        write a character
//
// and `syscall` is two instructions: `swi 0`, then return. By the ARM
// convention (227) its arguments are already in r0, r1, r2, r3, so the
// number of the call is in r0 and its first argument in r1, and its
// result will be whatever is in r0 when the program continues.
//
// From the kernel's side, a trap arrives with the processor in an
// awkward state: every register still holds the PROGRAM's values, and
// the kernel may not lose one of them, since the program doesn't know it
// was interrupted. So the first thing any kernel does on any trap is
// the same dull, careful thing, in assembly because C can't name
// registers:
//
//     trap_entry:   store r0 to r12, the user's sp and lr, the saved pc
//                   and the saved flags into a 17-word array, the
//                   *trap frame* of the current process
//                   call the C function trap()
//     resume:       hand the frame back to the processor (233's `resume`
//                   register), which reloads everything and continues
//                   the program
//
// In between, the program's registers are just an array in memory, and
// C can read and write them: `current[0]` is its r0. That is how a
// system call gets its arguments, and how it returns a value: the kernel
// writes the result into the frame's r0, and the program finds it there
// when it wakes.
//
// It is also how a program is started. There was no program to save,
// so the kernel makes up a frame by hand, "a program that is about to
// run its first instruction, with an empty stack", and resumes it.
//
// The system calls of this kernel:
//
//     1  putc(c)       print a character; returns it
//     2  exit(code)    the program is done: here, that stops the machine
//     3  calls()       how many system calls have been made
//     others           return -1
//
// And a program that faults is killed, with a message.
//
// This kernel and its one program are still linked into one image and
// share one address space. A hostile program could find the UART
// itself. 237 closes that with 234's page mapping.
//
// YOUR TASK: the three special saves in trap_entry, the first frame,
// and the system call table.
//
const std = @import("std");

//@export kernel_asm
/// In trap_entry. r0 points at the frame, r12 at the system registers
/// (0x20000000), and r1 is free to use (the user's r1 is already saved).
/// Three slots of the frame are still missing:
///   slot 13 (offset 52): the user's sp, which is in other_sp (+0x10)
///   slot 14 (offset 56): the user's lr, still in lr itself
///   slot 15 (offset 60): where the program continues: saved_pc (+0x08)
/// Five instructions.
//⟪
const kernel_save_special =
    \\        ldr   r1, [r12, #0x10]
    \\        str   r1, [r0, #52]
    \\        str   lr, [r0, #56]
    \\        ldr   r1, [r12, #0x08]
    \\        str   r1, [r0, #60]
    \\
;
//|||
const kernel_save_special = ???;
//⟫

const kernel_s =
    \\@ Every trap comes here, with the kernel's sp in sp and the user's
    \\@ values everywhere else.
    \\trap_entry:
    \\        str   r0, [sp, #-4]!          @ borrow r0: push the user's
    \\        ldr   r0, =current
    \\        ldr   r0, [r0]                @ r0 = the current frame
    \\        str   r1, [r0, #4]
    \\        str   r2, [r0, #8]
    \\        str   r3, [r0, #12]
    \\        str   r4, [r0, #16]
    \\        str   r5, [r0, #20]
    \\        str   r6, [r0, #24]
    \\        str   r7, [r0, #28]
    \\        str   r8, [r0, #32]
    \\        str   r9, [r0, #36]
    \\        str   r10, [r0, #40]
    \\        str   r11, [r0, #44]
    \\        str   r12, [r0, #48]
    \\        ldr   r1, [sp], #4            @ the user's r0, back off the stack
    \\        str   r1, [r0]
    \\        mov   r12, #0x20000000
    \\
++ kernel_save_special ++
    \\        ldr   r1, [r12, #0x20]        @ saved_flags
    \\        str   r1, [r0, #64]
    \\        bl    trap                    @ the kernel proper, in C
    \\@ Continue the current process. Also called from C; never returns.
    \\resume: ldr   r0, =current
    \\        ldr   r0, [r0]
    \\        mov   r12, #0x20000000
    \\        str   r0, [r12, #0x24]
    \\@ halt(code): stop the machine. (A swi in kernel mode does that.)
    \\halt:   swi   0
    \\@ What user code calls: syscall(number, a, b, c).
    \\syscall:
    \\        swi   0
    \\        mov   pc, lr
    \\@ A program whose main function returns lands here: exit(what it returned).
    \\user_done:
    \\        mov   r1, r0
    \\        mov   r0, #2
    \\        swi   0
    \\
;
//@end

/// In main(): make the first frame, in `regs`. The program starts at
/// the function user_main (its address is `(int)&user_main`), with its
/// stack pointer at 0x1c000, and when user_main returns it should land
/// in user_done. Slots as above: 13 is sp, 14 is lr, 15 is pc.
//⟪
const kernel_first_frame =
    \\    regs[13] = 0x1c000;
    \\    regs[14] = (int)&user_done;
    \\    regs[15] = (int)&user_main;
    \\
;
//|||
const kernel_first_frame = ???;
//⟫

/// In trap(), for a system call. Its number is the program's r0, its
/// argument the program's r1, and its result goes into the program's
/// r0. The calls are listed above; putchar(c) prints and returns c,
/// halt(code) stops the machine, and `calls` has already been counted.
//⟪
const kernel_dispatch =
    \\    int number = current[0];
    \\    if (number == 1) current[0] = putchar(current[1]);
    \\    else if (number == 2) halt(current[1]);
    \\    else if (number == 3) current[0] = calls;
    \\    else current[0] = -1;
    \\
;
//|||
const kernel_dispatch = ???;
//⟫

const kernel_c =
    \\int *sys = (int *)0x20000000;   /* the system registers (233) */
    \\int regs[17];                   /* the program's trap frame */
    \\int *current;                   /* the frame of whoever is running */
    \\int calls;
    \\
    \\int trap() {
    \\    int cause = sys[1];
    \\    if (cause != 1) {
    \\        puts("killed: cause ");
    \\        putchar('0' + cause);
    \\        putchar('\n');
    \\        halt(100 + cause);
    \\    }
    \\    calls++;
    \\
++ kernel_dispatch ++
    \\    return 0;
    \\}
    \\
    \\int main() {
    \\    sys[0] = (int)&trap_entry;  /* the vector */
    \\    current = regs;
    \\
++ kernel_first_frame ++
    \\    resume();
    \\    return 0;
    \\}
    \\
;

//@export kernel_run
const Outcome = struct { result: u32, output: []u8 };

/// Builds a kernel from C and assembly files (plus libc), and boots it.
fn runKernel(gpa: std.mem.Allocator, comptime Mmu: type, c_files: []const []const u8, asm_files: []const []const u8) !Outcome {
    var all_c: std.ArrayList([]const u8) = .empty;
    defer all_c.deinit(gpa);
    try all_c.appendSlice(gpa, c_files);
    try all_c.append(gpa, libc_c);
    const image = try buildProgram(gpa, all_c.items, asm_files, 0);
    defer gpa.free(image);
    var board = try Board.init(gpa, 0x20000);
    defer board.deinit();
    board.load(0, image);
    var m: Machine(Mmu) = .{ .board = &board };
    const result = try m.run(20_000_000);
    return .{ .result = result, .output = try gpa.dupe(u8, board.uart_out.items) };
}
//@end

const ta = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn expectKernel(want_output: []const u8, want_result: i32, user_c: []const u8, user_s: []const u8) !void {
    const out = try runKernel(ta, GuardOnly, &.{ kernel_c, user_c }, &.{ kernel_s, user_s });
    defer ta.free(out.output);
    try expectEqualStrings(want_output, out.output);
    try expectEqual(@as(u32, @bitCast(want_result)), out.result);
}

test "hello from user mode" {
    try expectKernel("hello from user mode\n", 7,
        \\int write(char *s) { while (*s) syscall(1, *s++); return 0; }
        \\int user_main() {
        \\    write("hello from user mode\n");
        \\    return 7;       /* through user_done: exit(7) */
        \\}
    , "");
}

test "system calls return values" {
    try expectKernel("ab", 1 * 1000 + 98 * 10 + 4,
        \\int user_main() {
        \\    int a = syscall(1, 'a');
        \\    int b = syscall(1, 'b');
        \\    int nothing = syscall(99, 5);
        \\    int count = syscall(3);
        \\    if (a != 'a') return 0;
        \\    syscall(2, -nothing * 1000 + b * 10 + count);
        \\    return 0;       /* never reached */
        \\}
    , "");
}

test "a system call changes nothing but r0" {
    // A program in assembly, with something in every register, and flags
    // that a branch after the call depends on.
    try expectKernel("", 3 + (1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10 + 11 + 12) * 16 + 0x1b000 + 5000, "",
        \\user_main:
        \\        mov   r1, #16
        \\        mov   r2, #32
        \\        mov   r3, #48
        \\        mov   r4, #64
        \\        mov   r5, #80
        \\        mov   r6, #96
        \\        mov   r7, #112
        \\        mov   r8, #128
        \\        mov   r9, #144
        \\        mov   r10, #160
        \\        mov   r11, #176
        \\        mov   r12, #192
        \\        sub   sp, sp, #0x1000
        \\        ldr   lr, =5000
        \\        mov   r0, #3
        \\        swi   0                   @ calls(): the first two calls are these...
        \\        mov   r0, #3
        \\        swi   0
        \\        mov   r0, #3
        \\        cmp   r1, #16             @ sets Z...
        \\        swi   0                   @ ...across a trap...
        \\        addne r0, r0, #1000       @ ...and it is still set
        \\        add   r0, r0, r1
        \\        add   r0, r0, r2
        \\        add   r0, r0, r3
        \\        add   r0, r0, r4
        \\        add   r0, r0, r5
        \\        add   r0, r0, r6
        \\        add   r0, r0, r7
        \\        add   r0, r0, r8
        \\        add   r0, r0, r9
        \\        add   r0, r0, r10
        \\        add   r0, r0, r11
        \\        add   r0, r0, r12
        \\        add   r0, r0, sp
        \\        add   r0, r0, lr
        \\        mov   r1, r0
        \\        mov   r0, #2
        \\        swi   0
    );
}

test "a program that misbehaves is killed" {
    try expectKernel("so far so good\nkilled: cause 4\n", 104,
        \\int user_main() {
        \\    for (char *s = "so far so good\n"; *s; s++) syscall(1, *s);
        \\    int *sys = (int *)0x20000000;
        \\    sys[0] = 0;         /* "from now on, traps go to address 0" */
        \\    return 1;
        \\}
    , "");
    try expectKernel("killed: cause 3\n", 103, "",
        \\user_main:
        \\        .word 0xe7f000f0
    );
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include machine
//@include c_lex
//@include c_expr
//@include c_parse
//@include c_gen
//@include c_lower
//@include linker
//@include libc
//@include arm_enc
//@include arm_alu
//@include arm_asm_line
//@include arm_asm
//@include arm_emu
