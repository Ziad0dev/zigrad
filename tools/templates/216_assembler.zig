//
// ─── Exercise 216: labels, two passes, and a pool of constants ────────
//
// 215 assembles a line. A program is lines that refer to each other:
//
//         mov   r0, #0
//     loop:
//         add   r0, r0, #1
//         cmp   r0, #10
//         bne   loop            @ backward: the assembler has seen `loop`
//         b     done            @ forward: it hasn't seen `done` yet!
//         ...
//     done:
//
// The forward reference is the one real problem in an assembler, and the
// classic answer is to read the file twice:
//
//   pass 1  walk the file only to learn WHERE everything is. Keep a
//           running address. A label gets the current address. Every
//           instruction adds 4. Nothing is encoded.
//   pass 2  walk it again, encoding. Now every label is known.
//
// Besides instructions, a line can be a *directive*, an order to the
// assembler itself. They start with a dot:
//
//     .word 1, 2, loop      32-bit values (a label's value is its address)
//     .byte 1, 2            8-bit values
//     .ascii "hi"           the bytes of a string;  .asciz adds a 0 after
//     .align 2              pad with zeros to a multiple of 2^2 bytes
//     .balign 4             pad to a multiple of 4 bytes (the same thing)
//     .space 16             16 zero bytes
//     .equ UART, 0x10000000 name a number
//     .ltorg                put the pool here (see below)
//     .global .text .data   accepted and ignored. (To the linker, 229, every
//                           label is global unless its name starts with .L)
//
// Instructions must sit at multiples of 4, so after any .byte or .ascii
// comes an .align.
//
// Last problem: `mov r0, #0x12345678` can't exist (214: 8 bits,
// anywhere). So how does a 32-bit number, or a label's address, get into
// a register? The assembler offers a wish, `ldr r0, =0x12345678`, and
// grants it with a trick: it stores the number as a word nearby, in a
// *literal pool*, and turns the line into a load of that word, relative
// to pc: `ldr r0, [pc, #offset]`. The pool goes wherever .ltorg says (it
// must be somewhere the processor will never try to execute, like after
// a function's return, and within 4095 bytes of its users), and whatever
// is left goes at the end of the file.
//
// YOUR TASK: the address bookkeeping of pass 1, and the pieces of pass 2
// that turn text into bytes.
//
const std = @import("std");

//@export arm_asm
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
    return ⟪(addr + to - 1) & ~(to - 1)|||???⟫;
}

