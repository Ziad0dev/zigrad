//
// ─── Exercise 234: virtual memory ─────────────────────────────────────
//
// 233's user mode protects a handful of registers. Everything else, the
// kernel's own memory, the UART, other programs, is still one stray
// pointer away. The real protection is this exercise: user code never
// sees a real address again.
//
// Memory is cut into *pages* of 4096 bytes. An address is then a page
// number (the top 20 bits) and an offset inside the page (the low 12):
//
//     0x40001a2c   =   page 0x40001, offset 0xa2c
//
// In user mode, every address the program uses, to fetch, load or
// store, is *virtual*: before it reaches the bus, the page number is
// looked up in a small table and replaced by a *physical* page number.
// The offset passes through untouched.
//
//     virtual 0x40001a2c  --(page 0x40001 is physical page 0x00007)-->  0x00007a2c
//
// The table is the *TLB* (for "translation lookaside buffer", a name
// that explains nothing). Ours has 8 entries, and only the kernel can
// write them. An entry says: this virtual page is that physical page,
// and whether it may be written. And if the program uses a page that
// has no entry? That is a fault, like any other (233): cause 4, the
// address in fault_addr, pc still at the instruction.
//
// Three things follow, and they are most of what an operating system
// does with memory:
//
//   ISOLATION     A program can only name pages the kernel gave it. The
//                 kernel's memory and the devices have no virtual
//                 address at all, so there is nothing to protect them
//                 from.
//   ANY ADDRESS   Every program can be linked to run at the same address
//                 (ours: 0x40000000), wherever it really is in memory.
//   ON DEMAND     The kernel need not map anything in advance. It can
//                 wait for the fault, map the page then, and return: the
//                 instruction runs again, and the program never knows.
//                 A page that is never touched costs nothing.
//
// The kernel reaches the TLB through three more system registers:
//
//     +0x40 index     which entry (0 to 7) the next write to +0x44 fills
//     +0x48 physical  the physical page, as an address (low 12 bits ignored)
//     +0x44 virtual   the virtual page, as an address; bit 0 = valid,
//                     bit 1 = writable. Writing this one fills the entry.
//
// (A real processor's TLB works the same way but is only a cache: on a
// miss, x86 and ARM hardware walk a tree of tables in memory to find the
// entry. MIPS did it this way, by trapping to the kernel, and it is by
// far the smaller circuit.)
//
// How small? The lookup is the second half of this exercise, in
// Verilog: eight comparators, side by side. The outline budgets a
// thousand lines of Verilog for its MMU, because it walks page tables.
// This one is checked against the Zig model like 219's ALU was. Wiring
// it between 221's processor and its bus is left for a rainy day: from
// here on, the operating system runs on the emulator.
//
// YOUR TASK: the lookup, in Zig and in Verilog.
//
const std = @import("std");

const page_bits = 12;
const page_size: u32 = 1 << page_bits;

const TlbEntry = struct {
    valid: bool = false,
    writable: bool = false,
    /// virtual and physical page numbers: an address's top 20 bits
    vpage: u20 = 0,
    ppage: u20 = 0,
};

const Tlb = struct {
    entries: [8]TlbEntry = @splat(.{}),
    index: u32 = 0,
    physical: u32 = 0,

    /// The physical address for a virtual one. error.TlbMiss if no valid
    /// entry has its page, error.ReadOnly for a write to a page that
    /// isn't writable.
    fn translate(t: *Tlb, addr: u32, write: bool) !u32 {
        const vpage: u20 = ???;
        for (t.entries) |e| {
            if (!e.valid or e.vpage != vpage) continue;
            if (write and !e.writable) return error.ReadOnly;
            // the entry's page, and the address's own offset
            return ???;
        }
        return error.TlbMiss;
    }

    fn readReg(t: *Tlb, reg: u32) !u32 {
        return switch (reg) {
            0x40 => t.index,
            0x48 => t.physical,
            else => error.NoDevice,
        };
    }

    fn writeReg(t: *Tlb, reg: u32, value: u32) !void {
        switch (reg) {
            0x40 => t.index = value % 8,
            0x48 => t.physical = value,
            0x44 => t.entries[t.index] = .{
                .valid = value & 1 != 0,
                .writable = value & 2 != 0,
                .vpage = @intCast(value >> page_bits),
                .ppage = @intCast(t.physical >> page_bits),
            },
            else => return error.NoDevice,
        }
    }

    fn switched(_: *Tlb) void {}
};

