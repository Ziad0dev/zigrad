//
// ─── Exercise 186: UIR, the text format ───────────────────────────────
//
// Chapter 36: UIR. 10-411 is graded on tests that every student writes and
// every compiler must pass, whatever language it's written in. So the
// course fixes one plain-text format for UOp programs, "UIR", and
// tinygrad reads and writes the same format (tinygrad/uop/uir.py, added in
// November 2026 to be "studentgrad compatible"). Week 3's example:
//
//     %buf   = buffer 3 slot=0 dtype=i32
//     %i     = range 3 slot=0
//     %write = store (index %buf %i) %i
//     %done  = end %write %i
//     %test  = assert (after %buf %done) [0 1 2]
//
// One line per UOp: `%name = op srcs key=value`. Srcs come first, then
// args. A value is
//
//     %name               an earlier line
//     7  -3  0x1f  true   a literal (a weak CONST, 181)
//     2.5  1e3  -inf  nan
//     [a b c]             a STACK of values
//     (op srcs args)      a nested UOp, so you don't need a line for it
//     { %x = ...          a scoped block: names made inside it don't leak
//       %y = ... }        out, and its value is its last line
//
// and right after the `=` the op can go without parentheses. The value
// of the whole program is its last line. A # starts a comment.
//
// Parsing builds UOps with the constructors of 182, so everything is
// hash-consed and type-checked as it's read: `add [1 2 3] 4` fails right
// there, with the same message the spec gives.
//
// The parser is recursive descent: one function per kind of thing
// (scope, value, expr), each eating tokens and calling the others. The
// tokenizer is tinygrad's regex, written out by hand.
//
// YOUR TASK: in tokenize(), tell "%x =" from "%x" and spot "key=". In the
// parser, reject a name defined twice, finish value(), and insist that
// srcs come before key=value args.
//
const std = @import("std");

//@export uir_parse
const TokenKind = enum { assign, key, ref, lparen, rparen, lbracket, rbracket, lbrace, rbrace, word };
const Token = struct { kind: TokenKind, text: []const u8 };

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Split UIR text into tokens. Comments are dropped.
fn tokenize(alloc: std.mem.Allocator, text: []const u8) []const Token {
    var out: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (c == '#') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        if (std.mem.indexOfScalar(u8, "()[]{}", c)) |k| {
            const kinds = [_]TokenKind{ .lparen, .rparen, .lbracket, .rbracket, .lbrace, .rbrace };
            out.append(alloc, .{ .kind = kinds[k], .text = text[i .. i + 1] }) catch @panic("out of memory");
            i += 1;
            continue;
        }
        var j = i + 1;
        if (c == '%') {
            while (j < text.len and isWordChar(text[j])) j += 1;
            // "%x =" defines x (spaces before the = are fine); "%x" uses it
            var k = j;
            while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
            if (⟪k < text.len and text[k] == '='|||???⟫) {
                out.append(alloc, .{ .kind = .assign, .text = text[i..j] }) catch @panic("out of memory");
                i = k + 1;
            } else {
                out.append(alloc, .{ .kind = .ref, .text = text[i..j] }) catch @panic("out of memory");
                i = j;
            }
            continue;
        }
        if (isWordChar(c)) {
            while (j < text.len and isWordChar(text[j])) j += 1;
            // "slot=0" is the key "slot", then the word "0"
            if (⟪j < text.len and text[j] == '='|||???⟫) {
                out.append(alloc, .{ .kind = .key, .text = text[i..j] }) catch @panic("out of memory");
                i = j + 1;
                continue;
            }
        }
        // any other word: up to a space, a bracket or a comment (-inf, 1.5e+3, ...)
        while (j < text.len and !std.ascii.isWhitespace(text[j]) and std.mem.indexOfScalar(u8, "()[]{}#", text[j]) == null) j += 1;
        out.append(alloc, .{ .kind = .word, .text = text[i..j] }) catch @panic("out of memory");
        i = j;
    }
    return out.items;
}

