//
// ─── Exercise 221: loads and stores, and a third state ────────────────
//
// 220's processor computes, but it can only reach its 15 registers. This
// exercise gives it the bus: `ldr`, `str` and their byte forms. With them
// it runs everything 218's emulator runs.
//
// First, WHERE. 218's loadStore(), as wires:
//
//   offset      12 bits of the instruction, or (bit 25) a shifted
//               register: the barrel shifter already has it on sh_out
//   moved       the base register plus (bit 23, U) or minus the offset
//   addr        [rn, #n] uses `moved`; [rn], #n uses rn as it was (bit 24, P)
//   updates_rn  rn becomes `moved` for [rn], #n and for [rn, #n]! (bit 21, W)
//
// A STORE fits in EXEC. While the instruction is being executed, the
// processor takes the bus away from pc: it puts `addr` on the address
// wires, the register's value on the data wires, and raises the write
// strobes. At the clock edge that ends the cycle, the memory takes it.
//
// The strobes are how a byte gets written into a memory made of 32-bit
// words: there are four of them, one per byte of the word, and only the
// raised ones are written. `strb` to address 0x1002 raises strobe 2 of
// the word at 0x1000. So that it needn't steer the byte, the processor
// puts it on all four byte lanes at once; the strobe picks the lane.
//
// A LOAD doesn't fit. EXEC can put the address on the bus, but a block
// RAM answers at the NEXT edge (220), and by then EXEC is over. So a
// load gets a state of its own:
//
//   EXEC    put addr on the bus. Store nothing: stay on this instruction
//           (keep pc, don't retire), and go to LOAD.
//   LOAD    the memory's answer is on mem_rdata now. This is the cycle
//           that finishes the instruction: rn and rd get their new
//           values, pc moves on, and the instruction retires.
//
// In LOAD the instruction is no longer on the memory's wires (the data
// is), which is what insn_q was for: EXEC saved a copy. Every decoded
// wire (rn, rd, addr, ...) reads the copy during LOAD, and since EXEC
// changed no register, they all still say what they said in EXEC.
//
// A byte load gets the whole word and picks its byte out: `loaded` below
// does that, and is ready for you to use.
//
// So instructions now take different times: a load three cycles, the
// rest two. Real ARM7s are like this too (their manuals count "S", "N"
// and "I" cycles per instruction).
//
// YOUR TASK: the address, the write strobes, and what EXEC and LOAD do.
//
const std = @import("std");

//@export v_cpu_mem
/// Which address a load or store uses: `moved` or the plain `rn_val`.
const mem_address = ⟪"insn[24] ? moved : rn_val"|||???⟫;

/// The four write strobes. When not `storing`: none. For a byte
/// (`is_byte`): only the one for the byte the address's two low bits
/// name, which is 4'b0001 shifted left by them. For a word: all four.
const write_strobes = ⟪"!storing ? 4'b0000 : is_byte ? (4'b0001 << addr[1:0]) : 4'b1111"|||???⟫;

/// EXEC, for a load or store whose condition holds. The defaults above
/// it said: state <= FETCH, retired <= 1, pc <= pc + 4.
/// A load (`is_load`) overrides all three and changes no register.
/// A store is finished here; the bus wiring below does the storing
/// itself, and what is left for EXEC is rn, if `updates_rn`.
//⟪
const exec_load_store =
    \\              if (is_load) begin
    \\                state <= LOAD; retired <= 0; pc <= pc;
    \\              end else begin
    \\                if (updates_rn) r[rn] <= moved;
    \\              end
;
//|||
const exec_load_store = ???;
//⟫

/// The LOAD state. rn first, if `updates_rn`; then `loaded` goes to rd
/// (so that when they are the same register, the load wins). As in 220,
/// rd == 15 means pc; otherwise pc moves on by 4. Then the instruction
/// is done: retire it, and back to FETCH.
//⟪
const load_cycle =
    \\          if (updates_rn) r[rn] <= moved;
    \\          if (rd == 15) pc <= loaded;
    \\          else begin
    \\            r[rd] <= loaded;
    \\            pc <= pc + 4;
    \\          end
    \\          retired <= 1;
    \\          state <= FETCH;
;
//|||
const load_cycle = ???;
//⟫

