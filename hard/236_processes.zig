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
const procs_new_frame = ???;

/// In schedule(): round robin. Try the four table slots in order,
/// starting with the one AFTER `running` and ending with `running`
/// itself (so a lone process keeps running). For the first one that is
/// alive: make it `running`, point `current` at its frame, wind the
/// timer (sys[7]) up to `slice`, and return. `%` is there for the
/// wrapping around.
const procs_choose = ???;

/// In trap(): what a timer trap (cause 2) does, and then, among the
/// system calls, what exit (number 2) does. Each is one or two
/// statements. This process's flag is alive[running].
const procs_timer_and_exit = ???;

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

const sys_base: u32 = 0x20000000;

const Cause = enum(u32) { none = 0, syscall = 1, timer = 2, bad_instruction = 3, fault = 4 };

/// No memory management: every address is what it says. (234 has a
/// better one.)
const NoMmu = struct {
    fn translate(_: *NoMmu, addr: u32, _: bool) !u32 {
        return addr;
    }
    fn readReg(_: *NoMmu, _: u32) !u32 {
        return error.NoDevice;
    }
    fn writeReg(_: *NoMmu, _: u32, _: u32) !void {
        return error.NoDevice;
    }
    fn switched(_: *NoMmu) void {}
};

/// A computer with a kernel mode: 218's processor and board, plus the
/// mode, the trap machinery, and an Mmu that decides which addresses
/// user code may use.
fn Machine(comptime Mmu: type) type {
    return struct {
        const M = @This();

        cpu: Cpu = .{},
        board: *Board,
        mmu: Mmu = .{},
        /// The mode. The machine starts in kernel mode.
        user: bool = false,
        vector: u32 = 0,
        cause: Cause = .none,
        saved_pc: u32 = 0,
        saved_user: bool = false,
        saved_flags: Flags = .{},
        other_sp: u32 = 0,
        fault_addr: u32 = 0,
        timer: u32 = 0,
        /// The kernel wrote to the `return` register during this step,
        /// and what it wrote.
        returning: bool = false,
        frame: u32 = 0,

        /// The bus, as the processor sees it. This is what Cpu.step()
        /// reads and writes through.
        fn read(m: *M, addr: u32, size: u3) !u32 {
            if (m.user) return m.board.read(try m.mmu.translate(addr, false), size);
            if (addr < sys_base or addr >= sys_base + 0x1000) return m.board.read(addr, size);
            return switch (addr - sys_base) {
                0x00 => m.vector,
                0x04 => @intFromEnum(m.cause),
                0x08 => m.saved_pc,
                0x0c => @intFromBool(m.saved_user),
                0x10 => m.other_sp,
                0x14 => m.fault_addr,
                0x1c => m.timer,
                0x20 => @as(u32, @intFromBool(m.saved_flags.n)) << 3 | @as(u32, @intFromBool(m.saved_flags.z)) << 2 |
                    @as(u32, @intFromBool(m.saved_flags.c)) << 1 | @intFromBool(m.saved_flags.v),
                else => |reg| m.mmu.readReg(reg),
            };
        }

        fn write(m: *M, addr: u32, size: u3, value: u32) !void {
            if (m.user) return m.board.write(try m.mmu.translate(addr, true), size, value);
            if (addr < sys_base or addr >= sys_base + 0x1000) return m.board.write(addr, size, value);
            switch (addr - sys_base) {
                0x00 => m.vector = value,
                0x08 => m.saved_pc = value,
                0x0c => m.saved_user = value & 1 != 0,
                0x10 => m.other_sp = value,
                0x18 => {
                    m.returning = true;
                    m.frame = 0;
                },
                0x24 => {
                    m.returning = true;
                    m.frame = value;
                },
                0x1c => m.timer = value,
                0x20 => m.saved_flags = .{ .n = value & 8 != 0, .z = value & 4 != 0, .c = value & 2 != 0, .v = value & 1 != 0 },
                else => |reg| try m.mmu.writeReg(reg, value),
            }
        }

        /// Into the kernel. cpu.r[PC] already says where the trapped
        /// code should continue.
        fn trap(m: *M, cause: Cause) void {
            m.cause = cause;
            m.saved_pc = m.cpu.r[PC];
            m.saved_user = m.user;
            m.saved_flags = m.cpu.flags;
            m.user = false;
            std.mem.swap(u32, &m.cpu.r[SP], &m.other_sp);
            m.cpu.r[PC] = m.vector;
        }

        /// And back out.
        fn trapReturn(m: *M) !void {
            if (m.frame != 0) {
                // a whole set of user registers, from the kernel's memory
                var words: [17]u32 = undefined;
                for (&words, 0..) |*w, n| w.* = try m.board.read(m.frame + 4 * @as(u32, @intCast(n)), 4);
                @memcpy(m.cpu.r[0..13], words[0..13]);
                m.other_sp = words[13];
                m.cpu.r[LR] = words[14];
                m.saved_pc = words[15];
                m.saved_flags = .{ .n = words[16] & 8 != 0, .z = words[16] & 4 != 0, .c = words[16] & 2 != 0, .v = words[16] & 1 != 0 };
                m.saved_user = true;
            }
            m.user = m.saved_user;
            m.cpu.flags = m.saved_flags;
            // the stacks swap back only if we really change mode
            if (m.user) std.mem.swap(u32, &m.cpu.r[SP], &m.other_sp);
            m.cpu.r[PC] = m.saved_pc;
            m.mmu.switched();
        }

        /// One instruction, or one trap. Returns r0 when the machine
        /// stops (a swi in kernel mode), and null while it runs.
        fn step(m: *M) !?u32 {
            if (m.user and m.timer != 0) {
                m.timer -= 1;
                if (m.timer == 0) {
                    // time is up, BEFORE the instruction at pc: it runs
                    // when the program is resumed
                    m.trap(.timer);
                    return null;
                }
            }
            const event = m.cpu.step(m);
            if (event == .ok) {
                if (m.returning) {
                    m.returning = false;
                    m.trapReturn() catch return error.KernelFault;
                }
                return null;
            }
            if (!m.user) {
                // Trouble in the kernel itself: there is nobody to tell.
                return switch (event) {
                    .swi => m.cpu.r[0],
                    .fault => error.KernelFault,
                    else => error.KernelBadInstruction,
                };
            }
            switch (event) {
                .swi => m.trap(.syscall),
                .undefined => m.trap(.bad_instruction),
                .fault => |f| {
                    m.fault_addr = f.addr;
                    m.trap(.fault);
                },
                .ok => unreachable,
            }
            return null;
        }

        fn run(m: *M, limit: usize) !u32 {
            for (0..limit) |_| {
                if (try m.step()) |result| return result;
            }
            return error.RanTooLong;
        }
    };
}

