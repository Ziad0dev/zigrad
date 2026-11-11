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

//@export tlb
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
        const vpage: u20 = ⟪@intCast(addr >> page_bits)|||???⟫;
        for (t.entries) |e| {
            if (!e.valid or e.vpage != vpage) continue;
            if (write and !e.writable) return error.ReadOnly;
            // the entry's page, and the address's own offset
            return ⟪@as(u32, e.ppage) << page_bits | (addr & (page_size - 1))|||???⟫;
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
//@end

/// The Verilog TLB's lookup. An entry is 42 bits:
///     [41] valid   [40] writable   [39:20] virtual page   [19:0] physical page
/// For the entry `entries[i]`: if it is valid and its virtual page is
/// the address's (vaddr[31:12]), then this is a hit; the physical
/// address is the entry's physical page followed by the address's low 12
/// bits; and `writable` is the entry's bit.
//⟪
const tlb_match =
    \\      if (entries[i][41] && entries[i][39:20] == vaddr[31:12]) begin
    \\        hit = 1;
    \\        paddr = {entries[i][19:0], vaddr[11:0]};
    \\        writable = entries[i][40];
    \\      end
;
//|||
const tlb_match = ???;
//⟫

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

//@include machine
//@include verilog_sim
//@include arm_enc
//@include arm_alu
//@include arm_asm_line
//@include arm_asm
//@include arm_emu