/// The Verilog TLB's lookup. An entry is 42 bits:
///     [41] valid   [40] writable   [39:20] virtual page   [19:0] physical page
/// For the entry `entries[i]`: if it is valid and its virtual page is
/// the address's (vaddr[31:12]), then this is a hit; the physical
/// address is the entry's physical page followed by the address's low 12
/// bits; and `writable` is the entry's bit.
const tlb_match = ???;

const tlb_module =
    \\module tlb(
    \\  input clk,
    \\  input we, input [2:0] index, input [41:0] entry,   // the kernel fills an entry
    \\  input [31:0] vaddr, input write,                   // an access by user code
    \\  output reg [31:0] paddr,
    \\  output miss,                                       // no entry for this page
    \\  output denied                                      // a write to a read-only page
    \\);
    \\  reg [41:0] entries [0:7];
    \\  reg hit, writable;
    \\  integer i;
    \\  initial for (i = 0; i < 8; i = i + 1) entries[i] = 0;
    \\  always @(posedge clk) if (we) entries[index] <= entry;
    \\  // all eight entries are compared at once: the loop describes eight
    \\  // copies of the same gates
    \\  always @* begin
    \\    hit = 0;
    \\    paddr = 0;
    \\    writable = 0;
    \\    for (i = 0; i < 8; i = i + 1) begin
    \\
++ tlb_match ++
    \\
    \\    end
    \\  end
    \\  assign miss = !hit;
    \\  assign denied = hit && write && !writable;
    \\endmodule
    \\
;

const ta = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

test "translating" {
    var t: Tlb = .{};
    try expectError(error.TlbMiss, t.translate(0x40001a2c, false));
    t.entries[3] = .{ .valid = true, .vpage = 0x40001, .ppage = 0x00007 };
    t.entries[5] = .{ .valid = true, .writable = true, .vpage = 0x7ffff, .ppage = 0x00009 };
    t.entries[6] = .{ .valid = false, .writable = true, .vpage = 0x12345, .ppage = 0x00001 };
    try expectEqual(@as(u32, 0x00007a2c), try t.translate(0x40001a2c, false));
    try expectEqual(@as(u32, 0x00007000), try t.translate(0x40001000, false));
    try expectEqual(@as(u32, 0x00007fff), try t.translate(0x40001fff, false));
    try expectError(error.TlbMiss, t.translate(0x40002000, false));
    try expectError(error.TlbMiss, t.translate(0x40000fff, false));
    try expectError(error.ReadOnly, t.translate(0x40001a2c, true));
    try expectEqual(@as(u32, 0x00009ffc), try t.translate(0x7ffffffc, true));
    try expectEqual(@as(u32, 0x00009ffc), try t.translate(0x7ffffffc, false));
    try expectError(error.TlbMiss, t.translate(0x12345000, false)); // not valid
    try expectError(error.TlbMiss, t.translate(0x00007a2c, false)); // physical addresses mean nothing here
    // the kernel's side: through the registers
    try t.writeReg(0x40, 6);
    try t.writeReg(0x48, 0x0000b123);
    try t.writeReg(0x44, 0x12345000 | 3);
    try expectEqual(@as(u32, 0x0000b004), try t.translate(0x12345004, true));
    try t.writeReg(0x44, 0); // and gone again
    try expectError(error.TlbMiss, t.translate(0x12345004, false));
}

const Outcome = struct { result: u32, output: []u8 };

/// Boots `kernel` (assembled at 0), with `user` assembled to run at
/// virtual 0x40000000 and placed at physical 0x3000.
fn boot(comptime kernel: []const u8, comptime user: []const u8) !Outcome {
    var kernel_prog = try assemble(ta, kernel_setup ++ kernel, 0, null);
    defer kernel_prog.deinit(ta);
    var user_prog = try assemble(ta, user, 0x40000000, null);
    defer user_prog.deinit(ta);
    var board = try Board.init(ta, 0x20000);
    defer board.deinit();
    board.load(0, kernel_prog.code);
    board.load(0x3000, user_prog.code);
    var m: Machine(Tlb) = .{ .board = &board };
    const result = try m.run(100_000);
    return .{ .result = result, .output = try ta.dupe(u8, board.uart_out.items) };
}