/// A literal, or null if `text` isn't one. (tinygrad: _lit)
fn literal(g: *Graph, text: []const u8) ?*const UOp {
    if (std.mem.eql(u8, text, "true")) return g.boolean(true);
    if (std.mem.eql(u8, text, "false")) return g.boolean(false);
    if (std.mem.eql(u8, text, "inf")) return g.float(std.math.inf(f64));
    if (std.mem.eql(u8, text, "-inf")) return g.float(-std.math.inf(f64));
    if (std.mem.eql(u8, text, "nan")) return g.float(std.math.nan(f64));
    if (std.mem.startsWith(u8, text, "0x")) {
        return g.int(std.fmt.parseInt(i64, text[2..], 16) catch return null);
    }
    if (std.fmt.parseInt(i64, text, 10)) |v| return g.int(v) else |_| {}
    const digits_first = text.len > 0 and (std.ascii.isDigit(text[0]) or (text[0] == '-' and text.len > 1 and std.ascii.isDigit(text[1])));
    if (!digits_first) return null;
    return g.float(std.fmt.parseFloat(f64, text) catch return null);
}

/// key=value args. tinygrad has more (name, addrspace, device, ...).
const Args = struct { slot: ?i64 = null, dtype: ?DType = null, op: ?Op = null, pop: ?i64 = null };

const Names = std.StringHashMap(?*const UOp);

const Parser = struct {
    g: *Graph,
    toks: []const Token,
    pos: usize = 0,
    lines: std.ArrayList(*const UOp) = .empty, // the top-level values, in order

    fn peek(p: *Parser) ?Token {
        return if (p.pos < p.toks.len) p.toks[p.pos] else null;
    }
    fn next(p: *Parser, what: []const u8) Error!Token {
        const tok = p.peek() orelse return p.g.fail(what);
        p.pos += 1;
        return tok;
    }
    /// The end of one value's srcs and args.
    fn atEnd(p: *Parser) bool {
        const tok = p.peek() orelse return true;
        return switch (tok.kind) {
            .rparen, .rbracket, .rbrace, .assign => true,
            else => false,
        };
    }

    /// `%name = value` lines, up to `close` or the end of the input. Its
    /// value is the last line's.
    fn scope(p: *Parser, names: *Names, close: ?TokenKind) Error!*const UOp {
        var last: ?*const UOp = null;
        while (p.peek()) |tok| {
            if (close != null and tok.kind == close.?) break;
            if (tok.kind != .assign) return p.g.fail("expected '%name ='");
            p.pos += 1;
            if (⟪names.contains(tok.text)|||???⟫) return p.g.fail("a name can only be defined once");
            names.put(tok.text, null) catch @panic("out of memory"); // can't be used in its own value
            const v = try p.value(names, true);
            names.put(tok.text, v) catch @panic("out of memory");
            last = v;
            if (close == null) p.lines.append(p.g.alloc, v) catch @panic("out of memory");
        }
        if (close) |c| {
            const tok = try p.next("expected '}'");
            if (tok.kind != c) return p.g.fail("expected '}'");
        } else if (p.peek() != null) return p.g.fail("unexpected closing bracket");
        return last orelse p.g.fail("expected an assignment");
    }

    /// One value. Right after a `=` (bare), it can be an op without parentheses.
    fn value(p: *Parser, names: *Names, bare: bool) Error!*const UOp {
        const tok = try p.next("expected a value");
        switch (tok.kind) {
            .lbrace => {
                var inner = names.clone() catch @panic("out of memory");
                return p.scope(&inner, .rbrace);
            },
            .lparen => {
                const op = try p.next("expected an op");
                if (op.kind != .word) return p.g.fail("expected an op");
                return ⟪p.expr(names, op.text, .rparen)|||???⟫;
            },
            .lbracket => {
                var srcs: std.ArrayList(*const UOp) = .empty;
                while (p.peek()) |next_tok| {
                    if (next_tok.kind == .rbracket) break;
                    srcs.append(p.g.alloc, try p.value(names, false)) catch @panic("out of memory");
                }
                const close = try p.next("expected ']'");
                if (close.kind != .rbracket) return p.g.fail("expected ']'");
                return ⟪p.g.stack(srcs.items)|||???⟫;
            },
            .ref => {
                const v = names.get(tok.text) orelse return p.g.fail("that %name is not defined");
                return v orelse p.g.fail("that %name is not defined yet");
            },
            .word => {
                if (literal(p.g, tok.text)) |lit| return lit;
                if (bare) return p.expr(names, tok.text, null);
                if (std.meta.stringToEnum(Op, tok.text) != null) return p.g.fail("an op inside a line needs parentheses: (op ...)");
                return p.g.fail("not a %name or a literal");
            },
            else => return p.g.fail("expected a value"),
        }
    }

    /// `op srcs key=value`, ended by `close` (or by the end of the line).
    fn expr(p: *Parser, names: *Names, name: []const u8, close: ?TokenKind) Error!*const UOp {
        const op = std.meta.stringToEnum(Op, name) orelse return p.g.fail("unknown op");
        if (op == .constant) return p.g.fail("write a literal instead");
        var srcs: std.ArrayList(*const UOp) = .empty;
        while (!p.atEnd() and p.peek().?.kind != .key) {
            srcs.append(p.g.alloc, try p.value(names, false)) catch @panic("out of memory");
        }
        var args: Args = .{};
        while (!p.atEnd()) {
            const key = try p.next("expected key=");
            if (⟪key.kind != .key|||???⟫) return p.g.fail("srcs must come before key=value args");
            const v = try p.next("expected a value after key=");
            try p.setArg(&args, key.text, v.text);
        }
        if (close) |c| {
            const tok = try p.next("expected ')'");
            if (tok.kind != c) return p.g.fail("expected ')'");
        }
        return p.build(op, srcs.items, args);
    }

    fn setArg(p: *Parser, args: *Args, key: []const u8, v: []const u8) Error!void {
        if (std.mem.eql(u8, key, "slot") or std.mem.eql(u8, key, "pop")) {
            const n = std.fmt.parseInt(i64, v, 10) catch return p.g.fail("expected an int");
            const field = if (key[0] == 's') &args.slot else &args.pop;
            if (field.* != null) return p.g.fail("an arg was given twice");
            field.* = n;
        } else if (std.mem.eql(u8, key, "dtype")) {
            if (args.dtype != null) return p.g.fail("an arg was given twice");
            args.dtype = std.meta.stringToEnum(DType, v) orelse return p.g.fail("unknown dtype");
        } else if (std.mem.eql(u8, key, "op")) {
            if (args.op != null) return p.g.fail("an arg was given twice");
            args.op = std.meta.stringToEnum(Op, v) orelse return p.g.fail("unknown op");
        } else return p.g.fail("unknown arg");
    }

    fn build(p: *Parser, op: Op, srcs: []const *const UOp, args: Args) Error!*const UOp {
        const g = p.g;
        const arg: Arg = switch (op) {
            .buffer, .param, .alloc => blk: {
                if (srcs.len != 1) return g.fail("a buffer has one src: its shape");
                const slot = args.slot orelse return g.fail("a buffer needs slot=");
                const dtype = args.dtype orelse return g.fail("a buffer needs dtype=");
                if (args.op != null or args.pop != null) return g.fail("unknown arg");
                break :blk .{ .param = .{ .slot = @intCast(slot), .dtype = dtype } };
            },
            .range => blk: {
                const slot = args.slot orelse return g.fail("a range needs slot=");
                if (args.dtype != null or args.op != null or args.pop != null) return g.fail("unknown arg");
                break :blk .{ .int = slot };
            },
            .reduce => blk: {
                const rop = args.op orelse return g.fail("a reduce needs op=");
                if (args.slot != null or args.dtype != null) return g.fail("unknown arg");
                break :blk .{ .reduce = .{ .op = rop, .pop = @intCast(args.pop orelse 0) } };
            },
            .cast => blk: {
                const dtype = args.dtype orelse return g.fail("a cast needs dtype=");
                if (args.slot != null or args.op != null or args.pop != null) return g.fail("unknown arg");
                break :blk .{ .dtype = dtype };
            },
            else => blk: {
                if (args.slot != null or args.dtype != null or args.op != null or args.pop != null) return g.fail("unknown arg");
                break :blk .none;
            },
        };
        return g.new(op, srcs, arg);
    }
};

