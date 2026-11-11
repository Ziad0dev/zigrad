//
// ─── Exercise 215: an assembler, one line at a time ───────────────────
//
// Nobody writes 0xe0921183. They write
//
//     adds r1, r2, r3, lsl #3
//
// and a program, the *assembler*, does 214's bit-packing. It is the
// simplest translator there is: one line in, one word out, no decisions.
// (George Hotz's outline calls it "straightforward and boring". It is
// also how you learn the instruction set, which is the point.)
//
// A line is a *mnemonic* and its *operands*.
//
// The mnemonic is a base name, then an optional `s` ("set the flags"),
// then an optional condition:
//
//     add      adds      addeq      addseq
//     b        bne       bl         bleq
//
// Read `bls` carefully: is it "bl" + "s", or "b" + "ls"? Branches never
// set flags, so only the second makes sense, and that rule is enough to
// make every mnemonic unambiguous: try each base name that the text
// starts with, and accept the first whose leftovers parse completely.
//
// The operands, by kind of instruction:
//
//     mov  rd, <op2>             and mvn
//     cmp  rn, <op2>             and cmn, tst, teq: flags only, S is implied
//     add  rd, rn, <op2>         and every other data-processing op
//     mul  rd, rm, rs
//     ldr  rd, <address>         and str, ldrb, strb
//     b    label                 and bl
//     swi  number
//
//     <op2>:      #constant  |  rm  |  rm, lsl #n  |  rm, lsl rs
//     <address>:  [rn]            the word at address rn
//                 [rn, #n]        ...at rn + n         (rn is unchanged)
//                 [rn, #n]!       ...at rn + n, and rn becomes rn + n
//                 [rn], #n        ...at rn, and THEN rn becomes rn + n
//                 [rn, rm]  [rn, -rm]  [rn, rm, lsl #n]   a register offset
//                 label           the word AT the label, found relative to pc
//
// The two forms that change rn are the stack. This part's processor has
// no push and pop instructions (real ARM does, as "load/store multiple";
// we leave those out), and doesn't need them:
//
//     str r0, [sp, #-4]!     push: move sp down a word, store there
//     ldr r0, [sp], #4       pop:  load from sp, then move sp up
//
// YOUR TASK: the mnemonic's suffixes, the two kinds of operand 2 without
// a shift, and the addressing modes.
//
const std = @import("std");

//@export arm_asm_line
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
        const may_set_flags = ⟪m.kind == .data or m.kind == .mul|||???⟫;
        if (may_set_flags and rest.len > 0 and rest[0] == 's') {
            m.s = true;
            rest = rest[1..];
        }
        if (rest.len > 0) {
            // Whatever is left must be a condition. If it isn't, this
            // base name was the wrong guess: try the next one.
            m.cond = ⟪parseCond(rest) orelse continue|||???⟫;
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
    if (!sc.eat(',')) return ⟪shiftedReg(rm, .lsl, 0)|||???⟫; // a plain register is "shifted left by 0"
    const kind = std.meta.stringToEnum(Shift, sc.word()) orelse return error.BadShift;
    if (sc.eat('#')) return shiftedReg(rm, kind, try shiftAmount(kind, try sc.number()));
    return shiftedByReg(rm, kind, try sc.reg());
}