// The tests' kernel: maps the user's code page (read-only, entry 0),
// and starts the user program at 0x40000000 with its stack pointer at
// 0x80000000. Each test supplies `handler`.
const kernel_setup =
    \\        mov   sp, #0x2000
    \\        mov   r12, #0x20000000
    \\        ldr   r0, =handler
    \\        str   r0, [r12]               @ vector
    \\        mov   r0, #0
    \\        str   r0, [r12, #0x40]        @ TLB entry 0:
    \\        mov   r0, #0x3000
    \\        str   r0, [r12, #0x48]        @   physical 0x3000
    \\        mov   r0, #0x40000000
    \\        orr   r0, r0, #1
    \\        str   r0, [r12, #0x44]        @   is virtual 0x40000000, valid, read-only
    \\        mov   r0, #0x40000000
    \\        str   r0, [r12, #0x08]        @ saved_pc
    \\        mov   r0, #1
    \\        str   r0, [r12, #0x0c]        @ saved_mode: user
    \\        mov   r0, #0x80000000
    \\        str   r0, [r12, #0x10]        @ the user's sp
    \\        mov   r9, #0                  @ the handlers count in r9
    \\        str   r0, [r12, #0x18]        @ go
    \\
;

// A handler that maps pages on demand: the page of fault_addr becomes
// physical page 8, 9, 10, ... in TLB entry 1, 2, ... 7, 1, 2, ...
// (never 0: that is the code). A system call stops, with r0.
const demand_handler =
    \\handler:
    \\        mov   r12, #0x20000000
    \\        ldr   r11, [r12, #0x04]
    \\        cmp   r11, #4
    \\        swine 0
    \\        add   r11, r9, #8             @ the next free physical page
    \\        mov   r11, r11, lsl #12
    \\        str   r11, [r12, #0x48]
    \\        mov   r10, r9                 @ entry 1 + (count mod 7)
    \\.Lmod:  cmp   r10, #7
    \\        subge r10, r10, #7
    \\        bge   .Lmod
    \\        add   r10, r10, #1
    \\        str   r10, [r12, #0x40]
    \\        ldr   r11, [r12, #0x14]       @ fault_addr
    \\        mov   r11, r11, lsr #12
    \\        mov   r11, r11, lsl #12
    \\        orr   r11, r11, #3            @ valid, writable
    \\        str   r11, [r12, #0x44]
    \\        add   r9, r9, #1
    \\        str   r12, [r12, #0x18]       @ back to the instruction that faulted
    \\
;

test "a program at 0x40000000 that is really at 0x3000" {
    const out = try boot(
        \\handler:
        \\        swi   0
    ,
        \\        ldr   r0, value               @ fetched and loaded through the TLB
        \\        add   r0, r0, pc, lsr #28     @ and pc says 0x4000000c
        \\        swi   0
        \\value:  .word 1000
    );
    defer ta.free(out.output);
    try expectEqual(@as(u32, 1004), out.result);
}

test "pages on demand" {
    const out = try boot(demand_handler,
        \\        mov   r0, #42
        \\        str   r0, [sp, #-4]!          @ the stack page: mapped at this very moment
        \\        mov   r1, #0x50000000
        \\        mov   r2, #7
        \\        str   r2, [r1, #0x10]         @ and a page for data
        \\        str   r2, [r1, #0x14]         @ the same page: no fault this time
        \\        ldr   r3, [sp], #4
        \\        ldr   r4, [r1, #0x10]
        \\        add   r0, r3, r4
        \\        add   r0, r0, r9, lsl #8      @ r9: how many faults the kernel handled
        \\        swi   0
    );
    defer ta.free(out.output);
    try expectEqual(@as(u32, 42 + 7 + (2 << 8)), out.result);
}

test "what user code can't do any more" {
    // write to its own code
    const code = try boot(
        \\handler:
        \\        mov   r12, #0x20000000
        \\        ldr   r0, [r12, #0x14]        @ fault_addr
        \\        swi   0
    ,
        \\        mov   r1, #0x40000000
        \\        str   r1, [r1, #8]
        \\        swi   0
    );
    defer ta.free(code.output);
    try expectEqual(@as(u32, 0x40000008), code.result);
    // reach the UART, the kernel's memory, or the system registers: none
    // of them has a virtual address
    inline for (.{ "0x10000000", "0x0", "0x20000000", "0x3000" }) |target| {
        const out = try boot(
            \\handler:
            \\        mov   r12, #0x20000000
            \\        ldr   r0, [r12, #0x14]
            \\        ldr   r1, [r12, #0x04]
            \\        add   r0, r0, r1
            \\        swi   0
        , "        ldr   r1, =" ++ target ++ "\n        ldr   r0, [r1]\n        mov   r0, #99\n        swi   0\n");
        defer ta.free(out.output);
        try expectEqual(try std.fmt.parseInt(u32, target, 0) + 4, out.result);
    }
}

test "more pages than the TLB has entries" {
    // Nine data pages, touched in turn, with seven TLB entries to go
    // round: every touch is a miss. This handler gives each fault a NEW
    // physical page, so a page that was pushed out of the TLB comes back
    // empty. (A kernel that wants to keep its promises must remember, for
    // every process, which physical page each virtual page had. That
    // list is a *page table*, and it is 237's.)
    const out = try boot(demand_handler,
        \\        mov   r1, #0x50000000
        \\        mov   r2, #0
        \\fill:   add   r3, r2, #100
        \\        str   r3, [r1, r2, lsl #12]   @ page r2 gets 100 + r2
        \\        add   r2, r2, #1
        \\        cmp   r2, #9
        \\        bne   fill
        \\        mov   r5, #0x8000
        \\        ldr   r0, [r1, r5]            @ page 8: still in the TLB
        \\        mov   r5, #0x1000
        \\        ldr   r4, [r1, r5]            @ page 1: pushed out; faults; a fresh page: 0
        \\        add   r0, r0, r4
        \\        add   r0, r0, r9, lsl #8
        \\        swi   0
    );
    defer ta.free(out.output);
    try expectEqual(@as(u32, 108 + 0 + (10 << 8)), out.result);
}

test "the TLB in gates against the TLB in Zig" {
    var prng = std.Random.DefaultPrng.init(234);
    const rand = prng.random();
    var model: Tlb = .{};
    var body: std.Io.Writer.Allocating = .init(ta);
    defer body.deinit();
    var want: std.Io.Writer.Allocating = .init(ta);
    defer want.deinit();
    for (0..300) |n| {
        if (n % 10 == 0) {
            // the kernel fills an entry; pages come from a small set, so lookups often hit
            const index = rand.uintLessThan(u32, 8);
            const e: TlbEntry = .{ .valid = rand.uintLessThan(u8, 8) != 0, .writable = rand.boolean(), .vpage = @as(u20, 0xc0000) + rand.uintLessThan(u20, 12), .ppage = rand.int(u20) };
            for (&model.entries) |*other| {
                if (other.vpage == e.vpage) other.valid = false; // a kernel keeps a page in one entry only
            }
            model.entries[index] = e;
            for (model.entries, 0..) |entry, k| {
                const bits: u64 = @as(u64, @intFromBool(entry.valid)) << 41 | @as(u64, @intFromBool(entry.writable)) << 40 | @as(u64, entry.vpage) << 20 | entry.ppage;
                try body.writer.print("    @(negedge clk); we = 1; index = {d}; entry = 42'h{x}; @(negedge clk); we = 0;\n", .{ k, bits });
            }
        }
        const vaddr = (@as(u32, 0xc0000) + rand.uintLessThan(u32, 12)) << 12 | rand.uintLessThan(u32, 4096);
        const write = rand.boolean();
        try body.writer.print("    vaddr = 32'h{x}; write = {d}; #1 $display(\"%b%b %h\", miss, denied, miss ? 0 : paddr);\n", .{ vaddr, @intFromBool(write) });
        if (model.translate(vaddr, false)) |paddr| {
            const denied = if (model.translate(vaddr, true)) |_| false else |_| write;
            try want.writer.print("0{d} {x:0>8}\n", .{ @intFromBool(denied), paddr });
        } else |_| try want.writer.writeAll("10 00000000\n");
    }
    const source = try std.mem.concat(ta, u8, &.{
        tlb_module,
        \\module bench;
        \\  reg clk = 0;
        \\  reg we = 0;
        \\  reg [2:0] index;
        \\  reg [41:0] entry;
        \\  reg [31:0] vaddr = 0;
        \\  reg write = 0;
        \\  wire [31:0] paddr;
        \\  wire miss, denied;
        \\  tlb dut(clk, we, index, entry, vaddr, write, paddr, miss, denied);
        \\  always #5 clk = ~clk;
        \\  initial begin
        \\
        ,
        body.written(),
        "    $finish;\n  end\nendmodule\n",
    });
    defer ta.free(source);
    const got = try simulateOrSkip(ta, source);
    defer ta.free(got);
    try std.testing.expectEqualStrings(want.written(), got);
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
    const ran = try std.process.run(alloc, io, .{ .argv = &.{ "vvp", "-n", vvp_path }, .cwd = .{ .path = dir } });
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
