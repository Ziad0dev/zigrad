//
// ─── Exercise 236: processes, and taking turns ────────────────────────
//
// One processor, several programs, each of which believes it has the
// machine to itself. 235 already holds the whole trick: while the kernel
// runs, a program is nothing but 17 words in a trap frame, and `resume`
// turns a frame back into a running program. So:
//
//     to switch programs, resume a DIFFERENT frame than the one you saved.
//
// That's a *context switch*. The rest is bookkeeping. A *process* is a
// program in the middle of running: here, a frame, a stack of its own,
// and a flag that says it is alive. The kernel keeps a table of them.
// The *scheduler* is the function that picks which one runs next, and
// the simplest fair one is *round robin*: the next live process after
// the current one, wrapping around.
//
// When does the kernel get to choose? Whenever it runs, and there are
// two ways it comes to run:
//
//   the process asks     yield(), "I have nothing to do right now", or
//                        exit(). Switching only then is *cooperative*
//                        multitasking, and one program that never asks
//                        (`while (1);`) freezes the machine. That was
//                        the Macintosh until 2001.
//   the timer says so    233's timer traps after a set number of user
//                        instructions, the *time slice*, whatever the
//                        program is doing: *preemptive* multitasking.
//                        The program can't tell. Its registers come back
//                        exactly as they were, a moment later.
//
// The system calls, on top of 235's putc (1):
//
//     2  exit()          this process is done. When the last one exits,
//                        the machine stops.
//     4  yield()         let the others run
//     5  getpid()        which process am I: 0 to 3
//     6  spawn(entry)    start a new process at the function `entry`.
//                        Returns its number, or -1 if the table is full.
//
// A process that faults is killed, and now that means what it should:
// the others carry on.
//
// YOUR TASK: the new frame in spawn(), the scheduler's choice, and
// what the timer and exit() do.
//
const std = @import("std");

/// In spawn(), for the free slot `p`, whose frame (17 words, already
/// zeroed) is `frame`: the process starts at `entry`, returns into
/// user_done, and gets its own stack. Process 0's stack starts at
/// 0x1c000, and each next one 0x1000 lower. (Slot 13 is sp, 14 lr, 15 pc.)
//⟪
const procs_new_frame =
    \\        frame[13] = 0x1c000 - p * 0x1000;
    \\        frame[14] = (int)&user_done;
    \\        frame[15] = entry;
    \\
;
//|||
const procs_new_frame = ???;
//⟫

/// In schedule(): round robin. Try the four table slots in order,
/// starting with the one AFTER `running` and ending with `running`
/// itself (so a lone process keeps running). For the first one that is
/// alive: make it `running`, point `current` at its frame, wind the
/// timer (sys[7]) up to `slice`, and return. `%` is there for the
/// wrapping around.
//⟪
const procs_choose =
    \\    for (int step = 1; step <= 4; step++) {
    \\        int p = (running + step) % 4;
    \\        if (alive[p]) {
    \\            running = p;
    \\            current = frames + p * 17;
    \\            sys[7] = slice;
    \\            return p;
    \\        }
    \\    }
    \\
;
//|||
const procs_choose = ???;
//⟫

/// In trap(): what a timer trap (cause 2) does, and then, among the
/// system calls, what exit (number 2) does. Each is one or two
/// statements. This process's flag is alive[running].
//⟪
const procs_timer_and_exit =
    \\    if (cause == 2) {
    \\        schedule();
    \\        return 0;
    \\    }
    \\    if (cause == 1 && current[0] == 2) {
    \\        alive[running] = 0;
    \\        schedule();
    \\        return 0;
    \\    }
    \\
;
//|||
const procs_timer_and_exit = ???;
//⟫

const procs_c =
    \\int *sys = (int *)0x20000000;
    \\int frames[68];         /* four processes, 17 words each */
    \\int alive[4];
    \\int *current;           /* the frame trap_entry saves into and resume loads */
    \\int running;            /* whose frame that is */
    \\int slice = 2000;       /* user instructions per turn */
    \\
    \\int spawn(int entry) {
    \\    for (int p = 0; p < 4; p++) {
    \\        if (alive[p]) continue;
    \\        int *frame = frames + p * 17;
    \\        for (int i = 0; i < 17; i++) frame[i] = 0;
    \\
++ procs_new_frame ++
    \\        alive[p] = 1;
    \\        return p;
    \\    }
    \\    return -1;
    \\}
    \\
    \\/* Picks who runs next. If nobody is left, the machine stops. */
    \\int schedule() {
    \\
++ procs_choose ++
    \\    halt(0);
    \\    return -1;
    \\}
    \\
    \\int trap() {
    \\    int cause = sys[1];
    \\
++ procs_timer_and_exit ++
    \\    if (cause != 1) {
    \\        puts("[killed ");
    \\        putchar('0' + running);
    \\        puts("]");
    \\        alive[running] = 0;
    \\        schedule();
    \\        return 0;
    \\    }
    \\    int number = current[0];
    \\    if (number == 1) current[0] = putchar(current[1]);
    \\    else if (number == 4) { current[0] = 0; schedule(); }
    \\    else if (number == 5) current[0] = running;
    \\    else if (number == 6) current[0] = spawn(current[1]);
    \\    else current[0] = -1;
    \\    return 0;
    \\}
    \\
    \\int main() {
    \\    sys[0] = (int)&trap_entry;
    \\    spawn((int)&user_main);
    \\    running = 3;            /* so that the first choice is process 0 */
    \\    schedule();
    \\    resume();
    \\    return 0;
    \\}
    \\