/// User code may use everything except the system registers.
const GuardOnly = struct {
    fn translate(_: *GuardOnly, addr: u32, _: bool) !u32 {
        if (addr >= sys_base and addr < sys_base + 0x1000) return error.Forbidden;
        return addr;
    }
    fn readReg(_: *GuardOnly, _: u32) !u32 {
        return error.NoDevice;
    }
    fn writeReg(_: *GuardOnly, _: u32, _: u32) !void {
        return error.NoDevice;
    }
    fn switched(_: *GuardOnly) void {}
};
/// In trap_entry. r0 points at the frame, r12 at the system registers
/// (0x20000000), and r1 is free to use (the user's r1 is already saved).
/// Three slots of the frame are still missing:
///   slot 13 (offset 52): the user's sp, which is in other_sp (+0x10)
///   slot 14 (offset 56): the user's lr, still in lr itself
///   slot 15 (offset 60): where the program continues: saved_pc (+0x08)
/// Five instructions.
const kernel_save_special =
    \\        ldr   r1, [r12, #0x10]
    \\        str   r1, [r0, #52]
    \\        str   lr, [r0, #56]
    \\        ldr   r1, [r12, #0x08]
    \\        str   r1, [r0, #60]
    \\
;

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
const CTok = enum { ident, keyword, num, str, punct, eof };

const CToken = struct {
    kind: CTok,
    /// The characters of the token, a slice of the source.
    text: []const u8,
    /// For a num: its value.
    num: u32 = 0,
    /// Which line it is on, counting from 1: for error messages.
    line: u32,

    fn is(tok: CToken, kind: CTok, text: []const u8) bool {
        return tok.kind == kind and std.mem.eql(u8, tok.text, text);
    }
};

const c_keywords = [_][]const u8{ "int", "char", "void", "if", "else", "while", "for", "return", "break", "continue", "extern" };

/// Punctuation, longest first: the first one that matches is the longest
/// that does.
const c_puncts = [_][]const u8{
    "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "++", "--", "+=", "-=",
    "+",  "-",  "*",  "/",  "%",  "&",  "|",  "^",  "~",  "!",  "<",  ">",
    "=",  "(",  ")",  "{",  "}",  "[",  "]",  ";",  ",",
};

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// What the character after a backslash stands for.
fn cEscape(c: u8) !u8 {
    return switch (c) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '0' => 0,
        '\\', '\'', '"' => c,
        else => error.BadEscape,
    };
}

/// The tokens of `source`, ending with an eof token. Their text points
/// into `source`. The caller frees the slice.
fn cLex(alloc: std.mem.Allocator, source: []const u8) ![]CToken {
    var toks: std.ArrayList(CToken) = .empty;
    errdefer toks.deinit(alloc);
    var line: u32 = 1;
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        const start = i;
        if (c == '\n') {
            line += 1;
            i += 1;
        } else if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
        } else if (std.mem.startsWith(u8, source[i..], "//")) {
            // a comment to the end of the line: stop AT the newline, so
            // that the branch above still counts it
            while (i < source.len and source[i] != '\n') i += 1;
        } else if (std.mem.startsWith(u8, source[i..], "/*")) {
            // a comment to the next */, which may be lines away
            const end = std.mem.indexOfPos(u8, source, i + 2, "*/") orelse return error.UnterminatedComment;
            line += @intCast(std.mem.count(u8, source[i..end], "\n"));
            i = end + 2;
        } else if (std.ascii.isDigit(c)) {
            // A number runs on while there are name characters (so 0x1f
            // is one token, and so is the mistake 12ab). Base 0 means:
            // look at the prefix. 0x is hexadecimal.
            while (i < source.len and isNameChar(source[i])) i += 1;
            const value = std.fmt.parseInt(u32, source[start..i], 0) catch return error.BadNumber;
            try toks.append(alloc, .{ .kind = .num, .text = source[start..i], .num = value, .line = line });
        } else if (isNameChar(c)) {
            while (i < source.len and isNameChar(source[i])) i += 1;
            const text = source[start..i];
            var kind: CTok = .ident;
            for (c_keywords) |kw| {
                // the WHOLE name must be the keyword: `interest` is not `int`
                if (std.mem.eql(u8, text, kw)) kind = .keyword;
            }
            try toks.append(alloc, .{ .kind = kind, .text = text, .line = line });
        } else if (c == '\'') {
            // 'a' or '\n': a number
            if (i + 2 >= source.len) return error.BadCharacter;
            var value: u8 = source[i + 1];
            i += 2;
            if (value == '\\') {
                value = try cEscape(source[i]);
                i += 1;
            }
            if (i >= source.len or source[i] != '\'') return error.BadCharacter;
            i += 1;
            try toks.append(alloc, .{ .kind = .num, .text = source[start..i], .num = value, .line = line });
        } else if (c == '"') {
            // Up to the closing quote. A backslash protects the character
            // after it, so that \" doesn't end the string.
            i += 1;
            while (i < source.len and source[i] != '"') {
                if (source[i] == '\n') return error.UnterminatedString;
                i += if (source[i] == '\\') 2 else 1;
            }
            if (i >= source.len) return error.UnterminatedString;
            i += 1;
            try toks.append(alloc, .{ .kind = .str, .text = source[start + 1 .. i - 1], .line = line });
        } else {
            const found = for (c_puncts) |p| {
                if (std.mem.startsWith(u8, source[i..], p)) break p;
            } else return error.BadCharacter;
            i += found.len;
            try toks.append(alloc, .{ .kind = .punct, .text = source[start..i], .line = line });
        }
    }
    try toks.append(alloc, .{ .kind = .eof, .text = "", .line = line });
    return toks.toOwnedSlice(alloc);
}
const CType = union(enum) {
    int,
    char,
    void,
    ptr: *const CType,
    array: struct { elem: *const CType, len: u32 },
};

const CUnary = enum { neg, not, lnot };

const CBinary = enum { mul, div, mod, add, sub, shl, shr, lt, le, gt, ge, eq, ne, bit_and, bit_xor, bit_or, log_and, log_or };

const CExpr = union(enum) {
    num: u32,
    /// The text between the quotes, escapes and all.
    str: []const u8,
    /// A variable of the function: its number in the function's list.
    local: u32,
    /// Any other name: a global variable, or a function.
    global: []const u8,
    unary: struct { op: CUnary, arg: *CExpr },
    /// *p. `byte` is for 228: read one byte there, and not a word.
    deref: struct { arg: *CExpr, byte: bool = false },
    /// &x
    addr: *CExpr,
    binary: struct { op: CBinary, lhs: *CExpr, rhs: *CExpr },
    assign: struct { target: *CExpr, value: *CExpr },
    call: struct { name: []const u8, args: []*CExpr },
    /// a[i]
    index: struct { base: *CExpr, at: *CExpr },
    cast: struct { to: CType, arg: *CExpr },
};

const CVar = struct { name: []const u8, type: CType };

const CBinaryInfo = struct { text: []const u8, op: CBinary, strength: u8 };

/// The binary operators, weakest first. Equal strength: same line in C's
/// precedence table.
const c_binary_ops = [_]CBinaryInfo{
    .{ .text = "||", .op = .log_or, .strength = 1 },
    .{ .text = "&&", .op = .log_and, .strength = 2 },
    .{ .text = "|", .op = .bit_or, .strength = 3 },
    .{ .text = "^", .op = .bit_xor, .strength = 4 },
    .{ .text = "&", .op = .bit_and, .strength = 5 },
    .{ .text = "==", .op = .eq, .strength = 6 },
    .{ .text = "!=", .op = .ne, .strength = 6 },
    .{ .text = "<", .op = .lt, .strength = 7 },
    .{ .text = "<=", .op = .le, .strength = 7 },
    .{ .text = ">", .op = .gt, .strength = 7 },
    .{ .text = ">=", .op = .ge, .strength = 7 },
    .{ .text = "<<", .op = .shl, .strength = 8 },
    .{ .text = ">>", .op = .shr, .strength = 8 },
    .{ .text = "+", .op = .add, .strength = 9 },
    .{ .text = "-", .op = .sub, .strength = 9 },
    .{ .text = "*", .op = .mul, .strength = 10 },
    .{ .text = "/", .op = .div, .strength = 10 },
    .{ .text = "%", .op = .mod, .strength = 10 },
};

const CParser = struct {
    toks: []const CToken,
    at: usize = 0,
    /// Every node of the tree is allocated here. Use an arena, and free
    /// the whole tree at once.
    alloc: std.mem.Allocator,
    /// The variables of the function being parsed (226).
    locals: std.ArrayList(CVar) = .empty,
    /// The variables whose names can be seen right now, as numbers in
    /// `locals`. The ones declared last are at the end.
    scope: std.ArrayList(u32) = .empty,
    /// Where in `scope` the block being parsed began (226).
    block_start: usize = 0,

    fn peek(p: *const CParser) CToken {
        return p.toks[p.at];
    }

    fn next(p: *CParser) CToken {
        const tok = p.toks[p.at];
        if (tok.kind != .eof) p.at += 1;
        return tok;
    }

    /// Is the next token this punctuation or keyword?
    fn sees(p: *const CParser, text: []const u8) bool {
        const tok = p.peek();
        return (tok.kind == .punct or tok.kind == .keyword) and std.mem.eql(u8, tok.text, text);
    }

    /// Takes the next token if it is this punctuation or keyword.
    fn eat(p: *CParser, text: []const u8) bool {
        if (!p.sees(text)) return false;
        p.at += 1;
        return true;
    }

    fn expect(p: *CParser, text: []const u8) !void {
        if (!p.eat(text)) return error.SyntaxError;
    }

    /// After an error: the line of the token the parser stopped at.
    fn line(p: *const CParser) u32 {
        return p.peek().line;
    }

    fn new(p: *CParser, e: CExpr) !*CExpr {
        const node = try p.alloc.create(CExpr);
        node.* = e;
        return node;
    }

    /// A copy of a whole tree. The sugar needs it: in a = a + b the two
    /// `a`s must be two trees, because 228 will rewrite trees in place.
    fn clone(p: *CParser, e: *const CExpr) !*CExpr {
        return p.new(switch (e.*) {
            .num, .str, .local, .global => e.*,
            .unary => |u| .{ .unary = .{ .op = u.op, .arg = try p.clone(u.arg) } },
            .deref => |d| .{ .deref = .{ .arg = try p.clone(d.arg), .byte = d.byte } },
            .addr => |a| .{ .addr = try p.clone(a) },
            .binary => |b| .{ .binary = .{ .op = b.op, .lhs = try p.clone(b.lhs), .rhs = try p.clone(b.rhs) } },
            .assign => |a| .{ .assign = .{ .target = try p.clone(a.target), .value = try p.clone(a.value) } },
            .call => |c| blk: {
                const args = try p.alloc.alloc(*CExpr, c.args.len);
                for (args, c.args) |*to, from| to.* = try p.clone(from);
                break :blk .{ .call = .{ .name = c.name, .args = args } };
            },
            .index => |x| .{ .index = .{ .base = try p.clone(x.base), .at = try p.clone(x.at) } },
            .cast => |c| .{ .cast = .{ .to = c.to, .arg = try p.clone(c.arg) } },
        });
    }

    /// The local variable with this name that can be seen from here. If
    /// two can (an inner block declared the name again), the one declared
    /// LAST wins: so look from the end of `scope`.
    fn lookup(p: *const CParser, name: []const u8) ?u32 {
        var i = p.scope.items.len;
        while (i > 0) {
            i -= 1;
            const n = p.scope.items[i];
            if (std.mem.eql(u8, p.locals.items[n].name, name)) return n;
        }
        return null;
    }

    /// `int`, `char` or `void`, if one is next.
    fn parseBaseType(p: *CParser) ?CType {
        if (p.eat("int")) return .int;
        if (p.eat("char")) return .char;
        if (p.eat("void")) return .void;
        return null;
    }

    /// Any number of `*`: each makes a pointer to the type so far.
    fn parsePointers(p: *CParser, base: CType) !CType {
        var t = base;
        while (p.eat("*")) {
            const pointee = try p.alloc.create(CType);
            pointee.* = t;
            t = .{ .ptr = pointee };
        }
        return t;
    }

    fn startsType(tok: CToken) bool {
        return tok.is(.keyword, "int") or tok.is(.keyword, "char") or tok.is(.keyword, "void");
    }

    fn parsePrimary(p: *CParser) anyerror!*CExpr {
        const tok = p.next();
        switch (tok.kind) {
            .num => return p.new(.{ .num = tok.num }),
            .str => return p.new(.{ .str = tok.text }),
            .ident => {
                if (p.eat("(")) {
                    // a call: expressions with commas between, up to the )
                    var args: std.ArrayList(*CExpr) = .empty;
                    if (!p.eat(")")) {
                        while (true) {
                            try args.append(p.alloc, try p.parseExpr());
                            if (!p.eat(",")) break;
                        }
                        try p.expect(")");
                    }
                    return p.new(.{ .call = .{ .name = tok.text, .args = args.items } });
                }
                if (p.lookup(tok.text)) |n| return p.new(.{ .local = n });
                return p.new(.{ .global = tok.text });
            },
            else => {},
        }
        if (tok.is(.punct, "(")) {
            // brackets leave no node: they only decided the tree's shape
            const inside = try p.parseExpr();
            try p.expect(")");
            return inside;
        }
        p.at -= @intFromBool(tok.kind != .eof); // point the error at this token
        return error.SyntaxError;
    }

    /// e = e + 1 or e = e - 1: what ++ and -- mean.
    fn step(p: *CParser, target: *CExpr, op: CBinary) !*CExpr {
        try needTarget(target);
        const sum = try p.new(.{ .binary = .{ .op = op, .lhs = try p.clone(target), .rhs = try p.new(.{ .num = 1 }) } });
        return p.new(.{ .assign = .{ .target = target, .value = sum } });
    }

    fn parsePostfix(p: *CParser) anyerror!*CExpr {
        var e = try p.parsePrimary();
        while (true) {
            if (p.eat("[")) {
                const at = try p.parseExpr();
                try p.expect("]");
                e = try p.new(.{ .index = .{ .base = e, .at = at } });
            } else if (p.eat("++")) {
                // the stepped value, minus one again: the value from before
                const stepped = try p.step(e, .add);
                e = try p.new(.{ .binary = .{ .op = .sub, .lhs = stepped, .rhs = try p.new(.{ .num = 1 }) } });
            } else if (p.eat("--")) {
                const stepped = try p.step(e, .sub);
                e = try p.new(.{ .binary = .{ .op = .add, .lhs = stepped, .rhs = try p.new(.{ .num = 1 }) } });
            } else return e;
        }
    }

    fn parseUnary(p: *CParser) anyerror!*CExpr {
        // What follows a unary operator is again a unary: - - x, *p++, !*p.
        if (p.eat("-")) return p.new(.{ .unary = .{ .op = .neg, .arg = try p.parseUnary() } });
        if (p.eat("~")) return p.new(.{ .unary = .{ .op = .not, .arg = try p.parseUnary() } });
        if (p.eat("!")) return p.new(.{ .unary = .{ .op = .lnot, .arg = try p.parseUnary() } });
        if (p.eat("*")) return p.new(.{ .deref = .{ .arg = try p.parseUnary() } });
        if (p.eat("&")) {
            const arg = try p.parseUnary();
            try needTarget(arg); // only something that lives in memory has an address
            return p.new(.{ .addr = arg });
        }
        if (p.eat("++")) return p.step(try p.parseUnary(), .add);
        if (p.eat("--")) return p.step(try p.parseUnary(), .sub);
        if (p.sees("(") and startsType(p.toks[p.at + 1])) {
            // a cast: (type) in front of a unary
            p.at += 1;
            const to = try p.parsePointers(p.parseBaseType().?);
            try p.expect(")");
            return p.new(.{ .cast = .{ .to = to, .arg = try p.parseUnary() } });
        }
        return p.parsePostfix();
    }

    fn binaryInfo(tok: CToken) ?CBinaryInfo {
        if (tok.kind != .punct) return null;
        for (c_binary_ops) |info| {
            if (std.mem.eql(u8, tok.text, info.text)) return info;
        }
        return null;
    }

    /// Precedence climbing: a unary, then every operator that is at
    /// least `min` strong, each with its right-hand side.
    fn parseBinary(p: *CParser, min: u8) anyerror!*CExpr {
        var lhs = try p.parseUnary();
        while (binaryInfo(p.peek())) |info| {
            if (info.strength < min) break; // too weak: it belongs to someone above us
            p.at += 1;
            // the right-hand side takes only operators stronger than this one
            const rhs = try p.parseBinary(info.strength + 1);
            lhs = try p.new(.{ .binary = .{ .op = info.op, .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    /// Only these can be assigned to, or have their address taken.
    fn needTarget(e: *const CExpr) !void {
        switch (e.*) {
            .local, .global, .deref, .index => {},
            else => return error.NotAssignable,
        }
    }

    fn parseAssign(p: *CParser) anyerror!*CExpr {
        const lhs = try p.parseBinary(1);
        if (p.eat("=")) {
            try needTarget(lhs);
            // a = b = c is a = (b = c)
            return p.new(.{ .assign = .{ .target = lhs, .value = try p.parseAssign() } });
        }
        for ([_]CBinaryInfo{ .{ .text = "+=", .op = .add, .strength = 0 }, .{ .text = "-=", .op = .sub, .strength = 0 } }) |sugar| {
            if (!p.eat(sugar.text)) continue;
            try needTarget(lhs);
            const sum = try p.new(.{ .binary = .{ .op = sugar.op, .lhs = try p.clone(lhs), .rhs = try p.parseAssign() } });
            return p.new(.{ .assign = .{ .target = lhs, .value = sum } });
        }
        return lhs;
    }

    fn parseExpr(p: *CParser) anyerror!*CExpr {
        return p.parseAssign();
    }
};

fn writeCType(w: *std.Io.Writer, t: CType) !void {
    switch (t) {
        .int, .char, .void => try w.writeAll(@tagName(t)),
        .ptr => |pointee| {
            try writeCType(w, pointee.*);
            try w.writeAll("*");
        },
        .array => |a| {
            try writeCType(w, a.elem.*);
            try w.print("[{d}]", .{a.len});
        },
    }
}

/// The tree as text: (operator operand operand). `locals` gives the
/// local variables their names back.
fn writeCExpr(w: *std.Io.Writer, e: *const CExpr, locals: []const CVar) !void {
    switch (e.*) {
        .num => |n| try w.print("{d}", .{n}),
        .str => |s| try w.print("\"{s}\"", .{s}),
        .local => |n| try w.writeAll(locals[n].name),
        .global => |name| try w.writeAll(name),
        .unary => |u| {
            try w.writeAll(switch (u.op) {
                .neg => "(- ",
                .not => "(~ ",
                .lnot => "(! ",
            });
            try writeCExpr(w, u.arg, locals);
            try w.writeAll(")");
        },
        .deref => |d| {
            try w.writeAll(if (d.byte) "(*b " else "(* ");
            try writeCExpr(w, d.arg, locals);
            try w.writeAll(")");
        },
        .addr => |a| {
            try w.writeAll("(& ");
            try writeCExpr(w, a, locals);
            try w.writeAll(")");
        },
        .binary => |b| {
            const text = for (c_binary_ops) |info| {
                if (info.op == b.op) break info.text;
            } else unreachable;
            try w.print("({s} ", .{text});
            try writeCExpr(w, b.lhs, locals);
            try w.writeAll(" ");
            try writeCExpr(w, b.rhs, locals);
            try w.writeAll(")");
        },
        .assign => |a| {
            try w.writeAll("(= ");
            try writeCExpr(w, a.target, locals);
            try w.writeAll(" ");
            try writeCExpr(w, a.value, locals);
            try w.writeAll(")");
        },
        .call => |c| {
            try w.print("(call {s}", .{c.name});
            for (c.args) |arg| {
                try w.writeAll(" ");
                try writeCExpr(w, arg, locals);
            }
            try w.writeAll(")");
        },
        .index => |x| {
            try w.writeAll("(index ");
            try writeCExpr(w, x.base, locals);
            try w.writeAll(" ");
            try writeCExpr(w, x.at, locals);
            try w.writeAll(")");
        },
        .cast => |c| {
            try w.writeAll("(cast ");
            try writeCType(w, c.to);
            try w.writeAll(" ");
            try writeCExpr(w, c.arg, locals);
            try w.writeAll(")");
        },
    }
}
/// How many bytes a value of this type takes. An int and a pointer are 4
/// (one register), a char is 1, and an array is all its elements.
fn cSizeOf(t: CType) u32 {
    return switch (t) {
        .int, .ptr => 4,
        .char => 1,
        .void => 0,
        .array => |a| a.len * cSizeOf(a.elem.*),
    };
}

const CStmt = union(enum) {
    expr: *CExpr,
    block: []*CStmt,
    @"if": struct { cond: *CExpr, then: *CStmt, otherwise: ?*CStmt },
    /// while and for. No condition: forever.
    loop: struct { cond: ?*CExpr, body: *CStmt, step: ?*CExpr },
    ret: ?*CExpr,
    brk,
    cont,
};

const CFunction = struct {
    name: []const u8,
    ret: CType,
    /// Every variable of the function. The first `params` of them are
    /// its parameters, in order.
    locals: []CVar,
    params: u32,
    body: *CStmt,
};

const CGlobal = struct {
    name: []const u8,
    type: CType,
    /// A number or a string, if any.
    init: ?*CExpr,
    /// Declared with `extern`: it lives in another file, and this one
    /// only needs to know its type.
    external: bool = false,
};

/// One source file, parsed.
const CUnit = struct { functions: []CFunction, globals: []CGlobal };

fn cNewStmt(p: *CParser, s: CStmt) !*CStmt {
    const node = try p.alloc.create(CStmt);
    node.* = s;
    return node;
}

/// After the base type: stars, a name, and maybe [length]. Empty
/// brackets, as in `char s[]`, make a pointer: that is what an array
/// parameter is.
fn cParseDeclarator(p: *CParser, base: CType) !CVar {
    var t = try p.parsePointers(base);
    const name = p.next();
    if (name.kind != .ident) return error.SyntaxError;
    if (p.eat("[")) {
        const elem = try p.alloc.create(CType);
        elem.* = t;
        if (p.eat("]")) {
            t = .{ .ptr = elem };
        } else {
            const len = p.next();
            if (len.kind != .num) return error.SyntaxError;
            try p.expect("]");
            t = .{ .array = .{ .elem = elem, .len = len.num } };
        }
    }
    return .{ .name = name.text, .type = t };
}

/// Adds a variable to the function, visible from here on. Returns its
/// number. The same name twice in one block is an error; in an inner
/// block it is fine, and hides the outer one.
fn cDeclare(p: *CParser, v: CVar) !u32 {
    for (p.scope.items[p.block_start..]) |n| {
        if (std.mem.eql(u8, p.locals.items[n].name, v.name)) return error.Redeclared;
    }
    const number: u32 = @intCast(p.locals.items.len);
    try p.locals.append(p.alloc, v);
    try p.scope.append(p.alloc, number);
    return number;
}

/// `int x = 1, *p, a[10];` with the base type already read. The
/// variables are declared, and what is left for the tree is the
/// assignments.
fn cParseLocals(p: *CParser, base: CType) !*CStmt {
    var inits: std.ArrayList(*CStmt) = .empty;
    while (true) {
        const n = try cDeclare(p, try cParseDeclarator(p, base));
        if (p.eat("=")) {
            const target = try p.new(.{ .local = n });
            const assign = try p.new(.{ .assign = .{ .target = target, .value = try p.parseAssign() } });
            try inits.append(p.alloc, try cNewStmt(p, .{ .expr = assign }));
        }
        if (!p.eat(",")) break;
    }
    try p.expect(";");
    return cNewStmt(p, .{ .block = inits.items });
}

/// The statements up to the closing brace; the opening one has been
/// read. Whatever they declare can be seen until the block ends.
fn cParseBlock(p: *CParser) anyerror!*CStmt {
    const outer_len = p.scope.items.len;
    const outer_start = p.block_start;
    p.block_start = outer_len;
    var list: std.ArrayList(*CStmt) = .empty;
    while (!p.eat("}")) {
        if (p.peek().kind == .eof) return error.SyntaxError;
        try list.append(p.alloc, try cParseStmt(p));
    }
    p.scope.items.len = outer_len;
    p.block_start = outer_start;
    return cNewStmt(p, .{ .block = list.items });
}

fn cParseStmt(p: *CParser) anyerror!*CStmt {
    if (p.eat("{")) return cParseBlock(p);
    if (p.eat(";")) return cNewStmt(p, .{ .block = &.{} });
    if (p.parseBaseType()) |base| return cParseLocals(p, base);
    if (p.eat("if")) {
        try p.expect("(");
        const cond = try p.parseExpr();
        try p.expect(")");
        const then = try cParseStmt(p);
        // The else is optional. (And in  if (a) if (b) x; else y;  this
        // line is why the else belongs to the NEAREST if: the inner call
        // gets to look for it first.)
        const otherwise: ?*CStmt = if (p.eat("else")) try cParseStmt(p) else null;
        return cNewStmt(p, .{ .@"if" = .{ .cond = cond, .then = then, .otherwise = otherwise } });
    }
    if (p.eat("while")) {
        try p.expect("(");
        const cond = try p.parseExpr();
        try p.expect(")");
        return cNewStmt(p, .{ .loop = .{ .cond = cond, .body = try cParseStmt(p), .step = null } });
    }
    if (p.eat("for")) {
        // for (init; cond; step) body  becomes  { init; loop }. Each of
        // the three parts may be missing. A variable declared in the
        // init lives until the loop ends.
        const outer_len = p.scope.items.len;
        const outer_start = p.block_start;
        p.block_start = outer_len;
        try p.expect("(");
        const init = try cParseStmt(p); // a declaration, an expression statement, or just ;
        const cond: ?*CExpr = if (p.sees(";")) null else try p.parseExpr();
        try p.expect(";");
        const step: ?*CExpr = if (p.sees(")")) null else try p.parseExpr();
        try p.expect(")");
        const body = try cParseStmt(p);
        p.scope.items.len = outer_len;
        p.block_start = outer_start;
        const loop = try cNewStmt(p, .{ .loop = .{ .cond = cond, .body = body, .step = step } });
        const both = try p.alloc.alloc(*CStmt, 2);
        both[0] = init;
        both[1] = loop;
        return cNewStmt(p, .{ .block = both });
    }
    if (p.eat("return")) {
        const value: ?*CExpr = if (p.sees(";")) null else try p.parseExpr();
        try p.expect(";");
        return cNewStmt(p, .{ .ret = value });
    }
    if (p.eat("break")) {
        try p.expect(";");
        return cNewStmt(p, .brk);
    }
    if (p.eat("continue")) {
        try p.expect(";");
        return cNewStmt(p, .cont);
    }
    const e = try p.parseExpr();
    try p.expect(";");
    return cNewStmt(p, .{ .expr = e });
}

/// A whole file. `p` must have an arena for its allocator.
fn cParseUnit(p: *CParser) !CUnit {
    var functions: std.ArrayList(CFunction) = .empty;
    var globals: std.ArrayList(CGlobal) = .empty;
    while (p.peek().kind != .eof) {
        const external = p.eat("extern");
        const base = p.parseBaseType() orelse return error.SyntaxError;
        const first = try cParseDeclarator(p, base);
        if (!p.eat("(")) {
            // global variables: `int x = 1, y;`
            var v = first;
            while (true) {
                const init: ?*CExpr = if (p.eat("=")) try p.parseBinary(1) else null;
                try globals.append(p.alloc, .{ .name = v.name, .type = v.type, .init = init, .external = external });
                if (!p.eat(",")) break;
                v = try cParseDeclarator(p, base);
            }
            try p.expect(";");
            continue;
        }
        // a function: its parameters are its first locals
        p.locals = .empty;
        p.scope = .empty;
        p.block_start = 0;
        if (!p.eat(")")) {
            if (p.sees("void") and p.toks[p.at + 1].is(.punct, ")")) {
                p.at += 2; // f(void): no parameters
            } else {
                while (true) {
                    const param_base = p.parseBaseType() orelse return error.SyntaxError;
                    _ = try cDeclare(p, try cParseDeclarator(p, param_base));
                    if (!p.eat(",")) break;
                }
                try p.expect(")");
            }
        }
        const params: u32 = @intCast(p.locals.items.len);
        if (p.eat(";")) continue; // only a promise that the function exists somewhere
        try p.expect("{");
        const body = try cParseBlock(p);
        try functions.append(p.alloc, .{ .name = first.name, .ret = first.type, .locals = p.locals.items, .params = params, .body = body });
    }
    return .{ .functions = functions.items, .globals = globals.items };
}

/// Parses C source. Everything is allocated in `arena`. If it fails and
/// `err_line` isn't null, the line of the mistake is put there.
fn cParse(arena: std.mem.Allocator, source: []const u8, err_line: ?*u32) !CUnit {
    var p: CParser = .{ .toks = try cLex(arena, source), .alloc = arena };
    return cParseUnit(&p) catch |err| {
        if (err_line) |l| l.* = p.line();
        return err;
    };
}

/// A statement as text, on one line.
fn writeCStmt(w: *std.Io.Writer, s: *const CStmt, locals: []const CVar) !void {
    switch (s.*) {
        .expr => |e| {
            try writeCExpr(w, e, locals);
            try w.writeAll(";");
        },
        .block => |list| {
            try w.writeAll("{");
            for (list) |inner| {
                try w.writeAll(" ");
                try writeCStmt(w, inner, locals);
            }
            try w.writeAll(" }");
        },
        .@"if" => |i| {
            try w.writeAll("if ");
            try writeCExpr(w, i.cond, locals);
            try w.writeAll(" ");
            try writeCStmt(w, i.then, locals);
            if (i.otherwise) |o| {
                try w.writeAll(" else ");
                try writeCStmt(w, o, locals);
            }
        },
        .loop => |l| {
            try w.writeAll("loop ");
            if (l.cond) |c| try writeCExpr(w, c, locals) else try w.writeAll("forever");
            try w.writeAll(" ");
            try writeCStmt(w, l.body, locals);
            if (l.step) |st| {
                try w.writeAll(" step ");
                try writeCExpr(w, st, locals);
            }
        },
        .ret => |value| {
            try w.writeAll("return");
            if (value) |v| {
                try w.writeAll(" ");
                try writeCExpr(w, v, locals);
            }
            try w.writeAll(";");
        },
        .brk => try w.writeAll("break;"),
        .cont => try w.writeAll("continue;"),
    }
}
const CGen = struct {
    out: *std.Io.Writer,
    alloc: std.mem.Allocator,
    unit: *const CUnit,
    /// The function being generated, and how far below fp each of its
    /// locals is.
    f: *const CFunction = undefined,
    offsets: []u32 = &.{},
    /// Labels handed out so far.
    labels: u32 = 0,
    /// Where `return`, `break` and `continue` jump to right now.
    return_label: u32 = 0,
    break_label: ?u32 = null,
    continue_label: ?u32 = null,
    /// The string constants met so far: they are written out at the end.
    strings: std.ArrayList([]const u8) = .empty,

    /// One instruction.
    fn emit(g: *CGen, comptime fmt: []const u8, args: anytype) !void {
        try g.out.print("        " ++ fmt ++ "\n", args);
    }

    fn newLabel(g: *CGen) u32 {
        g.labels += 1;
        return g.labels;
    }

    fn place(g: *CGen, label: u32) !void {
        try g.out.print(".L{d}:\n", .{label});
    }

    fn push(g: *CGen) !void {
        try g.emit("str r0, [sp, #-4]!", .{});
    }

    fn pop(g: *CGen, reg: u32) !void {
        try g.emit("ldr r{d}, [sp], #4", .{reg});
    }

    /// reg = value. mov can only make "8 bits, rotated" (214); mvn makes
    /// the inverses of those; anything else comes from the literal pool.
    fn constant(g: *CGen, reg: u32, value: u32) !void {
        if (encodeImm(value) != null) {
            try g.emit("mov r{d}, #{d}", .{ reg, value });
        } else if (encodeImm(~value) != null) {
            try g.emit("mvn r{d}, #{d}", .{ reg, ~value });
        } else {
            try g.emit("ldr r{d}, =0x{x}", .{ reg, value });
        }
    }

    /// The type of something that lives in memory. A name that was never
    /// declared is taken for an int.
    fn typeOfTarget(g: *const CGen, e: *const CExpr) CType {
        switch (e.*) {
            .local => |n| return g.f.locals[n].type,
            .global => |name| {
                for (g.unit.globals) |v| {
                    if (std.mem.eql(u8, v.name, name)) return v.type;
                }
                return .int;
            },
            .deref => |d| return if (d.byte) .char else .int,
            else => return .int,
        }
    }

    /// Writes code that leaves the ADDRESS of e in r0.
    fn genAddr(g: *CGen, e: *const CExpr) anyerror!void {
        switch (e.*) {
            .local => |n| {
                const offset = g.offsets[n];
                if (encodeImm(offset) != null) {
                    try g.emit("sub r0, fp, #{d}", .{offset});
                } else {
                    try g.constant(0, offset);
                    try g.emit("sub r0, fp, r0", .{});
                }
            },
            .global => |name| try g.emit("ldr r0, ={s}", .{name}),
            // The address of *p is... the value of p.
            .deref => |d| try g.genExpr(d.arg),
            .index => return error.NotLowered, // 228 turns a[i] into *(a + i)
            else => return error.NotAssignable,
        }
    }

    /// Writes code that leaves the VALUE of e in r0.
    fn genExpr(g: *CGen, e: *const CExpr) anyerror!void {
        switch (e.*) {
            .num => |n| try g.constant(0, n),
            .str => |s| {
                try g.emit("ldr r0, =.Lstr{d}", .{g.strings.items.len});
                try g.strings.append(g.alloc, s);
            },
            .local, .global, .deref => {
                try g.genAddr(e);
                switch (g.typeOfTarget(e)) {
                    .array => {}, // an array's value IS its address (228)
                    .char => try g.emit("ldrb r0, [r0]", .{}),
                    else => try g.emit("ldr r0, [r0]", .{}),
                }
            },
            .index => return error.NotLowered,
            .addr => |target| try g.genAddr(target),
            .unary => |u| {
                try g.genExpr(u.arg);
                switch (u.op) {
                    .neg => try g.emit("rsb r0, r0, #0", .{}),
                    .not => try g.emit("mvn r0, r0", .{}),
                    .lnot => {
                        try g.emit("cmp r0, #0", .{});
                        try g.emit("moveq r0, #1", .{});
                        try g.emit("movne r0, #0", .{});
                    },
                }
            },
            .binary => |b| switch (b.op) {
                .log_and => {
                    // If the left side is 0, the answer is that 0, and
                    // the right side must not even run.
                    const end = g.newLabel();
                    try g.genExpr(b.lhs);
                    try g.emit("cmp r0, #0", .{});
                    try g.emit("beq .L{d}", .{end});
                    try g.genExpr(b.rhs);
                    try g.emit("cmp r0, #0", .{});
                    try g.emit("movne r0, #1", .{});
                    try g.place(end);
                },
                .log_or => {
                    const one = g.newLabel();
                    const end = g.newLabel();
                    try g.genExpr(b.lhs);
                    try g.emit("cmp r0, #0", .{});
                    try g.emit("bne .L{d}", .{one});
                    try g.genExpr(b.rhs);
                    try g.emit("cmp r0, #0", .{});
                    try g.emit("beq .L{d}", .{end});
                    try g.place(one);
                    try g.emit("mov r0, #1", .{});
                    try g.place(end);
                },
                else => {
                    // the stack machine: left, push, right, pop
                    try g.genExpr(b.lhs);
                    try g.push();
                    try g.genExpr(b.rhs);
                    try g.pop(1);
                    try g.genOperator(b.op);
                },
            },
            .assign => |a| {
                // the address waits on the stack while the value is worked out
                try g.genAddr(a.target);
                try g.push();
                try g.genExpr(a.value);
                try g.pop(1);
                if (g.typeOfTarget(a.target) == .char) {
                    try g.emit("strb r0, [r1]", .{});
                } else {
                    try g.emit("str r0, [r1]", .{});
                }
                // r0 still holds the value: that is what `a = b = c` needs
            },
            .call => |c| {
                if (c.args.len > 4) return error.TooManyArguments;
                // Work the arguments out one by one, onto the stack. (Not
                // straight into r0 to r3: working out the second argument
                // would destroy the first.)
                for (c.args) |arg| {
                    try g.genExpr(arg);
                    try g.push();
                }
                // Then pop them into place. The LAST one pushed is on top.
                var reg = c.args.len;
                while (reg > 0) {
                    reg -= 1;
                    try g.pop(@intCast(reg));
                }
                try g.emit("bl {s}", .{c.name});
            },
            .cast => |c| {
                try g.genExpr(c.arg);
                if (c.to == .char) try g.emit("and r0, r0, #255", .{});
            },
        }
    }

    /// The left value is in r1, the right one in r0. The result goes to r0.
    fn genOperator(g: *CGen, op: CBinary) !void {
        switch (op) {
            .add => try g.emit("add r0, r1, r0", .{}),
            .sub => try g.emit("sub r0, r1, r0", .{}),
            .mul => try g.emit("mul r0, r1, r0", .{}),
            .div, .mod => {
                // The processor can't divide. A function does it (230),
                // and wants the left value in r0 and the right in r1.
                try g.emit("mov r2, r0", .{});
                try g.emit("mov r0, r1", .{});
                try g.emit("mov r1, r2", .{});
                try g.emit("bl {s}", .{if (op == .div) "__divsi3" else "__modsi3"});
            },
            .shl => try g.emit("mov r0, r1, lsl r0", .{}),
            .shr => try g.emit("mov r0, r1, asr r0", .{}),
            .bit_and => try g.emit("and r0, r1, r0", .{}),
            .bit_xor => try g.emit("eor r0, r1, r0", .{}),
            .bit_or => try g.emit("orr r0, r1, r0", .{}),
            .lt, .le, .gt, .ge, .eq, .ne => {
                // A comparison's value is 1 or 0: compare, assume 0, and
                // then conditionally make it 1. The condition is the
                // operator's own name: movlt, movle, ...
                try g.emit("cmp r1, r0", .{});
                try g.emit("mov r0, #0", .{});
                try g.emit("mov{s} r0, #1", .{@tagName(op)});
            },
            .log_and, .log_or => unreachable,
        }
    }

    fn genStmt(g: *CGen, s: *const CStmt) anyerror!void {
        switch (s.*) {
            .expr => |e| try g.genExpr(e),
            .block => |list| for (list) |inner| try g.genStmt(inner),
            .@"if" => |i| {
                const otherwise = g.newLabel();
                const end = g.newLabel();
                try g.genExpr(i.cond);
                try g.emit("cmp r0, #0", .{});
                try g.emit("beq .L{d}", .{otherwise});
                try g.genStmt(i.then);
                try g.emit("b .L{d}", .{end});
                try g.place(otherwise);
                if (i.otherwise) |o| try g.genStmt(o);
                try g.place(end);
            },
            .loop => |l| {
                //  top:   if the condition is 0, go to end
                //         the body
                //  next:  the step      <- `continue` comes here
                //         go to top
                //  end:                 <- `break` comes here
                const top = g.newLabel();
                const next = g.newLabel();
                const end = g.newLabel();
                const outer_break = g.break_label;
                const outer_continue = g.continue_label;
                g.break_label = end;
                g.continue_label = next;
                try g.place(top);
                if (l.cond) |cond| {
                    try g.genExpr(cond);
                    try g.emit("cmp r0, #0", .{});
                    try g.emit("beq .L{d}", .{end});
                }
                try g.genStmt(l.body);
                try g.place(next);
                if (l.step) |st| try g.genExpr(st);
                try g.emit("b .L{d}", .{top});
                try g.place(end);
                g.break_label = outer_break;
                g.continue_label = outer_continue;
            },
            .ret => |value| {
                if (value) |v| try g.genExpr(v);
                try g.emit("b .L{d}", .{g.return_label});
            },
            .brk => try g.emit("b .L{d}", .{g.break_label orelse return error.NotInLoop}),
            .cont => try g.emit("b .L{d}", .{g.continue_label orelse return error.NotInLoop}),
        }
    }

    fn genFunction(g: *CGen, f: *const CFunction) !void {
        if (f.params > 4) return error.TooManyArguments;
        g.f = f;
        g.return_label = g.newLabel();
        // Lay out the frame: each local goes below the ones before it.
        // Everything takes a multiple of 4 bytes, so words stay aligned.
        g.offsets = try g.alloc.alloc(u32, f.locals.len);
        var frame_size: u32 = 0;
        for (f.locals, g.offsets) |v, *offset| {
            frame_size += alignUp(cSizeOf(v.type), 4);
            offset.* = frame_size;
        }

        try g.out.print("{s}:\n", .{f.name});
        // the prologue
        try g.emit("str lr, [sp, #-4]!", .{});
        try g.emit("str fp, [sp, #-4]!", .{});
        try g.emit("mov fp, sp", .{});
        if (encodeImm(frame_size) != null) {
            try g.emit("sub sp, sp, #{d}", .{frame_size});
        } else {
            try g.constant(12, frame_size);
            try g.emit("sub sp, sp, r12", .{});
        }
        // the parameters arrive in registers, and are locals like any other
        for (0..f.params) |n| {
            try g.emit("str r{d}, [fp, #-{d}]", .{ n, g.offsets[n] });
        }
        try g.genStmt(f.body);
        // The epilogue: drop the locals, restore fp, and pop the return
        // address straight into pc.
        try g.place(g.return_label);
        try g.emit("mov sp, fp", .{});
        try g.emit("ldr fp, [sp], #4", .{});
        try g.emit("ldr pc, [sp], #4", .{});
        try g.emit(".ltorg", .{}); // the function's constants: nothing runs into them here
    }

    /// The value of a global's initializer, if it is a number.
    fn constantValue(e: *const CExpr) ?u32 {
        return switch (e.*) {
            .num => |n| n,
            .unary => |u| blk: {
                const v = constantValue(u.arg) orelse break :blk null;
                break :blk switch (u.op) {
                    .neg => 0 -% v,
                    .not => ~v,
                    .lnot => @intFromBool(v == 0),
                };
            },
            .cast => |c| constantValue(c.arg),
            else => null,
        };
    }

    fn genGlobal(g: *CGen, v: CGlobal) !void {
        if (v.external) return; // somebody else's: the linker will find it
        try g.out.print("{s}:\n", .{v.name});
        if (v.init) |init| {
            if (init.* == .str) {
                try g.emit(".word .Lstr{d}", .{g.strings.items.len});
                try g.strings.append(g.alloc, init.str);
            } else {
                const value = constantValue(init) orelse return error.NotConstant;
                try g.emit("{s} 0x{x}", .{ if (v.type == .char) ".byte" else ".word", value });
            }
        } else {
            try g.emit(".space {d}", .{cSizeOf(v.type)});
        }
        try g.emit(".align 2", .{});
    }
};

/// The assembly for a parsed file. The caller frees it.
fn cGenerate(alloc: std.mem.Allocator, unit: *const CUnit) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var g: CGen = .{ .out = &out.writer, .alloc = arena.allocator(), .unit = unit };
    for (unit.functions) |*f| try g.genFunction(f);
    for (unit.globals) |v| try g.genGlobal(v);
    for (g.strings.items, 0..) |s, n| {
        try out.writer.print(".Lstr{d}:\n        .asciz \"{s}\"\n        .align 2\n", .{ n, s });
    }
    return out.toOwnedSlice();
}

/// What runs first: set up a stack at the top of 64 KB, call main, and
/// stop. main's result is left in r0.
const c_start =
    \\_start: mov   sp, #0x10000
    \\        bl    main
    \\        swi   0
    \\
;

const CRun = struct { result: u32, output: []u8 };

/// Assembles `asm_source` (after c_start), runs it on the emulator with
/// `input` at the UART, and returns main's result and what was sent. The
/// caller frees the output.
fn runAssembly(gpa: std.mem.Allocator, asm_source: []const u8, input: []const u8) !CRun {
    const whole = try std.mem.concat(gpa, u8, &.{ c_start, asm_source });
    defer gpa.free(whole);
    var line_no: usize = 0;
    var prog = assemble(gpa, whole, 0, &line_no) catch |err| {
        var lines = std.mem.splitScalar(u8, whole, '\n');
        var n: usize = 1;
        while (lines.next()) |text| : (n += 1) {
            if (n == line_no) std.debug.print("the assembler says {s} about line {d} of the compiler's output:\n{s}\n", .{ @errorName(err), n, text });
        }
        return err;
    };
    defer prog.deinit(gpa);
    var board = try Board.init(gpa, 0x10000);
    defer board.deinit();
    board.load(0, prog.code);
    board.uart_in = input;
    var cpu: Cpu = .{};
    const event = cpu.run(&board, 5_000_000) orelse return error.RanTooLong;
    if (event != .swi) {
        std.debug.print("the program stopped at pc = 0x{x}: {any}\n", .{ cpu.r[PC], event });
        return error.ProgramCrashed;
    }
    return .{ .result = cpu.r[0], .output = try gpa.dupe(u8, board.uart_out.items) };
}
/// What a pointer or an array is made of. null: `t` is neither.
fn cElementOf(t: CType) ?CType {
    return switch (t) {
        .ptr => |pointee| pointee.*,
        .array => |a| a.elem.*,
        else => null,
    };
}

/// How far apart two neighbouring elements are. (A void* counts in bytes.)
fn cStride(element: CType) u32 {
    return @max(1, cSizeOf(element));
}

const c_char_type: CType = .char;

const CLower = struct {
    /// An arena: new nodes and new types are made here.
    alloc: std.mem.Allocator,
    unit: *const CUnit,
    f: *const CFunction,

    fn pointerTo(lo: *CLower, t: CType) !CType {
        const pointee = try lo.alloc.create(CType);
        pointee.* = t;
        return .{ .ptr = pointee };
    }

    fn typeOf(lo: *CLower, e: *const CExpr) anyerror!CType {
        switch (e.*) {
            .num, .unary => return .int,
            .str => return .{ .ptr = &c_char_type },
            .local => |n| return lo.f.locals[n].type,
            .global => |name| {
                for (lo.unit.globals) |v| {
                    if (std.mem.eql(u8, v.name, name)) return v.type;
                }
                return .int;
            },
            // *p is what p points at. (Of something that is no pointer:
            // an int. C would refuse; we let it through.)
            .deref => |d| return cElementOf(try lo.typeOf(d.arg)) orelse .int,
            .addr => |target| return lo.pointerTo(try lo.typeOf(target)),
            .index => |x| return cElementOf(try lo.typeOf(x.base)) orelse .int,
            .assign => |a| return lo.typeOf(a.target),
            .cast => |c| return c.to,
            .call => |c| {
                for (lo.unit.functions) |f| {
                    if (std.mem.eql(u8, f.name, c.name)) return f.ret;
                }
                return .int;
            },
            .binary => |b| {
                if (b.op != .add and b.op != .sub) return .int;
                const left = cElementOf(try lo.typeOf(b.lhs));
                const right = cElementOf(try lo.typeOf(b.rhs));
                // pointer - pointer is a count. Otherwise, a sum with a
                // pointer (or an array) in it is a pointer to the same
                // kind of element.
                if (left != null and right != null) return .int;
                if (left orelse right) |element| return lo.pointerTo(element);
                return .int;
            },
        }
    }

    fn new(lo: *CLower, e: CExpr) !*CExpr {
        const node = try lo.alloc.create(CExpr);
        node.* = e;
        return node;
    }

    /// e * stride, or just e when the stride is 1.
    fn scaled(lo: *CLower, e: *CExpr, stride: u32) !*CExpr {
        if (stride == 1) return e;
        return lo.new(.{ .binary = .{ .op = .mul, .lhs = e, .rhs = try lo.new(.{ .num = stride }) } });
    }

    /// Rewrites the tree under e, in place.
    fn lower(lo: *CLower, e: *CExpr) anyerror!void {
        switch (e.*) {
            .num, .str, .local, .global => {},
            .unary => |u| try lo.lower(u.arg),
            .addr => |target| try lo.lower(target),
            .cast => |c| try lo.lower(c.arg),
            .call => |c| for (c.args) |arg| try lo.lower(arg),
            .assign => |a| {
                try lo.lower(a.target);
                try lo.lower(a.value);
            },
            .deref => |*d| {
                try lo.lower(d.arg);
                // one byte, if what the pointer points at is a char
                const element = cElementOf(try lo.typeOf(d.arg)) orelse CType.int;
                d.byte = element == .char;
            },
            .index => |x| {
                // a[i] is *(a + i). Make that tree, and lower IT: the
                // sum still needs its scaling, the * its size.
                const sum = try lo.new(.{ .binary = .{ .op = .add, .lhs = x.base, .rhs = x.at } });
                e.* = .{ .deref = .{ .arg = sum } };
                try lo.lower(e);
            },
            .binary => |*b| {
                try lo.lower(b.lhs);
                try lo.lower(b.rhs);
                if (b.op != .add and b.op != .sub) return;
                const left = cElementOf(try lo.typeOf(b.lhs));
                const right = cElementOf(try lo.typeOf(b.rhs));
                if (left != null and right != null) {
                    if (b.op == .add) return error.AddingPointers;
                    // pointer - pointer: the bytes between them, divided
                    // by the stride. The strides here are 1 and 4, so a
                    // shift does the dividing.
                    if (cStride(left.?) == 4) {
                        const bytes = try lo.new(e.*);
                        e.* = .{ .binary = .{ .op = .shr, .lhs = bytes, .rhs = try lo.new(.{ .num = 2 }) } };
                    }
                } else if (left) |element| {
                    // pointer + n, pointer - n: n counts elements
                    b.rhs = try lo.scaled(b.rhs, cStride(element));
                } else if (right) |element| {
                    // n + pointer
                    if (b.op == .sub) return error.SubtractingPointer;
                    b.lhs = try lo.scaled(b.lhs, cStride(element));
                }
            },
        }
    }

    fn lowerStmt(lo: *CLower, s: *CStmt) anyerror!void {
        switch (s.*) {
            .expr => |e| try lo.lower(e),
            .block => |list| for (list) |inner| try lo.lowerStmt(inner),
            .@"if" => |i| {
                try lo.lower(i.cond);
                try lo.lowerStmt(i.then);
                if (i.otherwise) |o| try lo.lowerStmt(o);
            },
            .loop => |l| {
                if (l.cond) |cond| try lo.lower(cond);
                try lo.lowerStmt(l.body);
                if (l.step) |st| try lo.lower(st);
            },
            .ret => |value| if (value) |v| try lo.lower(v),
            .brk, .cont => {},
        }
    }
};

/// The whole compiler: C in, assembly out. The caller frees the
/// assembly. If it fails and `err_line` isn't null, the line of a syntax
/// error is put there.
fn cCompile(gpa: std.mem.Allocator, source: []const u8, err_line: ?*u32) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const unit = try cParse(arena.allocator(), source, err_line);
    for (unit.functions) |*f| {
        var lo: CLower = .{ .alloc = arena.allocator(), .unit = &unit, .f = f };
        try lo.lowerStmt(f.body);
    }
    return cGenerate(gpa, &unit);
}

/// Compiles C, puts `assembly` after it (for functions written by hand),
/// and runs the lot on the emulator. The caller frees the output.
fn cRun(gpa: std.mem.Allocator, source: []const u8, assembly: []const u8, input: []const u8) !CRun {
    var line: u32 = 0;
    const compiled = cCompile(gpa, source, &line) catch |err| {
        std.debug.print("the compiler says {s} (if it is about syntax: line {d})\n", .{ @errorName(err), line });
        return err;
    };
    defer gpa.free(compiled);
    const whole = try std.mem.concat(gpa, u8, &.{ compiled, assembly });
    defer gpa.free(whole);
    return runAssembly(gpa, whole, input);
}
const RelocKind = enum { abs32, call24 };

const Reloc = struct {
    /// The offset, in the object's code, of the word to patch.
    site: u32,
    kind: RelocKind,
    name: []const u8,
};

const ObjSymbol = struct { name: []const u8, offset: u32, local: bool };

const Object = struct {
    code: []const u8,
    symbols: []const ObjSymbol,
    relocs: []const Reloc,
    /// Everything above lives here.
    arena: std.heap.ArenaAllocator,

    fn deinit(o: *Object) void {
        o.arena.deinit();
    }

    fn find(o: *const Object, name: []const u8) ?u32 {
        for (o.symbols) |sym| {
            if (std.mem.eql(u8, sym.name, name)) return sym.offset;
        }
        return null;
    }
};

/// Assembles one file of a program into an object.
fn assembleObject(gpa: std.mem.Allocator, source: []const u8, err_line: ?*usize) !Object {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    var uses: std.ArrayList(SymbolUse) = .empty;
    const prog = try assembleNoting(alloc, source, 0, err_line, &uses);

    // Names given to plain numbers with .equ are not places in the code.
    var numbers: std.StringHashMapUnmanaged(void) = .empty;
    var lines = Lines.init(source);
    while (lines.next()) |text| {
        var sc: Scanner = .{ .text = text };
        const first = sc.word();
        if (std.mem.eql(u8, first, ".equ") or std.mem.eql(u8, first, ".set")) try numbers.put(alloc, sc.word(), {});
    }

    var symbols: std.ArrayList(ObjSymbol) = .empty;
    var it = prog.syms.map.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (numbers.contains(name)) continue;
        try symbols.append(alloc, .{ .name = try alloc.dupe(u8, name), .offset = entry.value_ptr.*, .local = std.mem.startsWith(u8, name, ".L") });
    }

    var relocs: std.ArrayList(Reloc) = .empty;
    for (uses.items) |use| {
        if (numbers.contains(use.name)) continue;
        const name = try alloc.dupe(u8, use.name);
        if (use.absolute) {
            try relocs.append(alloc, .{ .site = use.site, .kind = .abs32, .name = name });
        } else if (!prog.syms.map.contains(use.name)) {
            // relative, to a name from another file: only a branch can be patched
            const insn = prog.word(use.site);
            if (insn >> 25 & 0b111 != 0b101) return error.UndefinedSymbol;
            try relocs.append(alloc, .{ .site = use.site, .kind = .call24, .name = name });
        }
    }
    return .{ .code = prog.code, .symbols = symbols.items, .relocs = relocs.items, .arena = arena };
}

/// A linked program.
const Image = struct {
    code: []u8,
    base: u32,
    /// Every global symbol's final address.
    symbols: std.StringHashMapUnmanaged(u32),

    fn deinit(im: *Image, alloc: std.mem.Allocator) void {
        alloc.free(im.code);
        im.symbols.deinit(alloc);
    }
};

/// Links the objects, in order, into a program that runs at `base`.
/// After error.UndefinedSymbol or error.DuplicateSymbol, `culprit` (if
/// not null) holds the name.
fn linkObjects(alloc: std.mem.Allocator, objects: []const Object, base: u32, culprit: ?*[]const u8) !Image {
    // 1. Place. Each object starts at the next multiple of 4 after the
    //    one before it.
    const starts = try alloc.alloc(u32, objects.len);
    defer alloc.free(starts);
    var end = base;
    for (objects, starts) |o, *start| {
        start.* = alignUp(end, 4);
        end = start.* + @as(u32, @intCast(o.code.len));
    }

    // 2. The table of global symbols.
    var symbols: std.StringHashMapUnmanaged(u32) = .empty;
    errdefer symbols.deinit(alloc);
    for (objects, starts) |o, start| {
        for (o.symbols) |sym| {
            if (sym.local) continue;
            if (symbols.contains(sym.name)) {
                if (culprit) |c| c.* = sym.name;
                return error.DuplicateSymbol;
            }
            try symbols.put(alloc, sym.name, start + sym.offset);
        }
    }

    // 3. Copy the code, and patch.
    const code = try alloc.alloc(u8, end - base);
    errdefer alloc.free(code);
    @memset(code, 0);
    for (objects, starts) |o, start| {
        @memcpy(code[start - base ..][0..o.code.len], o.code);
        for (o.relocs) |reloc| {
            // The object's own symbols come first: that is how a local
            // label is found at all, and it can't be hidden by another file's.
            const target: u32 = if (o.find(reloc.name)) |offset|
                start + offset
            else
                symbols.get(reloc.name) orelse {
                    if (culprit) |c| c.* = reloc.name;
                    return error.UndefinedSymbol;
                };
            const site = start + reloc.site; // the word's own final address
            const word = code[site - base ..][0..4];
            switch (reloc.kind) {
                .abs32 => std.mem.writeInt(u32, word, target, .little),
                .call24 => {
                    // Keep the instruction's top byte (the condition and
                    // "this is a branch"). The low 24 bits become the
                    // distance in WORDS from pc, and pc reads as the
                    // instruction's address + 8.
                    const insn = std.mem.readInt(u32, word, .little);
                    const distance = target -% (site +% 8);
                    std.mem.writeInt(u32, word, (insn & 0xff000000) | (distance >> 2 & 0x00ffffff), .little);
                },
            }
        }
    }
    return .{ .code = code, .base = base, .symbols = symbols };
}

/// Runs a program that was linked to start at address 0, until a swi.
/// The caller frees the output.
fn runImage(gpa: std.mem.Allocator, code: []const u8, input: []const u8) !CRun {
    var board = try Board.init(gpa, 0x10000);
    defer board.deinit();
    board.load(0, code);
    board.uart_in = input;
    var cpu: Cpu = .{};
    const event = cpu.run(&board, 20_000_000) orelse return error.RanTooLong;
    if (event != .swi) {
        std.debug.print("the program stopped at pc = 0x{x}: {any}\n", .{ cpu.r[PC], event });
        return error.ProgramCrashed;
    }
    return .{ .result = cpu.r[0], .output = try gpa.dupe(u8, board.uart_out.items) };
}

/// The toolchain, end to end: compiles each C file and assembles each
/// assembly file on its own, and links them all, c_start first, to run
/// at `base`. The caller frees the result.
fn buildProgram(gpa: std.mem.Allocator, c_files: []const []const u8, asm_files: []const []const u8, base: u32) ![]u8 {
    return buildProgramWith(gpa, c_start, c_files, asm_files, base);
}

/// buildProgram(), with other start-up code than c_start in front.
fn buildProgramWith(gpa: std.mem.Allocator, start: []const u8, c_files: []const []const u8, asm_files: []const []const u8, base: u32) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var objects: std.ArrayList(Object) = .empty;
    try objects.append(alloc, try assembleObject(alloc, start, null));
    for (c_files, 1..) |source, n| {
        var c_line: u32 = 0;
        const text = cCompile(alloc, source, &c_line) catch |err| {
            std.debug.print("C file {d}: the compiler says {s} (if it is about syntax: line {d})\n", .{ n, @errorName(err), c_line });
            return err;
        };
        var line: usize = 0;
        try objects.append(alloc, assembleObject(alloc, text, &line) catch |err| {
            std.debug.print("C file {d}: the assembler says {s} about line {d} of the compiler's output\n", .{ n, @errorName(err), line });
            return err;
        });
    }
    for (asm_files, 1..) |source, n| {
        var line: usize = 0;
        try objects.append(alloc, assembleObject(alloc, source, &line) catch |err| {
            std.debug.print("assembly file {d}, line {d}: {s}\n", .{ n, line, @errorName(err) });
            return err;
        });
    }
    var culprit: []const u8 = "";
    const image = linkObjects(alloc, objects.items, base, &culprit) catch |err| {
        std.debug.print("the linker says {s}: {s}\n", .{ @errorName(err), culprit });
        return err;
    };
    return gpa.dupe(u8, image.code);
}
/// udiv(n, d): n / d for n >= 0 and d > 0, by long division. Work from
/// bit 30 down (bit 31 of a number that isn't negative is 0). Remember
/// that this is the function `/` is made of: it can't use `/` or `%`
/// itself.
const libc_udiv =
    \\int udiv(int n, int d) {
    \\    int q = 0;
    \\    int r = 0;
    \\    for (int i = 30; i >= 0; i--) {
    \\        r = (r << 1) | ((n >> i) & 1);
    \\        if (r >= d) {
    \\            r -= d;
    \\            q = q | (1 << i);
    \\        }
    \\    }
    \\    return q;
    \\}
    \\
;

const libc_division =
    \\/* Division, for a processor that has none. */
    \\
++ libc_udiv ++
    \\/* C rounds towards zero: -7 / 2 is -3, and the remainder has the
    \\   sign of the left side: -7 % 2 is -1. */
    \\int __divsi3(int a, int b) {
    \\    int negative = 0;
    \\    if (a < 0) { a = -a; negative = !negative; }
    \\    if (b < 0) { b = -b; negative = !negative; }
    \\    int q = udiv(a, b);
    \\    if (negative) return -q;
    \\    return q;
    \\}
    \\int __modsi3(int a, int b) {
    \\    int negative = a < 0;
    \\    if (a < 0) a = -a;
    \\    if (b < 0) b = -b;
    \\    int r = a - udiv(a, b) * b;     /* what the division left over */
    \\    if (negative) return -r;
    \\    return r;
    \\}
    \\
;

/// strcmp(a, b): 0 if the strings are the same; otherwise negative if a
/// comes first in the dictionary, positive if b does. Walk both while
/// their characters are equal, stopping at the end; the answer is the
/// difference of the two characters where the walk stopped.
const libc_strcmp =
    \\int strcmp(char *a, char *b) {
    \\    while (*a && *a == *b) {
    \\        a++;
    \\        b++;
    \\    }
    \\    return *a - *b;
    \\}
    \\
;

const libc_strings =
    \\int strlen(char *s) {
    \\    int n = 0;
    \\    while (s[n]) n++;
    \\    return n;
    \\}
    \\char *strcpy(char *to, char *from) {
    \\    char *start = to;
    \\    while (*to++ = *from++) ;
    \\    return start;
    \\}
    \\char *memcpy(char *to, char *from, int n) {
    \\    for (int i = 0; i < n; i++) to[i] = from[i];
    \\    return to;
    \\}
    \\char *memset(char *to, int value, int n) {
    \\    for (int i = 0; i < n; i++) to[i] = value;
    \\    return to;
    \\}
    \\
++ libc_strcmp;

/// print_int(n): n in decimal, through putchar, with a '-' in front if
/// it is negative. The digit that n % 10 gives is the LAST one: so first
/// print everything before it (that is n / 10, if there is anything),
/// and then this digit. '0' + 7 is the character '7'.
const libc_print_int =
    \\int print_int(int n) {
    \\    if (n < 0) {
    \\        putchar('-');
    \\        n = -n;
    \\    }
    \\    if (n >= 10) print_int(n / 10);
    \\    putchar('0' + n % 10);
    \\    return 0;
    \\}
    \\
;

const libc_io =
    \\/* The UART (222): word 0 sends, word 1 is the status, word 2 receives. */
    \\int putchar(int c) {
    \\    int *uart = (int *)0x10000000;
    \\    while ((uart[1] & 1) == 0) ;      /* wait until it can send */
    \\    uart[0] = c;
    \\    return c;
    \\}
    \\int getchar() {
    \\    int *uart = (int *)0x10000000;
    \\    while ((uart[1] & 2) == 0) ;      /* wait until a byte is there */
    \\    return uart[2];
    \\}
    \\int puts(char *s) {
    \\    while (*s) putchar(*s++);
    \\    return 0;
    \\}
    \\int print_hex(int n) {
    \\    for (int shift = 28; shift >= 0; shift -= 4) putchar("0123456789abcdef"[(n >> shift) & 15]);
    \\    return 0;
    \\}
    \\
++ libc_print_int;

/// Inside malloc: the search for a free block of at least `words` words.
/// `link` points at the word that holds the address of the next free
/// block to look at (to begin with, that word is the variable free_list
/// itself). While there is a block there:
///   - if it is big enough (its size is in block[0]): take it out of the
///     chain, by making *link skip to the block after it (block[1]), and
///     return the address of its word 1, as a char *;
///   - otherwise move on: link becomes the address of this block's own
///     "next" word.
const libc_first_fit =
    \\    while (*link) {
    \\        int *block = *link;
    \\        if (block[0] >= words) {
    \\            *link = (int *)block[1];
    \\            return (char *)(block + 1);
    \\        }
    \\        link = (int **)(block + 1);
    \\    }
    \\
;

const libc_memory =
    \\int heap[2048];         /* 8 KB to hand out */
    \\int heap_used;          /* how many of its words have been */
    \\int *free_list;         /* the blocks that came back */
    \\
    \\char *malloc(int bytes) {
    \\    int words = (bytes + 3) >> 2;
    \\    if (words < 1) words = 1;         /* a free block needs one word, for the chain */
    \\    int **link = &free_list;
    \\
++ libc_first_fit ++
    \\    /* nothing fits: cut a new block off the heap */
    \\    if (heap_used + 1 + words > 2048) return 0;
    \\    int *fresh = heap + heap_used;
    \\    heap_used += 1 + words;
    \\    fresh[0] = words;
    \\    return (char *)(fresh + 1);
    \\}
    \\int free(char *p) {
    \\    int *block = (int *)p - 1;        /* back to the size word */
    \\    block[1] = (int)free_list;        /* chain it in at the front */
    \\    free_list = block;
    \\    return 0;
    \\}
    \\
;

/// The library, as one C file.
const libc_c = libc_division ++ libc_strings ++ libc_io ++ libc_memory;

/// Compiles `program` (C), links it with the library, and runs it on the
/// emulator. The caller frees the output.
fn runC(gpa: std.mem.Allocator, program: []const u8, input: []const u8) !CRun {
    const image = try buildProgram(gpa, &.{ program, libc_c }, &.{}, 0);
    defer gpa.free(image);
    return runImage(gpa, image, input);
}
const Cond = enum(u4) { eq, ne, cs, cc, mi, pl, vs, vc, hi, ls, ge, lt, gt, le, al };
const Op = enum(u4) { @"and", eor, sub, rsb, add, adc, sbc, rsc, tst, teq, cmp, cmn, orr, mov, bic, mvn };
const Shift = enum(u2) { lsl, lsr, asr, ror };
const SP: u4 = 13;
const LR: u4 = 14;
const PC: u4 = 15;

/// The 12-bit operand for the constant `value`: rotate in bits 11..8,
/// imm8 in bits 7..0. null if no rotation works. imm8 rotated RIGHT by
/// 2 * rotate gives the value, so the value rotated LEFT by that much is
/// imm8: try each rotate from 0 up, and take the first that fits in 8 bits.
fn encodeImm(value: u32) ?u12 {
    for (0..16) |rotate| {
        const imm8 = std.math.rotl(u32, value, 2 * rotate);
        if (imm8 <= 0xff) return @intCast((rotate << 8) | imm8);
    }
    return null;
}

/// The constant that a 12-bit immediate operand stands for.
fn decodeImm(operand: u12) u32 {
    const rotate: u32 = operand >> 8;
    const imm8: u32 = operand & 0xff;
    return std.math.rotr(u32, imm8, 2 * rotate);
}

/// Operand 2 for "Rm, shifted by a constant amount".
fn shiftedReg(rm: u4, kind: Shift, amount: u5) u12 {
    return @as(u12, amount) << 7 | @as(u12, @intFromEnum(kind)) << 5 | rm;
}

/// Operand 2 for "Rm, shifted by the amount in Rs": bit 4 is set, and Rs
/// sits where the top of the amount was.
fn shiftedByReg(rm: u4, kind: Shift, rs: u4) u12 {
    return @as(u12, rs) << 8 | @as(u12, @intFromEnum(kind)) << 5 | 1 << 4 | rm;
}

/// A data-processing instruction. `imm` is the I bit.
fn dataProc(cond: Cond, op: Op, s: bool, rd: u4, rn: u4, imm: bool, operand2: u12) u32 {
    return @as(u32, @intFromEnum(cond)) << 28 |
        @as(u32, @intFromBool(imm)) << 25 |
        @as(u32, @intFromEnum(op)) << 21 |
        @as(u32, @intFromBool(s)) << 20 |
        @as(u32, rn) << 16 |
        @as(u32, rd) << 12 |
        operand2;
}

/// rd = rm * rs.
fn mulInsn(cond: Cond, s: bool, rd: u4, rm: u4, rs: u4) u32 {
    return @as(u32, @intFromEnum(cond)) << 28 | @as(u32, @intFromBool(s)) << 20 |
        @as(u32, rd) << 16 | @as(u32, rs) << 8 | 0b1001 << 4 | rm;
}

const Mem = struct {
    load: bool,
    byte: bool = false,
    rd: u4,
    rn: u4,
    /// P: true for [rn, #offset], false for [rn], #offset
    pre: bool = true,
    /// W: the ! in [rn, #offset]!
    writeback: bool = false,
};

fn memBits(cond: Cond, m: Mem, up: bool) u32 {
    return @as(u32, @intFromEnum(cond)) << 28 | 0b01 << 26 |
        @as(u32, @intFromBool(m.pre)) << 24 | @as(u32, @intFromBool(up)) << 23 |
        @as(u32, @intFromBool(m.byte)) << 22 | @as(u32, @intFromBool(m.writeback)) << 21 |
        @as(u32, @intFromBool(m.load)) << 20 | @as(u32, m.rn) << 16 | @as(u32, m.rd) << 12;
}

/// A load or store with a constant offset, from -4095 to 4095. The
/// instruction holds the offset's SIZE in 12 bits, and its sign as the U
/// bit: up for an offset of zero or more.
fn memImm(cond: Cond, m: Mem, offset: i32) u32 {
    const up = offset >= 0;
    const size: u32 = @abs(offset);
    std.debug.assert(size < 4096);
    return memBits(cond, m, up) | size;
}

/// A load or store whose offset is a (shifted) register: the I bit, and
/// the same layout as operand 2 of a data-processing instruction.
fn memReg(cond: Cond, m: Mem, up: bool, operand: u12) u32 {
    return memBits(cond, m, up) | 1 << 25 | @as(u32, operand);
}

/// A branch from the instruction at address `from` to address `to`. The
/// offset counts words, from 8 bytes past the branch, and is stored in
/// 24 bits (two's complement when it is negative).
fn branch(cond: Cond, link: bool, from: u32, to: u32) u32 {
    const bytes: i32 = @bitCast(to -% (from +% 8));
    const words: u32 = @bitCast(@divExact(bytes, 4));
    return @as(u32, @intFromEnum(cond)) << 28 | 0b101 << 25 | @as(u32, @intFromBool(link)) << 24 | (words & 0xffffff);
}

/// A system call.
fn swiInsn(cond: Cond, number: u24) u32 {
    return @as(u32, @intFromEnum(cond)) << 28 | 0b1111 << 24 | @as(u32, number);
}
const Flags = struct { n: bool = false, z: bool = false, c: bool = false, v: bool = false };

const Sum = struct { value: u32, carry: bool, overflow: bool };

/// a + b + carry_in, with the two flags only an adder can know.
fn addWithCarry(a: u32, b: u32, carry_in: bool) Sum {
    const wide = @as(u64, a) + @as(u64, b) + @intFromBool(carry_in);
    const value: u32 = @truncate(wide);
    return .{
        .value = value,
        // did the true sum need a 33rd bit?
        .carry = wide >> 32 != 0,
        // does the result's sign differ from a's AND from b's?
        .overflow = ((a ^ value) & (b ^ value)) >> 31 != 0,
    };
}

/// Does an instruction with this condition run, given the flags?
fn condPasses(cond: Cond, f: Flags) bool {
    return switch (cond) {
        .eq => f.z,
        .ne => !f.z,
        .cs => f.c,
        .cc => !f.c,
        .mi => f.n,
        .pl => !f.n,
        .vs => f.v,
        .vc => !f.v,
        .hi => f.c and !f.z,
        .ls => !f.c or f.z,
        .ge => f.n == f.v,
        .lt => f.n != f.v,
        .gt => !f.z and f.n == f.v,
        .le => f.z or f.n != f.v,
        .al => true,
    };
}

const Shifted = struct { value: u32, carry: bool };

/// The barrel shifter, for any amount from 0 to 255. The carry out is
/// the last bit that fell off the end. An amount of 0 changes nothing,
/// not even the carry.
fn barrelShift(kind: Shift, value: u32, amount: u32, carry_in: bool) Shifted {
    if (amount == 0) return .{ .value = value, .carry = carry_in };
    const sign = value >> 31 != 0;
    switch (kind) {
        .lsl => {
            if (amount > 32) return .{ .value = 0, .carry = false };
            // the last bit out is bit (32 - amount)
            const carry = (value >> @intCast(32 - amount)) & 1 != 0;
            return .{ .value = if (amount == 32) 0 else value << @intCast(amount), .carry = carry };
        },
        .lsr => {
            if (amount > 32) return .{ .value = 0, .carry = false };
            // the last bit out is bit (amount - 1)
            const carry = (value >> @intCast(amount - 1)) & 1 != 0;
            return .{ .value = if (amount == 32) 0 else value >> @intCast(amount), .carry = carry };
        },
        .asr => {
            // an ARITHMETIC shift right copies the sign bit in from the left,
            // so that -8 asr 1 is -4. Past 31 places, only sign bits are left.
            if (amount >= 32) return .{ .value = if (sign) 0xffffffff else 0, .carry = sign };
            const signed: i32 = @bitCast(value);
            return .{ .value = @bitCast(signed >> @intCast(amount)), .carry = (value >> @intCast(amount - 1)) & 1 != 0 };
        },
        .ror => {
            // a ROTATE puts the bits that fall off back in at the top
            const out = std.math.rotr(u32, value, amount % 32);
            return .{ .value = out, .carry = out >> 31 != 0 };
        },
    }
}

/// How the 5-bit shift amount of an instruction is meant (215's
/// shiftAmount(), backwards): for lsr and asr, 0 means 32. And `ror #0`
/// is a different shift altogether, "rotate right extended": one place,
/// through the carry flag, which makes a 33-bit rotation.
fn shiftByImmediate(kind: Shift, value: u32, amount: u5, carry_in: bool) Shifted {
    return switch (kind) {
        .lsl => barrelShift(.lsl, value, amount, carry_in),
        .lsr, .asr => barrelShift(kind, value, if (amount == 0) 32 else amount, carry_in),
        .ror => if (amount == 0)
            .{ .value = @as(u32, @intFromBool(carry_in)) << 31 | value >> 1, .carry = value & 1 != 0 }
        else
            barrelShift(.ror, value, amount, carry_in),
    };
}

const AluResult = struct {
    value: u32,
    /// The flags, if the instruction has its S bit.
    flags: Flags,
    /// false for tst, teq, cmp, cmn: they only set flags.
    writes: bool,
};

/// One data-processing operation: a <op> b. `flags` are the flags before,
/// and `shifter_carry` is the carry out of the barrel shifter that made b.
fn alu(op: Op, a: u32, b: u32, flags: Flags, shifter_carry: bool) AluResult {
    const sum: ?Sum = switch (op) {
        .add, .cmn => addWithCarry(a, b, false),
        .adc => addWithCarry(a, b, flags.c),
        .sub, .cmp => addWithCarry(a, ~b, true),
        .sbc => addWithCarry(a, ~b, flags.c),
        .rsb => addWithCarry(b, ~a, true), // "reverse subtract": b - a
        .rsc => addWithCarry(b, ~a, flags.c),
        else => null,
    };
    const writes = switch (op) {
        .tst, .teq, .cmp, .cmn => false,
        else => true,
    };
    if (sum) |s| {
        return .{ .value = s.value, .writes = writes, .flags = .{ .n = s.value >> 31 != 0, .z = s.value == 0, .c = s.carry, .v = s.overflow } };
    }
    const value = switch (op) {
        .@"and", .tst => a & b,
        .eor, .teq => a ^ b,
        .orr => a | b,
        .mov => b,
        .bic => a & ~b, // "bit clear"
        .mvn => ~b,
        else => unreachable,
    };
    // A logical operation: N and Z from the result, C from the shifter, V untouched.
    return .{ .value = value, .writes = writes, .flags = .{ .n = value >> 31 != 0, .z = value == 0, .c = shifter_carry, .v = flags.v } };
}
/// The addresses of labels. Filled in by the caller (216 does it from the
/// labels in a file).
/// Where a name was used: the address of the word that used it, and
/// whether that word IS the name's address (a `.word`, or a constant in
/// the literal pool) or an instruction that reaches it relative to pc.
const SymbolUse = struct { name: []const u8, site: u32, absolute: bool };

const Symbols = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,
    /// After error.UndefinedSymbol: the name that wasn't found.
    missing: []const u8 = "",
    /// Only the assembler of an *object file* sets this (229). Then every
    /// lookup is written down, with `site` and `absolute`, which say
    /// what is being assembled; and a name nobody has defined is no
    /// error. It reads as 0, for the linker to fill in later.
    uses: ?*std.ArrayList(SymbolUse) = null,
    uses_alloc: std.mem.Allocator = undefined,
    site: u32 = 0,
    absolute: bool = false,

    fn get(sy: *Symbols, name: []const u8) !u32 {
        if (sy.uses) |uses| {
            try uses.append(sy.uses_alloc, .{ .name = name, .site = sy.site, .absolute = sy.absolute });
            return sy.map.get(name) orelse 0;
        }
        return sy.map.get(name) orelse {
            sy.missing = name;
            return error.UndefinedSymbol;
        };
    }
};

fn parseReg(name: []const u8) ?u4 {
    const named = [_]struct { []const u8, u4 }{ .{ "sp", 13 }, .{ "lr", 14 }, .{ "pc", 15 }, .{ "fp", 11 }, .{ "ip", 12 } };
    for (named) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    if (name.len < 2 or name[0] != 'r') return null;
    return std.fmt.parseInt(u4, name[1..], 10) catch null;
}

/// Reads operands, left to right.
const Scanner = struct {
    text: []const u8,
    at: usize = 0,

    /// The next character that isn't a space (0 at the end), not consumed.
    fn peek(sc: *Scanner) u8 {
        while (sc.at < sc.text.len and (sc.text[sc.at] == ' ' or sc.text[sc.at] == '\t')) sc.at += 1;
        return if (sc.at < sc.text.len) sc.text[sc.at] else 0;
    }

    /// Consumes `c` if it is next.
    fn eat(sc: *Scanner, c: u8) bool {
        if (sc.peek() != c) return false;
        sc.at += 1;
        return true;
    }

    fn need(sc: *Scanner, c: u8) !void {
        if (!sc.eat(c)) return error.BadOperand;
    }

    fn done(sc: *Scanner) bool {
        return sc.peek() == 0;
    }

    /// A run of letters, digits, '_', '.' and '$': a name or a number.
    fn word(sc: *Scanner) []const u8 {
        _ = sc.peek();
        const start = sc.at;
        while (sc.at < sc.text.len) : (sc.at += 1) {
            const c = sc.text[sc.at];
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '$') break;
        }
        return sc.text[start..sc.at];
    }

    fn reg(sc: *Scanner) !u4 {
        return parseReg(sc.word()) orelse error.BadRegister;
    }

    /// 12, -12, 0x1f, or a character like 'a'. Returned as 32 bits.
    fn number(sc: *Scanner) !u32 {
        if (sc.eat('\'')) {
            if (sc.at + 1 >= sc.text.len or sc.text[sc.at + 1] != '\'') return error.BadNumber;
            sc.at += 2;
            return sc.text[sc.at - 2];
        }
        const negative = sc.eat('-');
        const v = std.fmt.parseInt(u32, sc.word(), 0) catch return error.BadNumber;
        return if (negative) 0 -% v else v;
    }

    /// A number, or a symbol's address.
    fn value(sc: *Scanner, syms: *Symbols) !u32 {
        const c = sc.peek();
        if (std.ascii.isDigit(c) or c == '-' or c == '\'') return sc.number();
        const name = sc.word();
        if (name.len == 0) return error.BadOperand;
        return syms.get(name);
    }
};

const Kind = union(enum) {
    data: Op,
    mul,
    mem: struct { load: bool, byte: bool },
    branch: struct { link: bool },
    swi,
};

const Mnemonic = struct { kind: Kind, s: bool = false, cond: Cond = .al };

const bases = [_]struct { []const u8, Kind }{
    .{ "and", .{ .data = .@"and" } },
    .{ "eor", .{ .data = .eor } },
    .{ "sub", .{ .data = .sub } },
    .{ "rsb", .{ .data = .rsb } },
    .{ "add", .{ .data = .add } },
    .{ "adc", .{ .data = .adc } },
    .{ "sbc", .{ .data = .sbc } },
    .{ "rsc", .{ .data = .rsc } },
    .{ "tst", .{ .data = .tst } },
    .{ "teq", .{ .data = .teq } },
    .{ "cmp", .{ .data = .cmp } },
    .{ "cmn", .{ .data = .cmn } },
    .{ "orr", .{ .data = .orr } },
    .{ "mov", .{ .data = .mov } },
    .{ "bic", .{ .data = .bic } },
    .{ "mvn", .{ .data = .mvn } },
    .{ "mul", .mul },
    .{ "ldrb", .{ .mem = .{ .load = true, .byte = true } } },
    .{ "strb", .{ .mem = .{ .load = false, .byte = true } } },
    .{ "ldr", .{ .mem = .{ .load = true, .byte = false } } },
    .{ "str", .{ .mem = .{ .load = false, .byte = false } } },
    .{ "bl", .{ .branch = .{ .link = true } } },
    .{ "b", .{ .branch = .{ .link = false } } },
    .{ "swi", .swi },
    .{ "svc", .swi }, // the modern name
};

fn parseCond(text: []const u8) ?Cond {
    if (std.mem.eql(u8, text, "hs")) return .cs; // "higher or same": another name for carry set
    if (std.mem.eql(u8, text, "lo")) return .cc;
    return std.meta.stringToEnum(Cond, text);
}

/// base name, then an optional "s", then an optional condition.
fn parseMnemonic(text: []const u8) ?Mnemonic {
    for (bases) |base| {
        if (!std.mem.startsWith(u8, text, base[0])) continue;
        var m: Mnemonic = .{ .kind = base[1] };
        var rest = text[base[0].len..];
        // Only data-processing instructions and mul can set the flags.
        const may_set_flags = m.kind == .data or m.kind == .mul;
        if (may_set_flags and rest.len > 0 and rest[0] == 's') {
            m.s = true;
            rest = rest[1..];
        }
        if (rest.len > 0) {
            // Whatever is left must be a condition. If it isn't, this
            // base name was the wrong guess: try the next one.
            m.cond = parseCond(rest) orelse continue;
        }
        return m;
    }
    return null;
}

/// How a constant shift amount is stored in 5 bits. lsl goes from 0 to 31.
/// The others go from 1 to 32 (a shift right by 0 would do nothing, so the
/// encoding 0 is reused to mean 32); ror stops at 31.
fn shiftAmount(kind: Shift, n: u32) !u5 {
    const max: u32 = switch (kind) {
        .lsl, .ror => 31,
        .lsr, .asr => 32,
    };
    if (n > max or (n == 0 and kind != .lsl)) return error.BadShift;
    return @truncate(n);
}

const Operand2 = struct { imm: bool, bits: u12 };

/// After the register rm: nothing, or ", lsl #n", or ", lsl rs".
fn parseShift(sc: *Scanner, rm: u4) !u12 {
    if (!sc.eat(',')) return shiftedReg(rm, .lsl, 0); // a plain register is "shifted left by 0"
    const kind = std.meta.stringToEnum(Shift, sc.word()) orelse return error.BadShift;
    if (sc.eat('#')) return shiftedReg(rm, kind, try shiftAmount(kind, try sc.number()));
    return shiftedByReg(rm, kind, try sc.reg());
}

fn parseOperand2(sc: *Scanner) !Operand2 {
    if (sc.eat('#')) {
        const v = try sc.number();
        return .{ .imm = true, .bits = encodeImm(v) orelse return error.ImmediateDoesNotFit };
    }
    return .{ .imm = false, .bits = try parseShift(sc, try sc.reg()) };
}

fn encodeData(sc: *Scanner, m: Mnemonic, op: Op) !u32 {
    switch (op) {
        .mov, .mvn => {
            const rd = try sc.reg();
            try sc.need(',');
            const op2 = try parseOperand2(sc);
            return dataProc(m.cond, op, m.s, rd, 0, op2.imm, op2.bits);
        },
        .tst, .teq, .cmp, .cmn => {
            const rn = try sc.reg();
            try sc.need(',');
            const op2 = try parseOperand2(sc);
            return dataProc(m.cond, op, true, 0, rn, op2.imm, op2.bits);
        },
        else => {
            const rd = try sc.reg();
            try sc.need(',');
            const rn = try sc.reg();
            try sc.need(',');
            const op2 = try parseOperand2(sc);
            return dataProc(m.cond, op, m.s, rd, rn, op2.imm, op2.bits);
        },
    }
}

/// The offset part of an address: #n, or rm, -rm, rm with a shift.
const Offset = union(enum) {
    imm: i32,
    reg: struct { up: bool, bits: u12 },
};

fn parseOffset(sc: *Scanner) !Offset {
    if (sc.eat('#')) return .{ .imm = @bitCast(try sc.number()) };
    const up = !sc.eat('-');
    return .{ .reg = .{ .up = up, .bits = try parseShift(sc, try sc.reg()) } };
}

fn encodeOffset(cond: Cond, m: Mem, offset: Offset) !u32 {
    switch (offset) {
        .imm => |n| {
            if (n < -4095 or n > 4095) return error.OffsetTooFar;
            return memImm(cond, m, n);
        },
        .reg => |r| return memReg(cond, m, r.up, r.bits),
    }
}

fn encodeMem(sc: *Scanner, cond: Cond, load: bool, byte: bool, addr: u32, syms: *Symbols) !u32 {
    var m: Mem = .{ .load = load, .byte = byte, .rd = try sc.reg(), .rn = 0 };
    try sc.need(',');
    if (!sc.eat('[')) {
        // A label: the word stored there. Its address is written as a
        // distance from pc, which reads as this instruction's address + 8.
        const target = try sc.value(syms);
        m.rn = PC;
        return encodeOffset(cond, m, .{ .imm = @bitCast(target -% (addr +% 8)) });
    }
    m.rn = try sc.reg();
    if (sc.eat(']')) {
        if (!sc.eat(',')) return memImm(cond, m, 0); // [rn]
        // [rn], offset: use rn as it is, then add the offset to it
        m.pre = false;
        return encodeOffset(cond, m, try parseOffset(sc));
    }
    // [rn, offset] or [rn, offset]!
    try sc.need(',');
    const offset = try parseOffset(sc);
    try sc.need(']');
    m.writeback = sc.eat('!');
    return encodeOffset(cond, m, offset);
}

/// Assembles one instruction, which will live at address `addr`.
fn encodeLine(line: []const u8, addr: u32, syms: *Symbols) !u32 {
    var sc: Scanner = .{ .text = line };
    const m = parseMnemonic(sc.word()) orelse return error.UnknownMnemonic;
    const encoded = switch (m.kind) {
        .data => |op| try encodeData(&sc, m, op),
        .mul => blk: {
            const rd = try sc.reg();
            try sc.need(',');
            const rm = try sc.reg();
            try sc.need(',');
            break :blk mulInsn(m.cond, m.s, rd, rm, try sc.reg());
        },
        .mem => |k| try encodeMem(&sc, m.cond, k.load, k.byte, addr, syms),
        .branch => |k| branch(m.cond, k.link, addr, try sc.value(syms)),
        .swi => blk: {
            _ = sc.eat('#');
            const n = try sc.number();
            if (n > 0xffffff) return error.BadNumber;
            break :blk swiInsn(m.cond, @intCast(n));
        },
    };
    if (!sc.done()) return error.BadOperand;
    return encoded;
}
/// The line without its comment: from `@` or `//` to the end, unless it
/// is inside quotes.
fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (c == '\\') i += 1 else if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '@' or (c == '/' and i + 1 < line.len and line[i + 1] == '/')) {
            return line[0..i];
        }
    }
    return line;
}

