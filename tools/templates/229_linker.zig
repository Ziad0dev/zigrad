//
// ─── Exercise 229: the linker ─────────────────────────────────────────
//
// So far a program was one file, assembled in one go, by an assembler
// that knew where everything was. Real programs are many files, written
// by different people, compiled one at a time: your main.c calls a
// printf it has never seen. So the compiler and assembler have to be
// able to produce a file with holes in it, and something has to fill
// them. What does a linker do? That.
//
// An *object file* is what the assembler writes when it knows it is not
// seeing the whole program. Ours has three parts:
//
//   code      the bytes, assembled as if the file started at address 0
//   symbols   the labels this file defines, as offsets into the code
//   relocs    the holes: "the word at offset 40 needs the address of
//             printf", for every use the assembler couldn't finish
//
// (ELF, the format of every .o file on Linux, is these three things
// with more bookkeeping around them.)
//
// Which uses can't the assembler finish? 216's assembler now tells us
// how each name was used, and there are only two ways:
//
//   relative   `bl helper`, `b loop`: the instruction holds the DISTANCE
//              to the target. If the target is in the same file, the
//              distance is known now and never changes, wherever the
//              file ends up. Nothing to do! Only a branch to a name
//              from another file is a hole. Its kind: call24.
//   absolute   `.word table`, `ldr r0, =message`: the word holds the
//              target's ADDRESS. That is unknown even for a label in
//              this very file, since the file's own final position
//              isn't decided yet. Always a hole. Its kind: abs32.
//
// The linker then does three things:
//
//   1. PLACE the objects one after another, from a base address.
//   2. Collect every object's symbols into one table: name -> final
//      address, which is where the object was placed plus the offset.
//      A name defined twice is an error, and so is one never defined.
//      Labels starting with `.L` are *local*: the compiler invents them
//      (.L1, .Lstr0) in every file, so they stay private to their file.
//   3. PATCH every hole: an abs32 gets the address; a call24 gets the
//      distance from the instruction to the address, the way 214 encoded
//      a branch.
//
// The result is a program: bytes that run at the base address.
//
// With this exercise the toolchain is complete. The last test compiles
// two C files separately and links them with a start-up file in
// assembly: your compiler, your assembler, your linker, your processor.
//
// YOUR TASK: the three steps of linkObjects().
//
const std = @import("std");