/// How many comma-separated things follow. (The comma in ',' is a
/// character, not a separator.)
fn countItems(sc: *Scanner) u32 {
    const rest = sc.text[sc.at..];
    var count: u32 = 1;
    for (rest, 0..) |c, i| {
        const quoted = i > 0 and i + 1 < rest.len and rest[i - 1] == '\'' and rest[i + 1] == '\'';
        if (c == ',' and !quoted) count += 1;
    }
    return count;
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
            try lay.syms.map.put(alloc, l.name, ⟪addr|||???⟫);
            text = l.rest;
        }
        if (text.len == 0) continue;
        var sc: Scanner = .{ .text = text };
        const first = sc.word();
        if (first.len == 0 or first[0] != '.') {
            // an instruction
            if (takeLiteral(text) != null) waiting += 1;
            addr += ⟪4|||???⟫;
            continue;
        }
        switch (parseDirective(first) orelse return error.UnknownDirective) {
            .word => addr += ⟪4 * countItems(&sc)|||???⟫,
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
        try lay.literals.append(alloc, ⟪at|||???⟫);
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
    std.mem.writeInt(u32, &bytes, value, ⟪.little|||???⟫);
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
                const pool_word = lay.literals.items[⟪wishes.items.len|||???⟫];
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
//@end

const ta = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

test "comments, labels and alignment" {
    try std.testing.expectEqualStrings("mov r0, #1 ", stripComment("mov r0, #1 @ one"));
    try std.testing.expectEqualStrings("add r0, r0, r1 ", stripComment("add r0, r0, r1 // sum"));
    try std.testing.expectEqualStrings(".ascii \"a@b//c\" ", stripComment(".ascii \"a@b//c\" @ real comment"));
    try std.testing.expectEqualStrings("cmp r0, #'@'", stripComment("cmp r0, #'@'"));
    try std.testing.expectEqualStrings("loop", takeLabel("loop: add r0, r0, #1").?.name);
    try std.testing.expectEqualStrings("add r0, r0, #1", takeLabel("loop: add r0, r0, #1").?.rest);
    try std.testing.expect(takeLabel("add r0, r0, #1") == null);
    try expectEqual(@as(u32, 8), alignUp(5, 4));
    try expectEqual(@as(u32, 8), alignUp(8, 4));
    try expectEqual(@as(u32, 12), alignUp(9, 4));
    try expectEqual(@as(u32, 0), alignUp(0, 4));
    try expectEqual(@as(u32, 16), alignUp(9, 16));
}

const count_to_ten =
    \\        mov   r0, #0
    \\loop:
    \\        add   r0, r0, #1
    \\        cmp   r0, #10
    \\        bne   loop            @ backward
    \\        b     done            @ forward
    \\        mvn   r0, #0          @ never runs
    \\done:   swi   0
;

test "forward and backward branches" {
    var prog = try assemble(ta, count_to_ten, 0x8000, null);
    defer prog.deinit(ta);
    try expectEqual(@as(usize, 7 * 4), prog.code.len);
    try expectEqual(@as(u32, 0x8004), try prog.syms.get("loop"));
    try expectEqual(@as(u32, 0x8018), try prog.syms.get("done"));
    try expectEqual(@as(u32, 0xe3a00000), prog.word(0x8000));
    try expectEqual(@as(u32, 0x1afffffc), prog.word(0x800c)); // bne loop: back 4 words from pc
    try expectEqual(@as(u32, 0xea000000), prog.word(0x8010)); // b done: pc + 8 is already `done`
    try expectEqual(@as(u32, 0xef000000), prog.word(0x8018));
    // little-endian: the low byte of mov r0, #0 comes first
    try expectEqual(@as(u8, 0x00), prog.code[0]);
    try expectEqual(@as(u8, 0xe3), prog.code[3]);
}

test "data, strings and the literal pool" {
    const source =
        \\        .equ  UART, 0x10000000
        \\start:  ldr   r1, =UART       @ a number that fits no mov
        \\        ldr   r2, =message    @ a label's address
        \\        ldrb  r0, [r2]
        \\        str   r0, [r1]
        \\        mov   pc, lr
        \\        .ltorg
        \\message:
        \\        .asciz "hi\n"
        \\        .byte 1, 2
        \\        .align 2
        \\table:  .word 7, -1, start, table
        \\        ldr   r3, =0xdeadbeef   @ this one's pool goes at the end
    ;
    var prog = try assemble(ta, source, 0x100, null);
    defer prog.deinit(ta);
    // five instructions, then the pool: two words
    try expectEqual(@as(u32, 0xe59f100c), prog.word(0x100)); // ldr r1, [pc, #12]: 0x108 + 12 = 0x114
    try expectEqual(@as(u32, 0xe59f200c), prog.word(0x104)); // ldr r2, [pc, #12]: 0x118
    try expectEqual(@as(u32, 0x10000000), prog.word(0x114));
    try expectEqual(@as(u32, 0x11c), prog.word(0x118));
    try expectEqual(@as(u32, 0x11c), try prog.syms.get("message"));
    try std.testing.expectEqualSlices(u8, "hi\n\x00\x01\x02\x00\x00", prog.code[0x1c..0x24]);
    try expectEqual(@as(u32, 0x124), try prog.syms.get("table"));
    try expectEqual(@as(u32, 7), prog.word(0x124));
    try expectEqual(@as(u32, 0xffffffff), prog.word(0x128));
    try expectEqual(@as(u32, 0x100), prog.word(0x12c));
    try expectEqual(@as(u32, 0x124), prog.word(0x130));
    try expectEqual(@as(u32, 0xe51f3004), prog.word(0x134)); // ldr r3, [pc, #-4]: the very next word
    try expectEqual(@as(u32, 0xdeadbeef), prog.word(0x138));
    try expectEqual(@as(usize, 0x3c), prog.code.len);
}

test "mistakes come with a line number" {
    var line: usize = 0;
    try expectError(error.UndefinedSymbol, assemble(ta, "mov r0, #1\n\nb nowhere\n", 0, &line));
    try expectEqual(@as(usize, 3), line);
    try expectError(error.DuplicateLabel, assemble(ta, "a: mov r0, #1\na: mov r0, #2", 0, &line));
    try expectEqual(@as(usize, 2), line);
    try expectError(error.UnknownDirective, assemble(ta, ".wrod 1", 0, &line));
    try expectError(error.ImmediateDoesNotFit, assemble(ta, "mov r0, #1\nmov r0, #257", 0, &line));
    try expectEqual(@as(usize, 2), line);
    try expectError(error.BadOperand, assemble(ta, ".word 1 2", 0, &line));
}

test "a comma that is a character, not a separator" {
    var line: usize = 0;
    var prog = try assemble(ta,
        \\        .byte ',', 'a', ','
        \\after:  .byte 1
        \\        .word ',', after
    , 0x100, &line);
    defer prog.deinit(ta);
    try expectEqual(@as(usize, 12), prog.code.len);
    try expectEqual(@as(u32, 0x012c612c), prog.word(0x100));
    try expectEqual(@as(u32, ','), prog.word(0x104));
    try expectEqual(@as(u32, 0x103), prog.word(0x108));
}

test "the judge: a whole file, byte for byte" {
    const source =
        \\        .text
        \\        .global _start
        \\_start: mov   r0, #0
        \\        ldr   r4, =numbers
        \\        mov   r5, #5
        \\sum:    ldr   r1, [r4], #4
        \\        add   r0, r0, r1
        \\        subs  r5, r5, #1
        \\        bne   sum
        \\        bl    double
        \\        ldr   r6, =0x12345678
        \\        ldr   r7, =text
        \\        ldrb  r8, [r7, #1]
        \\halt:   b     halt
        \\double: add   r0, r0, r0
        \\        mov   pc, lr
        \\        .ltorg
        \\numbers:
        \\        .word 1, 2, 3, 4, 0x7fffffff
        \\text:   .ascii "ab"
        \\        .asciz "c\n"
        \\        .byte 0xff
        \\        .align 2
        \\after:  ldr   r9, =after
        \\        ldr   r10, text
        \\        strb  r0, [r1, #-1]!
        \\        .space 3
        \\        .balign 4
        \\        .word after, _start
    ;
    var prog = try assemble(ta, source, 0, null);
    defer prog.deinit(ta);
    const judged = try llvmAssemble(ta, source);
    defer ta.free(judged);
    // One word differs, and it is worth a look: the call, `bl double`, at
    // 0x1c. We know where `double` is, so we encode the distance. LLVM
    // knows too, and still leaves the distance blank (-2 words: "to
    // myself") with a note in the object file asking the LINKER to fill
    // it in, because a linker may want to reroute a call. Notes like
    // that are called relocations, and they are exercise 229.
    try expectEqual(@as(u32, 0xeb000003), prog.word(0x1c));
    try expectEqual(@as(u32, 0xebfffffe), std.mem.readInt(u32, judged[0x1c..][0..4], .little));
    try std.testing.expectEqualSlices(u8, judged[0..0x1c], prog.code[0..0x1c]);
    try std.testing.expectEqualSlices(u8, judged[0x20..], prog.code[0x20..]);
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include arm_enc
//@include arm_asm_line
//@include llvm_as