const Labelled = struct { name: []const u8, rest: []const u8 };

/// If the text starts with "name:", the name and what follows it.
fn takeLabel(text: []const u8) ?Labelled {
    var sc: Scanner = .{ .text = text };
    const name = sc.word();
    if (name.len == 0 or sc.at >= text.len or text[sc.at] != ':') return null;
    return .{ .name = name, .rest = std.mem.trim(u8, text[sc.at + 1 ..], " \t") };
}

/// The lines of a file, without comments or surrounding spaces.
const Lines = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    number: usize = 0,

    fn init(source: []const u8) Lines {
        return .{ .it = std.mem.splitScalar(u8, source, '\n') };
    }

    fn next(l: *Lines) ?[]const u8 {
        const line = l.it.next() orelse return null;
        l.number += 1;
        return std.mem.trim(u8, stripComment(line), " \t\r");
    }
};

const Directive = enum { word, byte, ascii, asciz, p2align, balign, space, equ, ltorg, ignored };

fn parseDirective(name: []const u8) ?Directive {
    const table = [_]struct { []const u8, Directive }{
        .{ ".word", .word },
        .{ ".long", .word },
        .{ ".byte", .byte },
        .{ ".ascii", .ascii },
        .{ ".asciz", .asciz },
        .{ ".string", .asciz },
        .{ ".align", .p2align },
        .{ ".balign", .balign },
        .{ ".space", .space },
        .{ ".skip", .space },
        .{ ".equ", .equ },
        .{ ".set", .equ },
        .{ ".ltorg", .ltorg },
        .{ ".pool", .ltorg },
        .{ ".global", .ignored },
        .{ ".globl", .ignored },
        .{ ".text", .ignored },
        .{ ".data", .ignored },
        .{ ".section", .ignored },
        .{ ".type", .ignored },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// `addr`, moved up to the next multiple of `to` (a power of two).
fn alignUp(addr: u32, to: u32) u32 {
    return (addr + to - 1) & ~(to - 1);
}

/// How many comma-separated things follow.
fn countItems(sc: *Scanner) u32 {
    return @intCast(std.mem.count(u8, sc.text[sc.at..], ",") + 1);
}

/// The bytes of a quoted string, with \n, \t, \r, \0, \\ and \" decoded.
fn parseString(alloc: std.mem.Allocator, sc: *Scanner) ![]u8 {
    try sc.need('"');
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    while (sc.at < sc.text.len and sc.text[sc.at] != '"') : (sc.at += 1) {
        var c = sc.text[sc.at];
        if (c == '\\') {
            sc.at += 1;
            if (sc.at >= sc.text.len) return error.BadString;
            c = switch (sc.text[sc.at]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '0' => 0,
                '\\', '"' => sc.text[sc.at],
                else => return error.BadString,
            };
        }
        try out.append(alloc, c);
    }
    if (sc.at >= sc.text.len) return error.BadString;
    sc.at += 1;
    return out.toOwnedSlice(alloc);
}

const Literal = struct { head: []const u8, expr: []const u8 };

/// If the statement is a wish, "ldr r0, =something": the part before the
/// `=` and the something.
fn takeLiteral(text: []const u8) ?Literal {
    const comma = std.mem.indexOfScalar(u8, text, ',') orelse return null;
    const after = std.mem.trimStart(u8, text[comma + 1 ..], " \t");
    if (after.len == 0 or after[0] != '=') return null;
    return .{ .head = text[0 .. comma + 1], .expr = after[1..] };
}

/// What pass 1 learns.
const Layout = struct {
    syms: Symbols = .{},
    /// The address of each literal-pool word, in the order the wishes
    /// appear in the file.
    literals: std.ArrayList(u32) = .empty,
    end: u32 = 0,

    fn deinit(lay: *Layout, alloc: std.mem.Allocator) void {
        lay.syms.map.deinit(alloc);
        lay.literals.deinit(alloc);
    }
};

/// Pass 1: where is everything? `line` follows along, for error messages.
fn layout(alloc: std.mem.Allocator, source: []const u8, base: u32, line: *usize) !Layout {
    var lay: Layout = .{};
    errdefer lay.deinit(alloc);
    var addr = base;
    var waiting: u32 = 0; // wishes since the last pool
    var lines = Lines.init(source);
    while (lines.next()) |full| {
        line.* = lines.number;
        var text = full;
        while (takeLabel(text)) |l| {
            if (lay.syms.map.contains(l.name)) return error.DuplicateLabel;
            try lay.syms.map.put(alloc, l.name, addr);
            text = l.rest;
        }
        if (text.len == 0) continue;
        var sc: Scanner = .{ .text = text };
        const first = sc.word();
        if (first.len == 0 or first[0] != '.') {
            // an instruction
            if (takeLiteral(text) != null) waiting += 1;
            addr += 4;
            continue;
        }
        switch (parseDirective(first) orelse return error.UnknownDirective) {
            .word => addr += 4 * countItems(&sc),
            .byte => addr += countItems(&sc),
            .ascii, .asciz => |d| {
                const bytes = try parseString(alloc, &sc);
                defer alloc.free(bytes);
                addr += @intCast(bytes.len + @intFromBool(d == .asciz));
            },
            .p2align => addr = alignUp(addr, @as(u32, 1) << @intCast(if (sc.done()) 2 else try sc.number())),
            .balign => addr = alignUp(addr, try sc.number()),
            .space => addr += try sc.number(),
            .equ => {
                const name = sc.word();
                try sc.need(',');
                try lay.syms.map.put(alloc, name, try sc.number());
            },
            .ltorg => {
                addr = try placePool(alloc, &lay, addr, waiting);
                waiting = 0;
            },
            .ignored => {},
        }
    }
    lay.end = try placePool(alloc, &lay, addr, waiting);
    return lay;
}

/// Gives each of the `waiting` wishes a word, starting at the next
/// multiple of 4 from addr. Returns the address after the pool.
fn placePool(alloc: std.mem.Allocator, lay: *Layout, addr: u32, waiting: u32) !u32 {
    if (waiting == 0) return addr;
    var at = alignUp(addr, 4);
    for (0..waiting) |_| {
        try lay.literals.append(alloc, at);
        at += 4;
    }
    return at;
}

/// An assembled program: its bytes, and where its labels ended up.
const Program = struct {
    code: []u8,
    base: u32,
    syms: Symbols,

    fn deinit(p: *Program, alloc: std.mem.Allocator) void {
        alloc.free(p.code);
        p.syms.map.deinit(alloc);
    }

    fn word(p: *const Program, addr: u32) u32 {
        return std.mem.readInt(u32, p.code[addr - p.base ..][0..4], .little);
    }
};

fn appendWord(alloc: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    // ARM here is little-endian: the least significant byte comes first.
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(alloc, &bytes);
}

fn padTo(alloc: std.mem.Allocator, out: *std.ArrayList(u8), size: usize) !void {
    while (out.items.len < size) try out.append(alloc, 0);
}

/// Assembles `source` to run at address `base`. If it fails and
/// `err_line` isn't null, the line number of the mistake is put there.
fn assemble(alloc: std.mem.Allocator, source: []const u8, base: u32, err_line: ?*usize) !Program {
    return assembleNoting(alloc, source, base, err_line, null);
}

/// assemble(), for a file that is only part of a program (229): with a
/// list in `uses`, every use of a name is added to it, and names that
/// aren't defined in this file are let through.
fn assembleNoting(alloc: std.mem.Allocator, source: []const u8, base: u32, err_line: ?*usize, uses: ?*std.ArrayList(SymbolUse)) !Program {
    var line: usize = 0;
    defer if (err_line) |e| {
        e.* = line;
    };
    var lay = try layout(alloc, source, base, &line);
    defer lay.literals.deinit(alloc);
    errdefer lay.syms.map.deinit(alloc);
    lay.syms.uses = uses;
    lay.syms.uses_alloc = alloc;

    // Pass 2: the bytes. The address of the next byte is base + out.items.len.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var wishes: std.ArrayList([]const u8) = .empty; // what each pool word should hold
    defer wishes.deinit(alloc);
    var granted: usize = 0; // pool words written so far
    var lines = Lines.init(source);
    while (lines.next()) |full| {
        line = lines.number;
        var text = full;
        while (takeLabel(text)) |l| text = l.rest;
        if (text.len == 0) continue;
        var sc: Scanner = .{ .text = text };
        const first = sc.word();
        const addr: u32 = base + @as(u32, @intCast(out.items.len));
        lay.syms.site = addr;
        lay.syms.absolute = false;
        if (first.len == 0 or first[0] != '.') {
            if (takeLiteral(text)) |lit| {
                // "ldr r0, =x" becomes "ldr r0, <address of its pool word>",
                // which 215 encodes as a pc-relative load.
                const pool_word = lay.literals.items[wishes.items.len];
                try wishes.append(alloc, lit.expr);
                var buf: [128]u8 = undefined;
                const rewritten = std.fmt.bufPrint(&buf, "{s} {d}", .{ lit.head, pool_word }) catch return error.LineTooLong;
                try appendWord(alloc, &out, try encodeLine(rewritten, addr, &lay.syms));
            } else {
                try appendWord(alloc, &out, try encodeLine(text, addr, &lay.syms));
            }
            continue;
        }
        switch (parseDirective(first).?) {
            .word => while (true) {
                lay.syms.site = base + @as(u32, @intCast(out.items.len));
                lay.syms.absolute = true;
                try appendWord(alloc, &out, try sc.value(&lay.syms));
                if (!sc.eat(',')) break;
            },
            .byte => while (true) {
                try out.append(alloc, @truncate(try sc.number()));
                if (!sc.eat(',')) break;
            },
            .ascii, .asciz => |d| {
                const bytes = try parseString(alloc, &sc);
                defer alloc.free(bytes);
                try out.appendSlice(alloc, bytes);
                if (d == .asciz) try out.append(alloc, 0);
            },
            .p2align => try padTo(alloc, &out, alignUp(addr, @as(u32, 1) << @intCast(if (sc.done()) 2 else try sc.number())) - base),
            .balign => try padTo(alloc, &out, alignUp(addr, try sc.number()) - base),
            .space => try padTo(alloc, &out, out.items.len + try sc.number()),
            .ltorg => granted = try writePool(alloc, &out, base, &lay, wishes.items, granted),
            .equ, .ignored => continue,
        }
        if (!sc.done()) return error.BadOperand;
    }
    _ = try writePool(alloc, &out, base, &lay, wishes.items, granted);
    std.debug.assert(base + out.items.len == lay.end); // the two passes must agree
    return .{ .code = try out.toOwnedSlice(alloc), .base = base, .syms = lay.syms };
}

/// Writes the pool words for the wishes not granted yet. Returns how
/// many have been granted now.
fn writePool(alloc: std.mem.Allocator, out: *std.ArrayList(u8), base: u32, lay: *Layout, wishes: []const []const u8, granted: usize) !usize {
    for (wishes[granted..], granted..) |expr, k| {
        try padTo(alloc, out, lay.literals.items[k] - base);
        var sc: Scanner = .{ .text = expr };
        lay.syms.site = lay.literals.items[k];
        lay.syms.absolute = true;
        try appendWord(alloc, out, try sc.value(&lay.syms));
        if (!sc.done()) return error.BadOperand;
    }
    return wishes.len;
}
const Access = enum { read, write, execute };
const Fault = struct { addr: u32, access: Access };

/// What happened in one step, when it wasn't just "an instruction ran".
const Event = union(enum) {
    ok,
    /// A `swi` instruction: a request to whoever is in charge.
    swi: u24,
    /// A word that is no instruction we know. Its address is still in pc.
    undefined: u32,
    /// Memory said no. pc still points at the instruction.
    fault: Fault,
};

fn bit(insn: u32, comptime n: u5) bool {
    return (insn >> n) & 1 != 0;
}

fn field(insn: u32, comptime low: u5) u4 {
    return @truncate(insn >> low);
}

const Cpu = struct {
    /// r[15] is the address of the instruction about to run.
    r: [16]u32 = @splat(0),
    flags: Flags = .{},

    /// A register's value as an instruction at address `pc` sees it.
    fn get(cpu: *const Cpu, n: u4, pc: u32) u32 {
        return if (n == PC) pc +% 8 else cpu.r[n];
    }

    /// Runs one instruction. `mem` is anything with
    ///     read(addr: u32, size: u3) !u32    and
    ///     write(addr: u32, size: u3, value: u32) !void
    /// where size is 1 (a byte) or 4 (a word).
    fn step(cpu: *Cpu, mem: anytype) Event {
        const pc = cpu.r[PC];
        const insn = mem.read(pc, 4) catch return .{ .fault = .{ .addr = pc, .access = .execute } };
        const cond = std.enums.fromInt(Cond, insn >> 28) orelse return .{ .undefined = insn };
        cpu.r[PC] = pc +% 4; // unless the instruction says otherwise
        if (!condPasses(cond, cpu.flags)) return .ok;

        const event: Event = if (field(insn, 24) == 0b1111)
            .{ .swi = @truncate(insn) }
        else if (insn >> 25 & 0b111 == 0b101)
            cpu.branchInsn(insn, pc)
        else if (insn & 0x0fc000f0 == 0x00000090)
            cpu.multiply(insn, pc)
        else switch (insn >> 26 & 0b11) {
            0b00 => cpu.dataProcessing(insn, pc),
            0b01 => cpu.loadStore(insn, pc, mem),
            else => .{ .undefined = insn },
        };
        if (event == .undefined or event == .fault) cpu.r[PC] = pc;
        return event;
    }

    fn branchInsn(cpu: *Cpu, insn: u32, pc: u32) Event {
        // bits 23..0 are a signed number of WORDS, counted from pc + 8
        const words: i24 = @bitCast(@as(u24, @truncate(insn)));
        const bytes: i32 = @as(i32, words) * 4;
        if (bit(insn, 24)) cpu.r[LR] = pc +% 4; // bl: where to come back to
        cpu.r[PC] = pc +% 8 +% @as(u32, @bitCast(bytes));
        return .ok;
    }

    fn multiply(cpu: *Cpu, insn: u32, pc: u32) Event {
        if (bit(insn, 21)) return .{ .undefined = insn }; // multiply-accumulate: not built
        const product = cpu.get(field(insn, 0), pc) *% cpu.get(field(insn, 8), pc);
        cpu.r[field(insn, 16)] = product;
        if (bit(insn, 20)) {
            cpu.flags.n = product >> 31 != 0;
            cpu.flags.z = product == 0;
        }
        return .ok;
    }

    fn dataProcessing(cpu: *Cpu, insn: u32, pc: u32) Event {
        const op: Op = @enumFromInt(field(insn, 21));
        const s = bit(insn, 20);
        var b: Shifted = undefined;
        if (bit(insn, 25)) {
            // a constant: 8 bits, anywhere. Its carry is its top bit, if it was rotated at all.
            const value = decodeImm(@truncate(insn));
            b = .{ .value = value, .carry = if (field(insn, 8) == 0) cpu.flags.c else value >> 31 != 0 };
        } else {
            const rm = cpu.get(field(insn, 0), pc);
            const kind: Shift = @enumFromInt(insn >> 5 & 0b11);
            if (bit(insn, 4)) {
                // shifted by the low byte of register Rs
                if (bit(insn, 7)) return .{ .undefined = insn };
                b = barrelShift(kind, rm, cpu.get(field(insn, 8), pc) & 0xff, cpu.flags.c);
            } else {
                b = shiftByImmediate(kind, rm, @truncate(insn >> 7), cpu.flags.c);
            }
        }
        const result = alu(op, cpu.get(field(insn, 16), pc), b.value, cpu.flags, b.carry);
        // cmp and friends exist only to set flags; without S they are other instructions
        if (!result.writes and !s) return .{ .undefined = insn };
        if (s) cpu.flags = result.flags;
        if (result.writes) cpu.r[field(insn, 12)] = result.value; // into r15, this is a jump
        return .ok;
    }

    fn loadStore(cpu: *Cpu, insn: u32, pc: u32, mem: anytype) Event {
        const pre = bit(insn, 24); // P
        const up = bit(insn, 23); // U
        const size: u3 = if (bit(insn, 22)) 1 else 4; // B
        const writeback = bit(insn, 21); // W
        const load = bit(insn, 20); // L
        const rn = field(insn, 16);
        const rd = field(insn, 12);

        var offset: u32 = insn & 0xfff;
        if (bit(insn, 25)) {
            // a register offset, shifted by a constant
            if (bit(insn, 4)) return .{ .undefined = insn };
            offset = shiftByImmediate(@enumFromInt(insn >> 5 & 0b11), cpu.get(field(insn, 0), pc), @truncate(insn >> 7), cpu.flags.c).value;
        }
        const base = cpu.get(rn, pc);
        const moved = if (up) base +% offset else base -% offset;
        // [rn, #n] uses the moved address. [rn], #n uses rn as it was.
        const addr = if (pre) moved else base;
        // rn itself changes for [rn], #n and for [rn, #n]!
        const updates_rn = !pre or writeback;

        if (load) {
            const value = mem.read(addr, size) catch return .{ .fault = .{ .addr = addr, .access = .read } };
            if (updates_rn) cpu.r[rn] = moved;
            cpu.r[rd] = value;
        } else {
            mem.write(addr, size, cpu.get(rd, pc)) catch return .{ .fault = .{ .addr = addr, .access = .write } };
            if (updates_rn) cpu.r[rn] = moved;
        }
        return .ok;
    }

    /// Steps until something other than .ok happens. null: `limit`
    /// instructions went by and nothing did.
    fn run(cpu: *Cpu, mem: anytype, limit: usize) ?Event {
        for (0..limit) |_| {
            const event = cpu.step(mem);
            if (event != .ok) return event;
        }
        return null;
    }
};

const uart_base: u32 = 0x10000000;

/// The whole computer, so far: RAM from address 0, and a UART.
const Board = struct {
    ram: []u8,
    alloc: std.mem.Allocator,
    /// Every byte the program has sent.
    uart_out: std.ArrayList(u8) = .empty,
    /// Bytes on their way to the program.
    uart_in: []const u8 = "",

    fn init(alloc: std.mem.Allocator, ram_size: usize) !Board {
        const ram = try alloc.alloc(u8, ram_size);
        @memset(ram, 0);
        return .{ .ram = ram, .alloc = alloc };
    }

    fn deinit(b: *Board) void {
        b.alloc.free(b.ram);
        b.uart_out.deinit(b.alloc);
    }

    /// Copies a program into RAM.
    fn load(b: *Board, addr: u32, bytes: []const u8) void {
        @memcpy(b.ram[addr..][0..bytes.len], bytes);
    }

    fn read(b: *Board, addr: u32, size: u3) !u32 {
        if (addr >= uart_base) {
            switch (addr - uart_base) {
                // status: always ready to send (bit 0); bit 1 when input is waiting
                4 => return 1 | @as(u32, @intFromBool(b.uart_in.len > 0)) << 1,
                8 => {
                    if (b.uart_in.len == 0) return 0;
                    const byte = b.uart_in[0];
                    b.uart_in = b.uart_in[1..]; // reading the register takes the byte
                    return byte;
                },
                else => return error.NoDevice,
            }
        }
        if (size == 1) {
            if (addr >= b.ram.len) return error.NoDevice;
            return b.ram[addr];
        }
        // a word must sit at a multiple of 4
        if (addr % 4 != 0 or @as(usize, addr) + 4 > b.ram.len) return error.NoDevice;
        return std.mem.readInt(u32, b.ram[addr..][0..4], .little);
    }

    fn write(b: *Board, addr: u32, size: u3, value: u32) !void {
        if (addr == uart_base) return b.uart_out.append(b.alloc, @truncate(value));
        if (size == 1) {
            if (addr >= b.ram.len) return error.NoDevice;
            b.ram[addr] = @truncate(value);
            return;
        }
        if (addr % 4 != 0 or @as(usize, addr) + 4 > b.ram.len) return error.NoDevice;
        std.mem.writeInt(u32, b.ram[addr..][0..4], value, .little);
    }
};