const bus_wiring =
    \\  // a load or a store: where, and what
    \\  wire is_load = insn[20];
    \\  wire is_byte = insn[22];
    \\  wire [31:0] offset = insn[25] ? sh_out : {20'b0, insn[11:0]};
    \\  wire [31:0] moved = insn[23] ? rn_val + offset : rn_val - offset;
    \\  wire updates_rn = !insn[24] || insn[21];
    \\  wire [31:0] addr =
++ " " ++ mem_address ++ ";\n" ++
    \\  // During EXEC of a load or store, the bus is the instruction's. Otherwise it fetches.
    \\  wire on_bus = (state == EXEC) && pass && is_mem;
    \\  wire storing = on_bus && !is_load;
    \\  assign mem_addr = on_bus ? addr : pc;
    \\  assign mem_wdata = is_byte ? {4{rd_val[7:0]}} : rd_val;
    \\  assign mem_wstrb =
++ " " ++ write_strobes ++ ";\n" ++
    \\  // what a load gets: the word, or one byte of it, with zeros above
    \\  wire [7:0] loaded_byte = mem_rdata >> {addr[1:0], 3'b000};
    \\  wire [31:0] loaded = is_byte ? {24'b0, loaded_byte} : mem_rdata;
    \\
;

/// The finished processor.
const arm_cpu = cpuSource(bus_wiring, exec_load_store, load_cycle);
//@end

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "a store takes two cycles, a load three" {
    const result = try cosim(arm_cpu,
        \\        mov   r1, #0x1000
        \\        mov   r0, #42
        \\        str   r0, [r1]
        \\        ldr   r2, [r1]
        \\        ldreq r3, [r1]            @ not run (Z is clear): two cycles, like anything skipped
        \\        swi   0
    );
    try expectEqual(@as(usize, 5), result.instructions);
    // two each, one more for the load, and the swi's own two
    try expectEqual(@as(usize, 2 * 5 + 1 + 2), result.cycles);
}

test "summing an array: three addressing modes" {
    _ = try cosim(arm_cpu,
        \\        ldr   r4, =numbers
        \\        mov   r0, #0
        \\        mov   r5, #4
        \\sum:    ldr   r1, [r4], #4          @ load, then step the pointer
        \\        add   r0, r0, r1
        \\        subs  r5, r5, #1
        \\        bne   sum
        \\        ldr   r6, =numbers
        \\        mov   r7, #2
        \\        ldr   r2, [r6, r7, lsl #2]  @ numbers[2]
        \\        ldr   r3, [r6, #4]!         @ step the pointer, then load
        \\        ldr   r8, =result
        \\        str   r0, [r8]
        \\        ldr   r9, [r8]
        \\        ldr   r10, [r8, #-12]       @ numbers[3], from the other side
        \\        ldr   r6, [r6]              @ rn and rd the same: the load wins
        \\        swi   0
        \\numbers: .word 0x102, 0x304, 0x506, 0x708
        \\result: .word 0
    );
}

test "bytes: reversing a string in place" {
    _ = try cosim(arm_cpu,
        \\        ldr   r0, =text
        \\        add   r1, r0, #6            @ the last letter
        \\swap:   ldrb  r2, [r0]
        \\        ldrb  r3, [r1]
        \\        strb  r3, [r0], #1
        \\        strb  r2, [r1], #-1
        \\        cmp   r0, r1
        \\        blo   swap
        \\        ldr   r4, =text
        \\        ldr   r5, [r4]              @ "kcab", if every byte went to its own place
        \\        ldr   r6, [r4, #4]          @ "sdr" and the 0
        \\        ldr   r7, [r4, #8]          @ the neighbours are untouched
        \\        ldr   r8, [r4, #-4]
        \\        swi   0
        \\        .word 0x11223344
        \\text:   .asciz "drsback"
        \\        .word 0x55667788
    );
}

test "a stack: recursion, and returning by loading pc" {
    const result = try cosim(arm_cpu,
        \\        mov   sp, #0x10000
        \\        mov   r0, #6
        \\        bl    sum_to
        \\        swi   0
        \\@ sum_to(n) = n + sum_to(n - 1), and sum_to(0) = 0
        \\sum_to: cmp   r0, #0
        \\        moveq pc, lr
        \\        str   lr, [sp, #-4]!        @ push
        \\        str   r0, [sp, #-4]!
        \\        sub   r0, r0, #1
        \\        bl    sum_to
        \\        ldr   r1, [sp], #4          @ pop
        \\        add   r0, r0, r1
        \\        ldr   pc, [sp], #4          @ pop straight into pc: return
    );
    // 3 at the top, 9 for each of the six calls that recurse, 2 for the one that doesn't
    try expectEqual(@as(usize, 3 + 6 * 9 + 2), result.instructions);
}

test "a thousand random instructions with loads and stores, five times" {
    for (0..5) |seed| {
        const source = try randomProgram(std.testing.allocator, 221 + seed, 1000, true);
        defer std.testing.allocator.free(source);
        const result = try cosim(arm_cpu, source);
        try expectEqual(@as(usize, 1011), result.instructions);
    }
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include verilog_sim
//@include arm_enc
//@include arm_alu
//@include arm_asm_line
//@include arm_asm
//@include arm_emu
//@include v_datapath
//@include v_cpu
//@include cosim
//@include cpu_fuzz
