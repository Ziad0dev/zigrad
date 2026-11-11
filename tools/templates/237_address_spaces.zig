//
// ─── Exercise 237: every process in a world of its own ────────────────
//
// 236's processes take turns politely but live in one address space,
// kernel included. This exercise gives each its own, with 234's TLB,
// and that changes what a process *is*: no longer a function inside the
// kernel's image, but a separate program, linked on its own, that
// believes it starts at address 0x40000000 no matter how many others
// believe the same.
//
// The kernel's promise to each process is a *page table*: for every
// virtual page the process may use, which physical page holds it. Ours
// is as small as a page table gets, 17 words per process:
//
//     slots 0 to 15    virtual pages 0x40000000, 0x40001000, ... (64 KB:
//                      the program's code and data, then room to grow)
//     slot 16          virtual page 0x7ffff000: the stack, which starts
//                      at 0x80000000 and grows down
//
// A slot holds a physical page's address, or 0 for "not yet". Anything
// outside those 17 pages is not the process's to touch, and trying gets
// it killed: that is all a *segmentation fault* is.
//
// The TLB (8 entries) is only a cache of the running process's table,
// and the kernel fills it lazily, on faults. So a page fault means one
// of three things, and telling them apart is the heart of this
// exercise:
//
//   1. The address is outside the table: kill the process.
//   2. The slot is 0, a page touched for the first time: find a free
//      physical page now. (If there is none left, the machine is out of
//      memory, and the process that asked dies of it, as in case 1.)
//      If the page belongs to the program's image,
//      copy that part of the image into it (*demand loading*: a program
//      that never runs its error handling never loads it). Otherwise it
//      is fresh memory, stack or data.
//   3. The slot is filled, and the entry was merely pushed out of the
//      TLB, or the process was switched out: nothing to find.
//   In cases 2 and 3: put the mapping into the TLB and return. The
//   instruction runs again (233), and the process never knows.
//
// And one new duty on every context switch: *flush the TLB*. Its
// entries are the old process's. Leave them, and the new process would
// read the old one's memory through them.
//
// When a process ends, its pages go back to the kernel, which keeps the
// free ones the way 230's malloc keeps free blocks: as a list, chained
// through the first word of each. The next process to need a page gets
// one of those (wiped: never hand out someone's old data).
//
// The tests boot the kernel with several separately linked programs in
// memory (as a bootloader would leave them), including the same program
// twice: two processes, the same addresses, different memory.
//
// YOUR TASK: flushing, the new process's frame, and the page fault
// handler.
//
const std = @import("std");

/// flush_tlb(): make all 8 entries invalid. The registers (234), as
/// words of `sys`: sys[16] is the index, sys[17] the virtual side, whose
/// bit 0 is "valid".
//⟪
const vm_flush =
    \\int flush_tlb() {
    \\    for (int i = 0; i < 8; i++) {
    \\        sys[16] = i;
    \\        sys[17] = 0;
    \\    }
    \\    return 0;
    \\}
    \\
;
//|||
const vm_flush = ???;
//⟫

/// In spawn(): the new process's pc and sp (frame slots 15 and 13).
/// Every program is linked to start at 0x40000000, and the stack starts
/// at the top of its page.
//⟪
const vm_new_frame =
    \\        frame[15] = 0x40000000;
    \\        frame[13] = 0x80000000;
    \\
;
//|||
const vm_new_frame = ???;
//⟫

/// page_fault(addr): repair a fault at virtual address `addr` for the
/// running process, and return 1; or return 0 if the address isn't the
/// process's to use. Given: slot_of(addr), the table slot (or -1);
/// `entry`, a pointer to that slot; new_page(), a zeroed physical page,
/// or 0 if memory has run out (then return 0, and leave the slot empty);
/// and for the image: image_base[running] (where the program's bytes
/// are, physically), image_pages[running] (how many pages of them), and
/// memcpy(to, from, n) with char * arguments.
/// To fill the TLB: the index goes in sys[16] (use next_tlb, then move
/// it on, round and round the 8 entries); then the physical page's
/// address in sys[18]; then, in sys[17], the address's virtual page
/// (the address with its low 12 bits cleared) with bits 0 and 1 set:
/// valid and writable.
//⟪
const vm_page_fault =
    \\int page_fault(int addr) {
    \\    int slot = slot_of(addr);
    \\    if (slot < 0) return 0;
    \\    int *entry = tables + running * 17 + slot;
    \\    if (*entry == 0) {
    \\        *entry = new_page();
    \\        if (*entry == 0) return 0;
    \\        if (slot < image_pages[running])
    \\            memcpy((char *)*entry, (char *)(image_base[running] + slot * 4096), 4096);
    \\    }
    \\    sys[16] = next_tlb;
    \\    next_tlb = (next_tlb + 1) & 7;
    \\    sys[18] = *entry;
    \\    sys[17] = (addr & -4096) | 3;
    \\    return 1;
    \\}
    \\