/// A whole program: its value is the last line's.
fn parseUir(g: *Graph, text: []const u8) Error!*const UOp {
    var p: Parser = .{ .g = g, .toks = tokenize(g.alloc, text) };
    var names = Names.init(g.alloc);
    return p.scope(&names, null);
}

/// Every top-level line's value, in order (to run all of a file's asserts).
fn parseLines(g: *Graph, text: []const u8) Error![]const *const UOp {
    var p: Parser = .{ .g = g, .toks = tokenize(g.alloc, text) };
    var names = Names.init(g.alloc);
    _ = try p.scope(&names, null);
    return p.lines.items;
}
//@end

const t = std.testing;

test "tokens" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const toks = tokenize(arena.allocator(), "%x = add %y 1.5e+3 slot=0 # gone\n(]");
    const kinds = [_]TokenKind{ .assign, .word, .ref, .word, .key, .word, .lparen, .rbracket };
    try t.expectEqual(kinds.len, toks.len);
    for (kinds, toks) |k, tok| try t.expectEqual(k, tok.kind);
    try t.expectEqualStrings("%x", toks[0].text);
    try t.expectEqualStrings("1.5e+3", toks[3].text);
    try t.expectEqualStrings("slot", toks[4].text);
    // no space before the =
    try t.expectEqual(.assign, tokenize(arena.allocator(), "%x= 1")[0].kind);
}