fn parseOperand2(sc: *Scanner) !Operand2 {
    if (sc.eat('#')) {
        const v = try sc.number();
        return .{ .imm = true, .bits = ⟪encodeImm(v) orelse return error.ImmediateDoesNotFit|||???⟫ };
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
        return encodeOffset(cond, m, .{ .imm = @bitCast(⟪target -% (addr +% 8)|||???⟫) });
    }
    m.rn = try sc.reg();
    if (sc.eat(']')) {
        if (!sc.eat(',')) return memImm(cond, m, 0); // [rn]
        // [rn], offset: use rn as it is, then add the offset to it
        m.pre = ⟪false|||???⟫;
        return encodeOffset(cond, m, try parseOffset(sc));
    }
    // [rn, offset] or [rn, offset]!
    try sc.need(',');
    const offset = try parseOffset(sc);
    try sc.need(']');
    m.writeback = ⟪sc.eat('!')|||???⟫;
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
//@end

//@export llvm_as
/// The same source through a real assembler, LLVM's (inside `zig cc`), as
/// the bytes of the finished code. This is the judge.
fn llvmAssemble(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.s", .data = source });
    var dir_buf: [4096]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const s_path = try std.fs.path.join(alloc, &.{ dir, "a.s" });
    const o_path = try std.fs.path.join(alloc, &.{ dir, "a.o" });
    const bin_path = try std.fs.path.join(alloc, &.{ dir, "a.bin" });
    const steps = [_][]const []const u8{
        &.{ "zig", "cc", "-target", "arm-freestanding-eabi", "-mcpu=arm7tdmi", "-c", s_path, "-o", o_path },
        &.{ "zig", "objcopy", "-O", "binary", o_path, bin_path },
    };
    for (steps) |argv| {
        const result = try std.process.run(alloc, io, .{ .argv = argv });
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("{s} {s} failed:\n{s}\n", .{ argv[0], argv[1], result.stderr });
            return error.LlvmFailed;
        }
    }
    return tmp.dir.readFileAlloc(io, "a.bin", gpa, .limited(1 << 20));
}
//@end

const ta = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

fn one(line: []const u8) !u32 {
    var syms: Symbols = .{};
    return encodeLine(line, 0, &syms);
}

fn expectWord(want: u32, line: []const u8) !void {
    const got = try one(line);
    if (want != got) {
        std.debug.print("{s}: want 0x{x:0>8}, got 0x{x:0>8}\n", .{ line, want, got });
        return error.TestExpectedEqual;
    }
}

test "mnemonics: base, s, condition" {
    const add = parseMnemonic("add").?;
    try std.testing.expect(add.kind.data == .add and !add.s and add.cond == .al);
    const subsne = parseMnemonic("subsne").?;
    try std.testing.expect(subsne.kind.data == .sub and subsne.s and subsne.cond == .ne);
    // b + ls, not bl + s
    const bls = parseMnemonic("bls").?;
    try std.testing.expect(!bls.kind.branch.link and bls.cond == .ls and !bls.s);
    const bleq = parseMnemonic("bleq").?;
    try std.testing.expect(bleq.kind.branch.link and bleq.cond == .eq);
    const ble = parseMnemonic("ble").?;
    try std.testing.expect(!ble.kind.branch.link and ble.cond == .le);
    try std.testing.expect(parseMnemonic("bl").?.kind.branch.link);
    try std.testing.expect(parseMnemonic("bics").?.s);
    try std.testing.expect(parseMnemonic("muls").?.s);
    try std.testing.expect(parseMnemonic("movcs").?.cond == .cs);
    try std.testing.expect(parseMnemonic("movhs").?.cond == .cs);
    try std.testing.expect(parseMnemonic("teq").?.kind.data == .teq);
    try std.testing.expect(parseMnemonic("ldrbeq").?.kind.mem.byte);
    try std.testing.expect(parseMnemonic("addx") == null);
    try std.testing.expect(parseMnemonic("strs") == null); // a store can't set flags
    try std.testing.expect(parseMnemonic("bs") == null);
    try std.testing.expect(parseMnemonic("nop") == null);
}

test "data processing lines" {
    try expectWord(0xe3a00001, "mov r0, #1");
    try expectWord(0xe3a01cff, "mov r1, #0xff00");
    try expectWord(0xe3e03000, "mvn r3, #0");
    try expectWord(0xe0810002, "add r0, r1, r2");
    try expectWord(0xe0921183, "adds r1, r2, r3, lsl #3");
    try expectWord(0xe0454756, "sub r4, r5, r6, asr r7");
    try expectWord(0xe350000a, "cmp r0, #10");
    try expectWord(0xe2700000, "rsbs r0, r0, #0");
    try expectWord(0x02800001, "addeq r0, r0, #1");
    try expectWord(0xe1a0f00e, "mov pc, lr");
    try expectWord(0xe1a00461, "mov r0, r1, ror #8");
    try expectWord(0xe1a00021, "mov r0, r1, lsr #32");
    try expectWord(0xe3110102, "tst r1, #0x80000000");
    try expectWord(0xe3500061, "cmp r0, #'a'");
    try expectWord(0xe0000291, "mul r0, r1, r2");
    try expectWord(0xef123456, "swi 0x123456");
    try expectError(error.ImmediateDoesNotFit, one("mov r0, #0x101"));
    try expectError(error.UnknownMnemonic, one("jmp r0"));
    try expectError(error.BadRegister, one("mov r16, #1"));
    try expectError(error.BadOperand, one("mov r0, #1, r2"));
    try expectError(error.BadShift, one("mov r0, r1, lsl #32"));
    try expectError(error.BadShift, one("mov r0, r1, lsr #0"));
}