;

const ta = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Functions every test program gets.
const user_lib_c =
    \\int print(char *s) { while (*s) syscall(1, *s++); return 0; }
    \\
;

fn outputOf(comptime user_c: []const u8) ![]u8 {
    const out = try runKernel(ta, GuardOnly, &.{ procs_c, user_lib_c ++ user_c }, &.{kernel_s});
    try expectEqual(@as(u32, 0), out.result);
    return out.output;
}

fn expectOutput(want: []const u8, comptime user_c: []const u8) !void {
    const got = try outputOf(user_c);
    defer ta.free(got);
    try expectEqualStrings(want, got);
}

test "one process" {
    try expectOutput("alone 0\n",
        \\int user_main() { print("alone "); syscall(1, '0' + syscall(5)); print("\n"); return 0; }
    );
}

test "taking turns by asking: yield" {
    try expectOutput("a1 b1 c1 a2 b2 c2 a3 b3 c3 ",
        \\int turns(char *name) {
        \\    for (int i = 1; i <= 3; i++) { print(name); syscall(1, '0' + i); syscall(1, ' '); syscall(4); }
        \\    return 0;
        \\}
        \\int b_main() { return turns("b"); }
        \\int c_main() { return turns("c"); }
        \\int user_main() {
        \\    syscall(6, (int)&b_main);
        \\    syscall(6, (int)&c_main);
        \\    return turns("a");
        \\}
    );
}

test "exit, a full table, and slots that are used again" {
    try expectOutput("123-0 1 2 3 . 1 [killed 1]2 3 done",
        \\int quick() { syscall(1, '0' + syscall(5)); syscall(1, ' '); return 0; }
        \\int slow() { quick(); syscall(4); quick(); return 0; }
        \\int wild() { quick(); int *p = (int *)0x20000000; *p = 0; return 0; }
        \\int user_main() {
        \\    syscall(1, '0' + syscall(6, (int)&quick));
        \\    syscall(1, '0' + syscall(6, (int)&slow));
        \\    syscall(1, '0' + syscall(6, (int)&slow));
        \\    if (syscall(6, (int)&quick) == -1) syscall(1, '-');   /* the table is full */
        \\    quick();
        \\    syscall(4);             /* 1 runs and exits; 2 and 3 say their first line */
        \\    print(". ");
        \\    syscall(6, (int)&wild); /* gets slot 1, which is free again */
        \\    syscall(4);             /* wild; then 2 and 3 finish */
        \\    print("done");
        \\    return 0;
        \\}
    );
}

test "exit means now, and every process has a stack of its own" {
    try expectOutput("yy.",
        \\int where() { int local; return (int)&local; }
        \\int child() {
        \\    int sp = where();
        \\    syscall(1, 'x' + (sp < 0x1b000 && sp > 0x1a000));    /* process 1: the second stack */
        \\    syscall(2);
        \\    print("still here?");                                /* not after exit */
        \\    return 0;
        \\}
        \\int user_main() {
        \\    int sp = where();
        \\    syscall(1, 'x' + (sp < 0x1c000 && sp > 0x1b000));
        \\    syscall(6, (int)&child);
        \\    syscall(4);
        \\    syscall(4);
        \\    print(".");
        \\    return 0;
        \\}
    );
}

test "taking turns without asking: the timer" {
    // Three processes that never yield. Each prints its letter 20 times,
    // with a long loop in between.
    const got = try outputOf(
        \\int spin(int c) {
        \\    for (int i = 0; i < 20; i++) {
        \\        for (int j = 0; j < 300; j++) ;
        \\        syscall(1, c);
        \\    }
        \\    return 0;
        \\}
        \\int a_main() { return spin('a'); }
        \\int b_main() { return spin('b'); }
        \\int user_main() {
        \\    syscall(6, (int)&a_main);
        \\    syscall(6, (int)&b_main);
        \\    return spin('c');
        \\}
    );
    defer ta.free(got);
    try expectEqual(@as(usize, 60), got.len);
    // all three were running at the same time: the letters come mixed.
    // In any 6 letters in a row there are at least one of each.
    var at: usize = 0;
    while (at + 6 <= got.len) : (at += 1) {
        for ("abc") |letter| {
            if (std.mem.indexOfScalar(u8, got[at..][0..6], letter) == null) {
                std.debug.print("no '{c}' in \"{s}\", at {d} of \"{s}\"\n", .{ letter, got[at..][0..6], at, got });
                return error.NotInterleaved;
            }
        }
    }
}

test "preempted in the middle of arithmetic, and none the wiser" {
    // Two processes add up numbers, slowly, in locals and registers that
    // the other one is using too. Each must get its own right answer.
    try expectOutput("5050 500500 ",
        \\int show(int n) { if (n >= 10) show(n / 10); syscall(1, '0' + n % 10); return 0; }
        \\int sum_to(int n) { int s = 0; for (int i = 1; i <= n; i++) s += i; return s; }
        \\int small() { show(sum_to(100)); syscall(1, ' '); return 0; }
        \\int user_main() {
        \\    syscall(6, (int)&small);
        \\    show(sum_to(1000));
        \\    syscall(1, ' ');
        \\    return 0;
        \\}
    );
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include machine
//@include kernel_asm
//@include kernel_run
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