test "10-411's five weekly examples" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());

    const w1 = try parseUir(&g, "%sum = add 2 3\n%test = assert %sum 5");
    try t.expect(w1 == try g.assertEq(try g.add(g.int(2), g.int(3)), g.int(5)));

    const w2 = try parseLines(&g,
        \\%buf = buffer [] slot=0 dtype=i32
        \\%write = store %buf 7
        \\%ready = after %buf %write
        \\%value = load %ready
        \\%test = assert %value 7
    );
    try t.expectEqual(5, w2.len);
    try t.expect(w2[0] == g.buffer(0, .i32, null));
    try t.expectEqual(.load, w2[3].op);

    const w3 = try parseLines(&g,
        \\%buf = buffer 3 slot=0 dtype=i32
        \\%i = range 3 slot=0
        \\%write = store (index %buf %i) %i
        \\%done = end %write %i
        \\%test = assert (after %buf %done) [0 1 2]
    );
    try t.expect(w3[2] == try g.store(try g.index(w3[0], &.{w3[1]}), w3[1]));
    try t.expectEqualSlices(usize, &.{3}, w3[4].src[1].shape);

    const w4 = try parseUir(&g,
        \\%values = add [1 2 3] (expand 1 3)
        \\%sum = reduce %values op=add pop=1
        \\%test = assert %sum 9
    );
    try t.expectEqual(Reduce{ .op = .add, .pop = 1 }, w4.src[0].arg.reduce);

    const w5 = try parseUir(&g,
        \\%matrix = reshape [1 2 3 4] [2 2]
        \\%transposed = permute %matrix [1 0]
        \\%test = assert (index %transposed 1 0) 2
    );
    try t.expectEqual(.index, w5.src[0].op);
}

test "the gist's matmul header, and tinygrad's studentgrad test" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const gemm = try parseUir(&g,
        \\# gemm_256x256.uir
        \\%0 = buffer 65536 dtype=f32 slot=0
        \\%1 = buffer 65536 dtype=f32 slot=1
        \\%2 = reshape %0 [256 256 1]
    );
    try t.expectEqualSlices(usize, &.{ 256, 256, 1 }, gemm.shape);

    // test_studentgrad_syntax in tinygrad's test/null/test_uir_render.py
    const end = try parseUir(&g,
        \\%buf   = param 4 slot=0 dtype=i32   # comment
        \\%i     = range 4 slot=0
        \\%inc   = { %one = 0x1
        \\           %result = (add (index [10 20 30 40] %i) %one) }
        \\%store = store (index %buf %i) (add %inc (cast 1E2 dtype=i32))
        \\%end   = end %store %i
    );
    const buf = g.param(0, .i32, 4);
    const i = g.range(4, 0);
    const inc = try g.add(try g.index(g.ints(&.{ 10, 20, 30, 40 }), &.{i}), g.int(1));
    const val = try g.add(inc, try g.cast(g.float(100), .i32));
    try t.expect(end == try g.end(try g.store(try g.index(buf, &.{i}), val), &.{i}));
}

test "errors, like tinygrad's" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const bad = [_][]const u8{
        "", //                               no assignment
        "%0 = add %1 1", //                  %1 isn't defined
        "%0 = add 1 2 slot=1 4", //          a src after the args
        "%0 = frob 1", //                    no such op
        "%0 = add 1 nope", //                not a %name or a literal
        "%0 = add 1 (mul 2 3", //            missing )
        "%0 = [1 2", //                      missing ]
        "%0 = add load 1", //                an op inside a line needs ( )
        "%x = 1\n%x = 2", //                 defined twice
        "%x = 1 }", //                       a stray }
        "%x = cast 1 dtpye=i32", //          no such arg
        "%x = cast 1 dtype=i32 dtype=f32", // an arg twice
        "%x = { %x = 1 }", //                defined twice, inside a block
        "%x = add %x 1", //                  used in its own definition
        "%x = add [1 2 3] 4", //             the spec: shapes must match
        "%x = { %y = 1 }\n%z = %y", //       a block's names stay inside it
    };
    for (bad) |text| {
        if (parseUir(&g, text)) |_| {
            std.debug.print("parsed, but shouldn't: {s}\n", .{text});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include dtypes

//@include uop_core

//@include uop_rules