;
//|||
const vm_page_fault = ???;
//⟫

const vm_c =
    \\int *sys = (int *)0x20000000;
    \\int *boot = (int *)0x1f000;     /* what the loader left: a count, then (address, size) pairs */
    \\int frames[68];
    \\int alive[4];
    \\int *current;
    \\int running;
    \\int slice = 2000;
    \\int tables[68];                 /* a page table of 17 slots for each process */
    \\int image_base[4];
    \\int image_pages[4];
    \\int next_free = 0x50000;        /* physical memory from here up has never been used... */
    \\int memory_end = 0x80000;       /* ...as far as here, where it ends */
    \\int free_pages;                 /* pages that came back, each holding the next one's address */
    \\int next_tlb;
    \\int faults;                     /* page faults repaired, for the curious */
    \\
    \\int new_page() {
    \\    int page = free_pages;
    \\    if (page) {
    \\        free_pages = *(int *)page;
    \\    } else {
    \\        if (next_free >= memory_end) return 0;
    \\        page = next_free;
    \\        next_free += 4096;
    \\    }
    \\    memset((char *)page, 0, 4096);    /* never hand out someone's old data */
    \\    return page;
    \\}
    \\
    \\/* The end of a process: its pages go back on the list. */
    \\int reap(int p) {
    \\    for (int i = 0; i < 17; i++) {
    \\        int *entry = tables + p * 17 + i;
    \\        if (*entry) {
    \\            *(int *)*entry = free_pages;
    \\            free_pages = *entry;
    \\            *entry = 0;
    \\        }
    \\    }
    \\    alive[p] = 0;
    \\    return 0;
    \\}
    \\
    \\/* Which slot of a page table an address belongs to. -1: none. */
    \\int slot_of(int addr) {
    \\    int page = (addr >> 12) & 0xfffff;
    \\    if (page >= 0x40000 && page < 0x40010) return page - 0x40000;
    \\    if (page == 0x7ffff) return 16;
    \\    return -1;
    \\}
    \\
++ vm_flush ++ vm_page_fault ++
    \\/* Starts program number `which` of the loader's list. */
    \\int spawn(int which) {
    \\    if (which < 0 || which >= boot[0]) return -1;
    \\    for (int p = 0; p < 4; p++) {
    \\        if (alive[p]) continue;
    \\        int *frame = frames + p * 17;
    \\        for (int i = 0; i < 17; i++) { frame[i] = 0; tables[p * 17 + i] = 0; }
    \\
++ vm_new_frame ++
    \\        image_base[p] = boot[1 + which * 2];
    \\        image_pages[p] = (boot[2 + which * 2] + 4095) >> 12;
    \\        alive[p] = 1;
    \\        return p;
    \\    }
    \\    return -1;
    \\}
    \\
    \\int schedule() {
    \\    for (int step = 1; step <= 4; step++) {
    \\        int p = (running + step) & 3;
    \\        if (alive[p]) {
    \\            running = p;
    \\            current = frames + p * 17;
    \\            sys[7] = slice;
    \\            flush_tlb();        /* the entries in there are someone else's */
    \\            return p;
    \\        }
    \\    }
    \\    halt(faults);
    \\    return -1;
    \\}
    \\
    \\int trap() {
    \\    int cause = sys[1];
    \\    if (cause == 2) { schedule(); return 0; }
    \\    if (cause == 4 && page_fault(sys[5])) { faults++; return 0; }
    \\    if (cause != 1) {
    \\        puts("[segfault ");
    \\        putchar('0' + running);
    \\        puts("]");
    \\        reap(running);
    \\        schedule();
    \\        return 0;
    \\    }
    \\    int number = current[0];
    \\    if (number == 1) current[0] = putchar(current[1]);
    \\    else if (number == 2) { reap(running); schedule(); }
    \\    else if (number == 4) { current[0] = 0; schedule(); }
    \\    else if (number == 5) current[0] = running;
    \\    else if (number == 6) current[0] = spawn(current[1]);
    \\    else if (number == 7) current[0] = faults;
    \\    else if (number == 8) current[0] = alive[current[1] & 3];
    \\    else current[0] = -1;
    \\    return 0;
    \\}
    \\
    \\int main() {
    \\    sys[0] = (int)&trap_entry;
    \\    spawn(0);
    \\    running = 3;
    \\    schedule();
    \\    resume();
    \\    return 0;
    \\}
    \\
