//
// ─── Exercise 233: two modes, and the door between them ───────────────
//
// Chapter 46: an operating system. Until now, whatever program ran owned
// the machine: every address, the UART, the lot. An operating system is
// a program that owns the machine *instead*, and lets other programs
// borrow it, without having to trust them. Software alone can't do that
// (a program that can do anything can undo any protection). It needs
// three small favours from the hardware, and this exercise builds them
// into the emulator:
//
// 1. A MODE BIT. The processor is either in *kernel mode*, where
//    everything is allowed, or in *user mode*, where some things fault.
//    Here those things are the system registers below.
//
// 2. A TRAP. The only way from user mode into kernel mode: the processor
//    itself switches mode AND jumps to an address the kernel chose
//    beforehand, in one step, so user code can never run with kernel
//    rights. What is saved, and all that is saved, is what the processor
//    is about to overwrite:
//
//        saved_pc    <- pc         where to continue afterwards
//        saved_mode  <- mode
//        saved_flags <- N, Z, C, V   or a timer trap between a cmp and
//                                  its branch would change the outcome
//        sp         <-> other_sp   the kernel gets its own stack: the
//                                  user's sp may point anywhere
//        cause       <- why
//        mode        <- kernel
//        pc          <- vector
//
//    Three things cause a trap. A `swi` instruction: the program asks
//    for something, a *system call*. A fault or an unknown instruction:
//    the program did something impossible. And the timer: nothing
//    happened at all, but the program's time is up.
//
// 3. A WAY BACK that undoes exactly that: mode <- saved_mode, the flags
//    return, the stack pointers swap again, pc <- saved_pc.
//
// The kernel talks to all this through *system registers*, which this
// machine keeps at 0x20000000, like one more device:
//
//     +0x00 vector       where a trap jumps to
//     +0x04 cause        1 system call, 2 timer, 3 bad instruction, 4 fault
//     +0x08 saved_pc
//     +0x0c saved_mode   1: it was user code
//     +0x10 other_sp     the stack pointer of the mode we are not in
//     +0x14 fault_addr   for a fault: the address that couldn't be used
//     +0x18 return       writing anything here is the way back
//     +0x1c timer        counts down once per user instruction, and the
//                        trap comes as it reaches 0: N lets N - 1 user
//                        instructions run (so 1 runs none). 0: off.
//     +0x20 saved_flags  N, Z, C, V as bits 3 to 0
//     +0x24 resume       writing an address here goes to user mode with
//                        EVERY user register loaded from the 17 words
//                        there: r0 to r12, sp, lr, pc, flags. (235 will
//                        want that. Real ARM has an instruction for it.)
//
// (Real ARM keeps the same state in special registers, cpsr and spsr,
// gives each mode its own copy of sp and lr, and returns with
// `movs pc, lr`. The names differ on every processor. The four ideas, a
// mode, a saved pc, a second stack and a vector, do not.)
//
// Where a trap's saved_pc points is the subtle part, and 218 prepared
// it. After a system call it points PAST the swi: the call is done. But
// after a fault it points AT the instruction, with every register as
// before, so the kernel can fix the cause and run it again. That is the
// whole trick behind the next exercise.
//
// One more convention: a `swi` in kernel mode has nobody above it to
// ask, so here it stops the machine, with r0 as the result.
//
// YOUR TASK: trap(), the way back, and the two checks in step().
//
const std = @import("std");