//@export linker
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
        start.* = ⟪alignUp(end, 4)|||???⟫;
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
            try symbols.put(alloc, sym.name, ⟪start + sym.offset|||???⟫);
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
                .abs32 => std.mem.writeInt(u32, word, ⟪target|||???⟫, .little),
                .call24 => {
                    // Keep the instruction's top byte (the condition and
                    // "this is a branch"). The low 24 bits become the
                    // distance in WORDS from pc, and pc reads as the
                    // instruction's address + 8.
                    const insn = std.mem.readInt(u32, word, .little);
                    const distance = ⟪target -% (site +% 8)|||???⟫;
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
//@end

const ta = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const main_s =
    \\main:   str   lr, [sp, #-4]!
    \\        mov   r0, #5
    \\        bl    triple            @ another file's
    \\        ldr   r1, =bonus        @ another file's, by address
    \\        ldr   r1, [r1]
    \\        add   r0, r0, r1
    \\        bl    .Ltwice           @ our own
    \\        ldr   pc, [sp], #4
    \\.Ltwice: add  r0, r0, r0
    \\        mov   pc, lr
;

const lib_s =
    \\        .equ  THREE, 3
    \\triple: ldr   r1, =THREE        @ a number: no hole for this one
    \\        mul   r2, r0, r1
    \\        mov   r0, r2
    \\        b     .Ltwice           @ a different .Ltwice
    \\.Ltwice: mov  pc, lr
    \\bonus:  .word 6
    \\where:  .word bonus, triple     @ absolute, though they are right here
;

test "what the assembler leaves for the linker" {
    var main_o = try assembleObject(ta, main_s, null);
    defer main_o.deinit();
    try expectEqual(@as(usize, 2), main_o.symbols.len);
    try expectEqual(@as(u32, 0), main_o.find("main").?);
    try expectEqual(@as(u32, 32), main_o.find(".Ltwice").?);
    // two holes: the call, and the pool word for =bonus; `bl .Ltwice` needs nothing
    try expectEqual(@as(usize, 2), main_o.relocs.len);
    try expectEqual(RelocKind.call24, main_o.relocs[0].kind);
    try expectEqual(@as(u32, 8), main_o.relocs[0].site);
    try expectEqualStrings("triple", main_o.relocs[0].name);
    try expectEqual(RelocKind.abs32, main_o.relocs[1].kind);
    try expectEqual(@as(u32, 40), main_o.relocs[1].site); // the literal pool, after the code
    try expectEqualStrings("bonus", main_o.relocs[1].name);

    var lib_o = try assembleObject(ta, lib_s, null);
    defer lib_o.deinit();
    try expectEqual(@as(usize, 4), lib_o.symbols.len); // THREE is a number, not a place
    try expect(lib_o.find("THREE") == null);
    try expectEqual(@as(usize, 2), lib_o.relocs.len);
    try expectEqual(RelocKind.abs32, lib_o.relocs[0].kind);
    try expectEqual(@as(u32, 24), lib_o.relocs[0].site);
    try expectEqualStrings("triple", lib_o.relocs[1].name);

    // loading the word at a label from another file can't be patched
    try expectError(error.UndefinedSymbol, assembleObject(ta, " ldr r0, elsewhere", null));
}

test "linking two files, anywhere" {
    var objects = [_]Object{ try assembleObject(ta, c_start, null), try assembleObject(ta, main_s, null), try assembleObject(ta, lib_s, null) };
    defer for (&objects) |*o| o.deinit();

    var image = try linkObjects(ta, &objects, 0, null);
    defer image.deinit(ta);
    try expectEqual(@as(usize, 12 + 44 + 36), image.code.len);
    try expectEqual(@as(u32, 0), image.symbols.get("_start").?);
    try expectEqual(@as(u32, 12), image.symbols.get("main").?);
    try expectEqual(@as(u32, 56), image.symbols.get("triple").?);
    try expectEqual(@as(u32, 76), image.symbols.get("bonus").?);
    try expect(image.symbols.get(".Ltwice") == null);
    const ran = try runImage(ta, image.code, "");
    defer ta.free(ran.output);
    try expectEqual(@as(u32, (5 * 3 + 6) * 2), ran.result);

    // The same objects, linked to live somewhere else. The code that
    // only used distances is the same, byte for byte; the addresses moved.
    var high = try linkObjects(ta, &objects, 0x4000, null);
    defer high.deinit(ta);
    try expectEqual(@as(u32, 0x4000 + 56), high.symbols.get("triple").?);
    const word = struct {
        fn at(im: Image, offset: usize) u32 {
            return std.mem.readInt(u32, im.code[offset..][0..4], .little);
        }
    }.at;
    try expectEqual(word(image, 20), word(high, 20)); // bl triple
    try expectEqual(word(image, 36), word(high, 36)); // bl .Ltwice
    try expectEqual(@as(u32, 76), word(image, 52)); // the pool word: bonus
    try expectEqual(@as(u32, 0x4000 + 76), word(high, 52));
    try expectEqual(@as(u32, 0x4000 + 76), word(high, 80)); // where: bonus,
    try expectEqual(@as(u32, 0x4000 + 56), word(high, 84)); // triple
    // bl triple at 20: 56 is (56 - 28) / 4 = 7 words past pc
    try expectEqual(@as(u32, 0xeb000007), word(image, 20));
}

test "a call backwards, and an object that isn't a multiple of 4 long" {
    var objects = [_]Object{
        try assembleObject(ta, c_start, null),
        try assembleObject(ta, "seven:  mov r0, #7\n mov pc, lr\ntext: .ascii \"abc\"", null),
        try assembleObject(ta, "main:   b seven", null),
    };
    defer for (&objects) |*o| o.deinit();
    var image = try linkObjects(ta, &objects, 0, null);
    defer image.deinit(ta);
    try expectEqual(@as(u32, 24), image.symbols.get("main").?); // 12 + 11, rounded up
    const ran = try runImage(ta, image.code, "");
    defer ta.free(ran.output);
    try expectEqual(@as(u32, 7), ran.result);
}

test "what can go wrong" {
    var objects = [_]Object{
        try assembleObject(ta, "main: bl helper\n", null),
        try assembleObject(ta, "helper: mov pc, lr\n.L1: .word .L1\n", null),
        try assembleObject(ta, "helper: mov pc, lr\n.L1: .word .L1, nowhere\n", null),
    };
    defer for (&objects) |*o| o.deinit();
    var culprit: []const u8 = "";
    try expectError(error.DuplicateSymbol, linkObjects(ta, &objects, 0, &culprit));
    try expectEqualStrings("helper", culprit);
    try expectError(error.UndefinedSymbol, linkObjects(ta, objects[0..1], 0, &culprit));
    try expectEqualStrings("helper", culprit);
    try expectError(error.UndefinedSymbol, linkObjects(ta, &.{ objects[0], objects[2] }, 0, &culprit));
    try expectEqualStrings("nowhere", culprit);
    // each file's .L1 is its own
    var image = try linkObjects(ta, objects[0..2], 0, null);
    defer image.deinit(ta);
}

test "separate compilation: two C files and some assembly" {
    const image = try buildProgram(ta, &.{
        \\int total;
        \\char *label = "sum=";
        \\int add(int n) { total += n; return total; }
        ,
        \\extern char *label;
        \\extern int total;
        \\int main() {
        \\    for (int i = 1; i <= 10; i++) add(i);
        \\    for (int i = 0; label[i]; i++) putc(label[i]);
        \\    putc('0' + total / 10);
        \\    putc('0' + total % 10);
        \\    return total;
        \\}
    }, &.{
        \\putc:   mov   r1, #0x10000000
        \\        str   r0, [r1]
        \\        mov   pc, lr
        \\@ just enough division for two digits: r0 / 10 and r0 % 10
        \\__divsi3:
        \\        mov   r2, #0
        \\.Lmore: cmp   r0, #10
        \\        subge r0, r0, #10
        \\        addge r2, r2, #1
        \\        bge   .Lmore
        \\        mov   r0, r2
        \\        mov   pc, lr
        \\__modsi3:
        \\.Lless: cmp   r0, #10
        \\        subge r0, r0, #10
        \\        bge   .Lless
        \\        mov   pc, lr
    }, 0);
    defer ta.free(image);
    const ran = try runImage(ta, image, "");
    defer ta.free(ran.output);
    try expectEqual(@as(u32, 55), ran.result);
    try expectEqualStrings("sum=55", ran.output);
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
//@include arm_enc
//@include arm_alu
//@include arm_asm_line
//@include arm_asm
//@include arm_emu