test "addressing modes" {
    try expectWord(0xe5910000, "ldr r0, [r1]");
    try expectWord(0xe5910004, "ldr r0, [r1, #4]");
    try expectWord(0xe5110004, "ldr r0, [r1, #-4]");
    try expectWord(0xe52d0004, "str r0, [sp, #-4]!"); // push
    try expectWord(0xe49d0004, "ldr r0, [sp], #4"); // pop
    try expectWord(0xe7d32004, "ldrb r2, [r3, r4]");
    try expectWord(0xe5c32001, "strb r2, [r3, #1]");
    try expectWord(0xe7910102, "ldr r0, [r1, r2, lsl #2]");
    try expectWord(0xe7021003, "str r1, [r2, -r3]");
    try expectWord(0xe6910002, "ldr r0, [r1], r2");
    try expectWord(0xe7b10002, "ldr r0, [r1, r2]!");
    try expectError(error.OffsetTooFar, one("ldr r0, [r1, #4096]"));
    try expectError(error.BadOperand, one("ldr r0, [r1, #4"));
}

test "labels" {
    var syms: Symbols = .{};
    defer syms.map.deinit(ta);
    try syms.map.put(ta, "loop", 0x54);
    try syms.map.put(ta, "table", 0x70);
    try expectEqual(@as(u32, 0xeafffffe), try encodeLine("b loop", 0x54, &syms));
    try expectEqual(@as(u32, 0x1affffff), try encodeLine("bne loop", 0x50, &syms));
    try expectEqual(@as(u32, 0xebfffff9), try encodeLine("bl loop", 0x68, &syms));
    // the word at `table`, from 0x60: pc reads as 0x68, so [pc, #8]
    try expectEqual(@as(u32, 0xe59f5008), try encodeLine("ldr r5, table", 0x60, &syms));
    try expectEqual(@as(u32, 0xe51f5010), try encodeLine("ldr r5, table", 0x78, &syms)); // [pc, #-16]
    try expectError(error.UndefinedSymbol, encodeLine("b nowhere", 0, &syms));
    try std.testing.expectEqualStrings("nowhere", syms.missing);
}

test "the judge: LLVM's assembler agrees, word for word" {
    const lines = [_][]const u8{
        "mov r0, #1",                "mov r2, #0x3fc",         "orr r0, r0, #0xf000000f", "bic r0, r0, #0xff",
        "adds r1, r2, r3, lsl #3",   "sub r4, r5, r6, asr r7", "rsc r1, r2, r3, ror r4",  "subsne r1, r1, r2",
        "andseq r9, r10, r11",       "eor r0, r0, r0, lsr #1", "adc r12, r12, #0",        "sbcs r0, r1, r2",
        "cmn r0, #1",                "teq r1, r2, lsl #4",     "mvnlt r0, r1",            "movhs r0, #0",
        "mulgt r0, r1, r2",          "muls r3, r4, r5",        "ldrb r2, [r3, r4]",       "strbne r2, [r3, #1]",
        "ldr r0, [r1, r2, lsl #2]",  "str r1, [r2, -r3]",      "str r0, [sp, #-4]!",      "ldr r0, [sp], #4",
        "ldr r0, [r1, -r2, asr #3]", "strb r0, [r1], #-1",     "ldrmi r0, [fp, #-8]",     "str lr, [sp, #-4]!",
        "ldr pc, [sp], #4",          "swi 17",                 "svcvs 0xbeef",            "mov r0, r1, asr #32",
    };
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(ta);
    for (lines) |line| {
        try source.appendSlice(ta, line);
        try source.append(ta, '\n');
    }
    const judged = try llvmAssemble(ta, source.items);
    defer ta.free(judged);
    try expectEqual(lines.len * 4, judged.len);
    for (lines, 0..) |line, i| {
        try expectWord(std.mem.readInt(u32, judged[4 * i ..][0..4], .little), line);
    }
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include arm_enc