//@export machine
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
            m.saved_pc = ⟪m.cpu.r[PC]|||???⟫;
            m.saved_user = m.user;
            m.saved_flags = m.cpu.flags;
            m.user = ⟪false|||???⟫;
            std.mem.swap(u32, &m.cpu.r[SP], &m.other_sp);
            m.cpu.r[PC] = ⟪m.vector|||???⟫;
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
            m.cpu.r[PC] = ⟪m.saved_pc|||???⟫;
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
                .swi => m.trap(⟪.syscall|||???⟫),
                .undefined => m.trap(.bad_instruction),
                .fault => |f| {
                    m.fault_addr = ⟪f.addr|||???⟫;
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
//@end

const ta = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const Outcome = struct { result: u32, output: []u8 };

/// Assembles `source` at 0 and runs it from there, in kernel mode.
fn boot(source: []const u8) !Outcome {
    var line_no: usize = 0;
    var prog = assemble(ta, source, 0, &line_no) catch |err| {
        std.debug.print("assembling failed on line {d}: {s}\n", .{ line_no, @errorName(err) });
        return err;
    };
    defer prog.deinit(ta);
    var board = try Board.init(ta, 0x10000);
    defer board.deinit();
    board.load(0, prog.code);
    var m: Machine(GuardOnly) = .{ .board = &board };
    const result = try m.run(100_000);
    return .{ .result = result, .output = try ta.dupe(u8, board.uart_out.items) };
}

// A tiny kernel for the tests. It starts `user` in user mode with its
// own stack. Its trap handler is the test's own `handler`.
const kernel_setup =
    \\        .equ  SYS, 0x20000000
    \\        mov   sp, #0x8000             @ the kernel's stack
    \\        mov   r12, #0x20000000
    \\        ldr   r0, =handler
    \\        str   r0, [r12]               @ vector
    \\        ldr   r0, =user
    \\        str   r0, [r12, #0x08]        @ saved_pc: where user code begins
    \\        mov   r0, #1
    \\        str   r0, [r12, #0x0c]        @ saved_mode: user
    \\        mov   r0, #0x4000
    \\        str   r0, [r12, #0x10]        @ other_sp: the user's stack
    \\
;

const kernel_go =
    \\        mov   r0, #0
    \\        str   r0, [r12, #0x18]        @ "return": into user mode for the first time
    \\
;

const kernel_start = kernel_setup ++ kernel_go;

test "a system call, and back" {
    const out = try boot(kernel_start ++
        \\@ The handler: r0 holds a character to print. Then back to the caller.
        \\handler:
        \\        mov   r12, #0x10000000
        \\        str   r0, [r12]
        \\        mov   r12, #0x20000000
        \\        ldr   r11, [r12, #0x04]       @ cause
        \\        cmp   r11, #1
        \\        swine 0                       @ not a system call: stop
        \\        cmp   r0, #33                 @ "!" means: we're done
        \\        ldreq r0, [r12, #0x08]        @ ...and the result is how far into `user` we got
        \\        ldreq r1, =user
        \\        subeq r0, r0, r1
        \\        swieq 0
        \\        str   r0, [r12, #0x18]        @ return
        \\user:   mov   r0, #72                 @ "H"
        \\        swi   0
        \\        mov   r0, #105                @ "i"
        \\        swi   0
        \\        mov   r0, #33                 @ "!"
        \\        swi   0
    );
    defer ta.free(out.output);
    try expectEqualStrings("Hi!", out.output);
    // saved_pc of the last call: just past its swi, the sixth instruction of `user`
    try expectEqual(@as(u32, 6 * 4), out.result);
}

test "each mode has its own stack" {
    const out = try boot(kernel_start ++
        \\handler:
        \\        mov   r12, #0x20000000
        \\        ldr   r1, [r12, #0x10]        @ other_sp: the user's, now
        \\        add   r0, sp, r1              @ the kernel's sp is back in sp
        \\        ldr   r2, [r12, #0x0c]        @ saved_mode
        \\        add   r0, r0, r2
        \\        cmp   r3, #0
        \\        swine 0                       @ second time: stop with the sum
        \\        mov   r3, #1
        \\        str   r0, [r12, #0x18]        @ first time: return
        \\user:   sub   sp, sp, #0x100          @ the user moves its stack...
        \\        swi   0
        \\        add   r4, sp, #1              @ ...and still has it after the call
        \\        mov   sp, r4
        \\        swi   0
    );
    defer ta.free(out.output);
    try expectEqual(@as(u32, 0x8000 + 0x3f01 + 1), out.result);
}

test "user code can't touch the system registers" {
    const out = try boot(kernel_start ++
        \\handler:
        \\        mov   r12, #0x20000000
        \\        ldr   r0, [r12, #0x04]        @ cause: 4
        \\        ldr   r1, [r12, #0x14]        @ fault_addr
        \\        add   r0, r0, r1
        \\        ldr   r1, [r12, #0x08]        @ saved_pc: AT the store, the third instruction
        \\        ldr   r2, =user
        \\        sub   r1, r1, r2
        \\        add   r0, r0, r1, lsl #8
        \\        ldr   r1, [r12]               @ the vector is unharmed
        \\        ldr   r2, =handler
        \\        cmp   r1, r2
        \\        addne r0, r0, #1
        \\        swi   0
        \\user:   mov   r5, #0x20000000
        \\        mov   r6, #0
        \\        str   r6, [r5]                @ "from now on, traps go to address 0"
        \\        swi   0
    );
    defer ta.free(out.output);
    try expectEqual(@as(u32, 4 + 0x20000000 + (8 << 8)), out.result);
}

test "a fault can be repaired and the instruction run again" {
    const out = try boot(kernel_start ++
        \\handler:
        \\        mov   r12, #0x20000000
        \\        ldr   r11, [r12, #0x04]
        \\        cmp   r11, #4
        \\        swine 0                       @ the system call at the end: stop, with r0
        \\        ldr   r5, =number             @ a fault: give the user a pointer that works
        \\        str   r0, [r12, #0x18]        @ and go back TO the load
        \\user:   mvn   r5, #0                  @ a pointer to nowhere
        \\        ldr   r0, [r5]                @ faults; then, repaired, loads 1234
        \\        swi   0
        \\number: .word 1234
    );
    defer ta.free(out.output);
    try expectEqual(@as(u32, 1234), out.result);
}

test "an instruction that doesn't exist" {
    const out = try boot(kernel_start ++
        \\handler:
        \\        mov   r12, #0x20000000
        \\        ldr   r0, [r12, #0x04]
        \\        swi   0
        \\user:   .word 0xe7f000f0              @ no instruction
    );
    defer ta.free(out.output);
    try expectEqual(@as(u32, 3), out.result);
}

test "the timer takes the processor back" {
    // The user program never asks for anything: it counts to 1000. The
    // timer interrupts it every 50 instructions all the same, and the
    // handler prints a dot. The handler must leave every register the
    // user has as it found it. It uses r12 and r11, which this user
    // program doesn't.
    const out = try boot(kernel_setup ++
        \\        mov   r0, #50
        \\        str   r0, [r12, #0x1c]        @ timer
        \\
    ++ kernel_go ++
        \\handler:
        \\        mov   r12, #0x20000000
        \\        ldr   r11, [r12, #0x04]
        \\        cmp   r11, #2
        \\        swine 0                       @ the system call at the end
        \\        mov   r11, #50
        \\        str   r11, [r12, #0x1c]       @ wind the timer up again
        \\        mov   r11, #0x10000000
        \\        mov   r12, #46                @ "."
        \\        str   r12, [r11]
        \\        mov   r12, #0x20000000
        \\        str   r12, [r12, #0x18]
        \\user:   mov   r0, #0
        \\        mov   r1, #0
        \\count:  add   r1, r1, #1
        \\        add   r0, r0, r1
        \\        cmp   r1, #1000
        \\        bne   count
        \\        swi   0
    );
    defer ta.free(out.output);
    try expectEqual(@as(u32, 500500), out.result);
    // 2 + 4 * 1000 + 1 user instructions. The 50th tick of the timer is
    // the trap itself, so 49 of them run between two dots.
    try expectEqual(@as(usize, 4003 / 49), out.output.len);
}

test "returning with a whole set of registers" {
    const out = try boot(
        \\        mov   r12, #0x20000000
        \\        ldr   r0, =handler
        \\        str   r0, [r12]
        \\        ldr   r0, =frame
        \\        str   r0, [r12, #0x24]        @ become the program the frame describes
        \\handler:
        \\        mov   r12, #0x20000000
        \\        ldr   r1, [r12, #0x10]        @ the user's sp
        \\        add   r0, r0, r1
        \\        swi   0
        \\user:   addeq r0, r0, r7              @ Z is set in the frame's flags, so this runs
        \\        addne r0, r0, #1000
        \\        add   r0, r0, r12
        \\        add   r0, r0, lr
        \\        swi   0
        \\frame:  .word 1, 0, 0, 0, 0, 0, 0, 20, 0, 0, 0, 0, 300   @ r0 to r12
        \\        .word 0x4000, 50000, user, 4                    @ sp, lr, pc, flags: Z
    );
    defer ta.free(out.output);
    try expectEqual(@as(u32, 1 + 20 + 300 + 50000 + 0x4000), out.result);
}

test "trouble in the kernel stops the machine" {
    try expectError(error.KernelFault, boot(" mvn r0, #0\n ldr r0, [r0]\n"));
    try expectError(error.KernelBadInstruction, boot(" .word 0xe7f000f0\n"));
    try expectError(error.RanTooLong, boot("forever: b forever\n"));
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include arm_enc
//@include arm_alu
//@include arm_asm_line
//@include arm_asm
//@include arm_emu