;

// What a user program starts with (instead of c_start): the kernel has
// already set sp. When main returns, exit.
const user_start_s =
    \\_start: bl    main
    \\        mov   r0, #2
    \\        swi   0
    \\syscall:
    \\        swi   0
    \\        mov   pc, lr
    \\
;

// A user program's library. Its putchar is a system call: the UART has
// no address here.
const user_lib_c = libc_division ++ libc_strings ++
    \\int putchar(int c) { return syscall(1, c); }
    \\int puts(char *s) { while (*s) putchar(*s++); return 0; }
    \\
++ libc_print_int;

const ta = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Boots the kernel with these user programs (C) in memory. Program 0
/// is started; it can spawn the others by number.
fn bootWith(programs: []const []const u8) !Outcome {
    const kernel = try buildProgram(ta, &.{ vm_c, libc_c }, &.{kernel_s}, 0);
    defer ta.free(kernel);
    try std.testing.expect(kernel.len < 0xf000);
    var board = try Board.init(ta, 0x80000);
    defer board.deinit();
    board.load(0, kernel);
    try board.write(0x1f000, 4, @intCast(programs.len));
    for (programs, 0..) |source, n| {
        const image = try buildProgramWith(ta, user_start_s, &.{ source, user_lib_c }, &.{}, 0x40000000);
        defer ta.free(image);
        try std.testing.expect(image.len <= 0x8000);
        const where: u32 = 0x20000 + 0x8000 * @as(u32, @intCast(n));
        // memory is never clean: whatever was here before is still lying around
        @memset(board.ram[where..][0..0x8000], 0xaa);
        board.load(where, image);
        try board.write(0x1f004 + 8 * @as(u32, @intCast(n)), 4, where);
        try board.write(0x1f008 + 8 * @as(u32, @intCast(n)), 4, @intCast(image.len));
    }
    var m: Machine(Tlb) = .{ .board = &board };
    const result = try m.run(50_000_000);
    return .{ .result = result, .output = try ta.dupe(u8, board.uart_out.items) };
}

test "a program that was linked on its own" {
    const out = try bootWith(&.{
        \\int main() { puts("hello from 0x"); print_int((int)&main >> 28); puts("0000000\n"); return 0; }
    });
    defer ta.free(out.output);
    try expectEqualStrings("hello from 0x40000000\n", out.output);
    // The kernel stops with its count of repaired faults: at least the
    // page with the code and the stack's, and nowhere near the 17 a
    // table can hold.
    try std.testing.expect(out.result >= 2 and out.result <= 6);
}

const counter_c =
    \\int count;
    \\int main() {
    \\    for (int i = 0; i < 3; i++) {
    \\        count++;
    \\        putchar('0' + syscall(5)); putchar(':'); putchar('0' + count); putchar(' ');
    \\        syscall(4);
    \\    }
    \\    return 0;
    \\}
;

test "the same program twice: the same addresses, different memory" {
    const out = try bootWith(&.{
        \\int main() { syscall(6, 1); syscall(6, 1); return 0; }
        ,
        counter_c,
    });
    defer ta.free(out.output);
    try expectEqualStrings("1:1 2:1 1:2 2:2 1:3 2:3 ", out.output);
}

test "pages appear when they are touched, and only then" {
    const out = try bootWith(&.{
        \\char *far = (char *)0x40008000;      /* past the program: fresh pages */
        \\int main() {
        \\    int before = syscall(7);
        \\    far[0] = 'a';                     /* one page */
        \\    far[4095] = 'b';                  /* the same page */
        \\    far[4096 * 3] = 'c';              /* another; the two between are never made */
        \\    int after = syscall(7);
        \\    if (far[1] != 0 || far[4096 * 7 + 4095] != 0) return 1;     /* fresh memory is zeroed */
        \\    putchar(far[0]); putchar(far[4095]); putchar(far[4096 * 3]);
        \\    print_int(after - before);
        \\    return 0;
        \\}
    });
    defer ta.free(out.output);
    try expectEqualStrings("abc2", out.output);
}

test "only the program's own pages come from its image" {
    // The memory after the program's image holds junk (the loader's
    // 0xaa bytes). The last page of the image brings some of it along,
    // after the program's last byte. No page beyond the image may.
    const out = try bootWith(&.{
        \\int main() {
        \\    char *base = (char *)0x40000000;
        \\    int junk = 0;
        \\    for (int page = 0; page < 16; page++) if (base[page * 4096 + 4095] == 0xaa) junk++;
        \\    print_int(junk);
        \\    return 0;
        \\}
    });
    defer ta.free(out.output);
    try expectEqualStrings("1", out.output);
}

test "more pages than the TLB holds: the table remembers" {
    // 234's handler lost a page's contents when its TLB entry was
    // reused. A page table doesn't: twelve pages, each written, then
    // each read back.
    const out = try bootWith(&.{
        \\int *far = (int *)0x40004000;
        \\int main() {
        \\    for (int i = 0; i < 12; i++) far[i * 1024] = 100 + i;
        \\    int sum = 0;
        \\    for (int i = 0; i < 12; i++) sum += far[i * 1024];
        \\    print_int(sum);
        \\    return 0;
        \\}
    });
    defer ta.free(out.output);
    try expectEqualStrings("1266", out.output);
}

test "what a process can't reach kills it, and only it" {
    const out = try bootWith(&.{
        \\int main() {
        \\    for (int which = 1; which <= 4; which++) { syscall(6, which); syscall(4); }
        \\    puts(" init is fine");
        \\    return 0;
        \\}
        ,
        \\int main() { int *kernel = (int *)0x1000; puts("reading the kernel: "); return *kernel; }
        ,
        \\int main() { int *uart = (int *)0x10000000; puts(" writing to the UART: "); *uart = '!'; return 0; }
        ,
        \\int main() { char *beyond = (char *)0x40010000; puts(" one page too far: "); *beyond = 1; return 0; }
        ,
        \\int main() { int *nothing = (int *)0; puts(" a null pointer: "); return *nothing; }
    });
    defer ta.free(out.output);
    try expectEqualStrings("reading the kernel: [segfault 1] writing to the UART: [segfault 1] one page too far: [segfault 1] a null pointer: [segfault 1] init is fine", out.output);
}

const hog_c =
    \\int main() {
    \\    char *base = (char *)0x40000000;
    \\    for (int page = 1; page < 16; page++) base[page * 4096] = 'a' + syscall(5);
    \\    syscall(4);                                  /* let the others have a go */
    \\    for (int page = 1; page < 16; page++) if (base[page * 4096] != 'a' + syscall(5)) return 1;
    \\    putchar('a' + syscall(5));
    \\    return 0;
    \\}
;

test "a dead process's pages are used again" {
    // Memory has 48 pages to give out, and a hog takes all 17 of its
    // table. Ten of them, one after another, only fit if each one's
    // pages come back when it ends.
    const out = try bootWith(&.{
        \\int main() {
        \\    for (int n = 0; n < 10; n++) {
        \\        int child = syscall(6, 1);
        \\        while (syscall(8, child)) syscall(4);     /* wait for it to end */
        \\    }
        \\    puts(" done");
        \\    return 0;
        \\}
        ,
        hog_c,
    });
    defer ta.free(out.output);
    try expectEqualStrings("bbbbbbbbbb done", out.output);
}

test "out of memory: the one that asked dies, the rest go on" {
    // Three hogs at once want 51 pages, and init holds some too. The
    // third runs out part of the way, and what it had goes to the fourth.
    const out = try bootWith(&.{
        \\int main() {
        \\    syscall(6, 1); syscall(6, 1); syscall(6, 1);
        \\    while (syscall(8, 1) || syscall(8, 2)) syscall(4);
        \\    syscall(6, 1);
        \\    return 0;
        \\}
        ,
        hog_c,
    });
    defer ta.free(out.output);
    try expectEqualStrings("[segfault 3]bcb", out.output);
}

test "preempted, switched, flushed, and still right" {
    // Two copies of a program that fills an array and adds it up, at the
    // same virtual addresses, with the timer switching between them.
    const out = try bootWith(&.{
        \\int main() { syscall(6, 1); syscall(6, 1); return 0; }
        ,
        \\int data[600];
        \\int main() {
        \\    int me = syscall(5);
        \\    for (int round = 0; round < 3; round++) {
        \\        for (int i = 0; i < 600; i++) data[i] = i * me;
        \\        int sum = 0;
        \\        for (int i = 0; i < 600; i++) sum += data[i];
        \\        putchar('a' + (sum == 179700 * me));     /* 0 + 1 + ... + 599, times me: 'b' if right */
        \\    }
        \\    return 0;
        \\}
    });
    defer ta.free(out.output);
    try expectEqualStrings("bbbbbb", out.output);
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include machine
//@include tlb
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
