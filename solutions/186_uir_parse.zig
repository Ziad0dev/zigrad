// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
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
            if (k < text.len and text[k] == '=') {
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
            if (j < text.len and text[j] == '=') {
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
            if (names.contains(tok.text)) return p.g.fail("a name can only be defined once");
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
                return p.expr(names, op.text, .rparen);
            },
            .lbracket => {
                var srcs: std.ArrayList(*const UOp) = .empty;
                while (p.peek()) |next_tok| {
                    if (next_tok.kind == .rbracket) break;
                    srcs.append(p.g.alloc, try p.value(names, false)) catch @panic("out of memory");
                }
                const close = try p.next("expected ']'");
                if (close.kind != .rbracket) return p.g.fail("expected ']'");
                return p.g.stack(srcs.items);
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
            if (key.kind != .key) return p.g.fail("srcs must come before key=value args");
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
                break :blk .{ .param = .{ .slot = std.math.cast(u32, slot) orelse return g.fail("slot= out of range"), .dtype = dtype } };
            },
            .range => blk: {
                const slot = args.slot orelse return g.fail("a range needs slot=");
                if (args.dtype != null or args.op != null or args.pop != null) return g.fail("unknown arg");
                break :blk .{ .int = slot };
            },
            .reduce => blk: {
                const rop = args.op orelse return g.fail("a reduce needs op=");
                if (args.slot != null or args.dtype != null) return g.fail("unknown arg");
                break :blk .{ .reduce = .{ .op = rop, .pop = std.math.cast(u32, args.pop orelse 0) orelse return g.fail("pop= out of range") } };
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
        "%x = add 1", //                     too few srcs
        "%x = where true 1", //              too few srcs
        "%x = add [] 1", //                  [] has no value to add
        "%x = buffer 3 slot=-1 dtype=i32", // a slot can't be negative
        "%x = reduce [1 2] op=add pop=-1", // nor a pop
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

const DType = enum {
    void,
    bool,
    weakint,
    i32,
    weakfloat,
    f32,

    fn isInt(d: DType) bool {
        return d == .weakint or d == .i32;
    }
    fn isFloat(d: DType) bool {
        return d == .weakfloat or d == .f32;
    }
};

/// A literal as written in a program: a bool, an integer or a float.
const Literal = union(enum) { boolean: bool, int: i64, float: f64 };

/// The dtype of a bare literal. tinygrad: the CONST case of dtype_from_uop.
fn literalDType(lit: Literal) DType {
    return switch (lit) {
        .boolean => .bool,
        .int => .weakint,
        .float => .weakfloat,
    };
}

/// Where a type sits on the chain bool -> weakint -> i32 -> weakfloat -> f32.
fn rank(d: DType) u8 {
    return switch (d) {
        .void => unreachable, // void has no value, so it never meets anything
        .bool => 0,
        .weakint => 1,
        .i32 => 2,
        .weakfloat => 3,
        .f32 => 4,
    };
}

/// The least upper bound: the dtype of a + b. tinygrad: least_upper_dtype.
fn lub(a: DType, b: DType) DType {
    return if (rank(a) >= rank(b)) a else b;
}

/// The dtype a value gets when it has to be stored. tinygrad: strong_dtype.
fn commit(d: DType) DType {
    return switch (d) {
        .weakint => .i32,
        .weakfloat => .f32,
        else => d,
    };
}

/// Float-only ops (RECIP, EXP2, ...) need a float. tinygrad: least_upper_float.
fn leastUpperFloat(d: DType) DType {
    if (d == .weakint) return .weakfloat;
    if (d.isFloat()) return d;
    return lub(d, .f32);
}

const Op = enum {
    constant, // a literal; its value is the arg
    param, //    an input of a CALL. arg: slot and dtype. src[0]: its shape
    call, //     src[0] is the body, src[1..] are the arguments
    buffer, //   memory that outlives everything. arg: slot and dtype. src[0]: its shape
    alloc, //    memory that lives inside one call, like C's `float a[10]`
    range, //    a loop counter 0, 1, ..., src[0] - 1. arg: its slot (its name)
    end, //      closes the ranges src[1..] around src[0]
    after, //    src[0], once src[1..] have happened
    stack, //    a new leading axis, made of the srcs
    index, //    pops leading axes off src[0], one per index src
    load,
    store, //    writes src[1] into src[0]
    cast,
    recip,
    add,
    mul,
    max,
    xor,
    shl,
    div, //      floor division, like Python's //
    mod, //      floor modulo, like Python's %
    cmplt,
    cmpne,
    where,
    reshape,
    expand,
    permute,
    pad,
    shrink,
    reduce, //   arg: the op (add, mul or max) and how many leading axes to pop
    stage, //    materializes src[0] over the ranges src[1..]
    sink, //     groups its srcs: the root of a graph, or of a kernel
    assert, //   tests only: src[0] must equal src[1]

    fn isAlu(op: Op) bool {
        return switch (op) {
            .cast, .recip, .add, .mul, .max, .xor, .shl, .div, .mod, .cmplt, .cmpne, .where => true,
            else => false,
        };
    }
    fn isMovement(op: Op) bool {
        return switch (op) {
            .reshape, .expand, .permute, .pad, .shrink => true,
            else => false,
        };
    }
};

const Param = struct { slot: u32, dtype: DType };
const Reduce = struct { op: Op, pop: u32 };

const Arg = union(enum) {
    none,
    int: i64, //       a weakint CONST, or a RANGE's slot
    float: f64, //     a weakfloat CONST
    boolean: bool, //  a bool CONST
    dtype: DType, //   a CAST's target
    param: Param, //   PARAM, BUFFER, ALLOC
    reduce: Reduce, // REDUCE
};

const UOp = struct {
    op: Op,
    src: []const *const UOp,
    arg: Arg,
    dtype: DType,
    shape: []const usize,

    /// A CONST's value as an int (a RANGE's end, a shape argument, ...).
    fn intValue(u: *const UOp) ?i64 {
        if (u.op != .constant) return null;
        return switch (u.arg) {
            .int => |v| v,
            else => null,
        };
    }
};

const Error = error{Spec};

/// What makes two UOps "the same": op, srcs (as pointers) and arg.
const Key = struct { op: Op, src: []const *const UOp, arg: Arg };

fn argBits(a: Arg) u64 {
    return switch (a) {
        .none => 0,
        .int => |v| @bitCast(v),
        .float => |v| @bitCast(v), // by bits: -0.0 and 0.0 are different literals
        .boolean => |v| @intFromBool(v),
        .dtype => |d| @intFromEnum(d),
        .param => |p| @as(u64, p.slot) << 8 | @intFromEnum(p.dtype),
        .reduce => |r| @as(u64, r.pop) << 8 | @intFromEnum(r.op),
    };
}

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&k.op));
        h.update(std.mem.sliceAsBytes(k.src));
        h.update(std.mem.asBytes(&@intFromEnum(std.meta.activeTag(k.arg))));
        h.update(std.mem.asBytes(&argBits(k.arg)));
        return h.final();
    }
    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.op == b.op and std.mem.eql(*const UOp, a.src, b.src) and
            std.meta.activeTag(a.arg) == std.meta.activeTag(b.arg) and argBits(a.arg) == argBits(b.arg);
    }
};

const Graph = struct {
    alloc: std.mem.Allocator, // an arena: UOps live as long as their graph
    cache: std.HashMap(Key, *const UOp, KeyContext, 80),
    why: []const u8 = "", //    why the last UOp couldn't be made

    fn init(alloc: std.mem.Allocator) Graph {
        return .{ .alloc = alloc, .cache = .init(alloc) };
    }

    /// The one way to make a UOp: hash-consed, with dtype and shape worked out.
    fn new(g: *Graph, op: Op, src: []const *const UOp, arg: Arg) Error!*const UOp {
        if (g.cache.get(.{ .op = op, .src = src, .arg = arg })) |u| return u;
        try g.checkSrcs(op, src);
        const dtype = try dtypeOf(g, op, src, arg);
        const shape = try shapeOf(g, op, src, arg);
        const u = g.alloc.create(UOp) catch @panic("out of memory");
        u.* = .{ .op = op, .src = g.alloc.dupe(*const UOp, src) catch @panic("out of memory"), .arg = arg, .dtype = dtype, .shape = shape };
        g.cache.put(.{ .op = op, .src = u.src, .arg = arg }, u) catch @panic("out of memory");
        return u;
    }

    /// The right number of srcs, and no void where a value is needed.
    fn checkSrcs(g: *Graph, op: Op, src: []const *const UOp) Error!void {
        const ok = switch (op) {
            .constant => src.len == 0,
            .param, .buffer, .alloc, .range, .cast, .recip, .load => src.len == 1,
            .add, .mul, .max, .xor, .shl, .div, .mod, .cmplt, .cmpne, .store, .assert, .reshape, .expand, .permute => src.len == 2,
            .where, .pad, .shrink => src.len == 3,
            .index, .after, .end, .stage, .call, .reduce => src.len >= 1,
            .stack, .sink => true,
        };
        if (!ok) return g.fail("wrong number of srcs for this op");
        if (op == .range and (src[0].intValue() orelse -1) < 0) return g.fail("a RANGE's end must be an int literal");
        if (op.isAlu() or (op == .stack and src.len > 0)) {
            for (src) |s| if (s.dtype == .void) return g.fail("a void value can't be used here");
        }
    }

    fn fail(g: *Graph, why: []const u8) Error {
        g.why = why;
        return error.Spec;
    }

    fn cat(g: *Graph, a: []const usize, b: []const usize) []const usize {
        return std.mem.concat(g.alloc, usize, &.{ a, b }) catch @panic("out of memory");
    }

    // ── literals ──
    fn int(g: *Graph, v: i64) *const UOp {
        return g.new(.constant, &.{}, .{ .int = v }) catch unreachable;
    }
    fn float(g: *Graph, v: f64) *const UOp {
        return g.new(.constant, &.{}, .{ .float = v }) catch unreachable;
    }
    fn boolean(g: *Graph, v: bool) *const UOp {
        return g.new(.constant, &.{}, .{ .boolean = v }) catch unreachable;
    }
    /// A list of ints the way tinygrad writes a shape: one int is a CONST,
    /// anything else a STACK of them. (tinygrad: shape_to_shape_arg)
    fn ints(g: *Graph, vs: []const usize) *const UOp {
        if (vs.len == 1) return g.int(@intCast(vs[0]));
        const c = g.alloc.alloc(*const UOp, vs.len) catch @panic("out of memory");
        for (vs, c) |v, *u| u.* = g.int(@intCast(v));
        return g.new(.stack, c, .none) catch unreachable;
    }
    /// Read a shape argument back.
    fn asInts(g: *Graph, u: *const UOp) Error![]const usize {
        if (u.intValue()) |v| {
            const out = g.alloc.alloc(usize, 1) catch @panic("out of memory");
            out[0] = std.math.cast(usize, v) orelse return g.fail("shape arguments can't be negative");
            return out;
        }
        if (u.op != .stack) return g.fail("a shape argument must be a CONST or a STACK of CONSTs");
        const out = g.alloc.alloc(usize, u.src.len) catch @panic("out of memory");
        for (u.src, out) |s, *o| {
            const v = s.intValue() orelse return g.fail("a shape argument must be a CONST or a STACK of CONSTs");
            o.* = std.math.cast(usize, v) orelse return g.fail("shape arguments can't be negative");
        }
        return out;
    }

    // ── memory and loops ──
    fn buffer(g: *Graph, slot: u32, dtype: DType, size: ?usize) *const UOp {
        const shape: []const usize = if (size) |n| &.{n} else &.{};
        return g.new(.buffer, &.{g.ints(shape)}, .{ .param = .{ .slot = slot, .dtype = dtype } }) catch unreachable;
    }
    fn param(g: *Graph, slot: u32, dtype: DType, size: ?usize) *const UOp {
        const shape: []const usize = if (size) |n| &.{n} else &.{};
        return g.new(.param, &.{g.ints(shape)}, .{ .param = .{ .slot = slot, .dtype = dtype } }) catch unreachable;
    }
    fn local(g: *Graph, slot: u32, dtype: DType, size: ?usize) *const UOp {
        const shape: []const usize = if (size) |n| &.{n} else &.{};
        return g.new(.alloc, &.{g.ints(shape)}, .{ .param = .{ .slot = slot, .dtype = dtype } }) catch unreachable;
    }
    fn range(g: *Graph, n: usize, slot: i64) *const UOp {
        return g.new(.range, &.{g.int(@intCast(n))}, .{ .int = slot }) catch unreachable;
    }
    fn index(g: *Graph, x: *const UOp, idx: []const *const UOp) Error!*const UOp {
        return g.new(.index, std.mem.concat(g.alloc, *const UOp, &.{ &.{x}, idx }) catch @panic("out of memory"), .none);
    }
    fn load(g: *Graph, x: *const UOp) Error!*const UOp {
        return g.new(.load, &.{x}, .none);
    }
    fn store(g: *Graph, target: *const UOp, value: *const UOp) Error!*const UOp {
        return g.new(.store, &.{ target, value }, .none);
    }
    fn after(g: *Graph, x: *const UOp, deps: []const *const UOp) Error!*const UOp {
        return g.new(.after, std.mem.concat(g.alloc, *const UOp, &.{ &.{x}, deps }) catch @panic("out of memory"), .none);
    }
    fn end(g: *Graph, x: *const UOp, ranges: []const *const UOp) Error!*const UOp {
        return g.new(.end, std.mem.concat(g.alloc, *const UOp, &.{ &.{x}, ranges }) catch @panic("out of memory"), .none);
    }
    fn stage(g: *Graph, x: *const UOp, ranges: []const *const UOp) Error!*const UOp {
        return g.new(.stage, std.mem.concat(g.alloc, *const UOp, &.{ &.{x}, ranges }) catch @panic("out of memory"), .none);
    }
    fn call(g: *Graph, body: *const UOp, args: []const *const UOp) Error!*const UOp {
        return g.new(.call, std.mem.concat(g.alloc, *const UOp, &.{ &.{body}, args }) catch @panic("out of memory"), .none);
    }
    fn sink(g: *Graph, srcs: []const *const UOp) Error!*const UOp {
        return g.new(.sink, srcs, .none);
    }
    fn assertEq(g: *Graph, a: *const UOp, b: *const UOp) Error!*const UOp {
        return g.new(.assert, &.{ a, b }, .none);
    }

    // ── ALU ──
    fn stack(g: *Graph, srcs: []const *const UOp) Error!*const UOp {
        return g.new(.stack, srcs, .none);
    }
    fn alu(g: *Graph, op: Op, srcs: []const *const UOp) Error!*const UOp {
        return g.new(op, srcs, .none);
    }
    fn add(g: *Graph, a: *const UOp, b: *const UOp) Error!*const UOp {
        return g.new(.add, &.{ a, b }, .none);
    }
    fn mul(g: *Graph, a: *const UOp, b: *const UOp) Error!*const UOp {
        return g.new(.mul, &.{ a, b }, .none);
    }
    fn cmplt(g: *Graph, a: *const UOp, b: *const UOp) Error!*const UOp {
        return g.new(.cmplt, &.{ a, b }, .none);
    }
    fn where(g: *Graph, c: *const UOp, a: *const UOp, b: *const UOp) Error!*const UOp {
        return g.new(.where, &.{ c, a, b }, .none);
    }
    fn cast(g: *Graph, x: *const UOp, dtype: DType) Error!*const UOp {
        return g.new(.cast, &.{x}, .{ .dtype = dtype });
    }

    // ── movement and reduce ──
    fn reshape(g: *Graph, x: *const UOp, shape: []const usize) Error!*const UOp {
        return g.new(.reshape, &.{ x, g.ints(shape) }, .none);
    }
    fn expand(g: *Graph, x: *const UOp, front: []const usize) Error!*const UOp {
        return g.new(.expand, &.{ x, g.ints(front) }, .none);
    }
    fn permute(g: *Graph, x: *const UOp, perm: []const usize) Error!*const UOp {
        return g.new(.permute, &.{ x, g.ints(perm) }, .none);
    }
    fn pad(g: *Graph, x: *const UOp, offsets: []const usize, sizes: []const usize) Error!*const UOp {
        return g.new(.pad, &.{ x, g.ints(offsets), g.ints(sizes) }, .none);
    }
    fn shrink(g: *Graph, x: *const UOp, offsets: []const usize, sizes: []const usize) Error!*const UOp {
        return g.new(.shrink, &.{ x, g.ints(offsets), g.ints(sizes) }, .none);
    }
    fn reduce(g: *Graph, x: *const UOp, op: Op, pop: u32) Error!*const UOp {
        return g.new(.reduce, &.{x}, .{ .reduce = .{ .op = op, .pop = pop } });
    }
};

fn prod(s: []const usize) usize {
    var p: usize = 1;
    for (s) |v| p *= v;
    return p;
}

fn sameShape(a: []const usize, b: []const usize) bool {
    return std.mem.eql(usize, a, b);
}

/// Every UOp that root depends on, and root, with srcs before their users
/// (023). Unless enter_calls, a CALL's body (its src[0]) isn't walked into:
/// the PARAMs in there belong to that call, not to us. (tinygrad: toposort)
fn toposort(g: *Graph, root: *const UOp, enter_calls: bool) []const *const UOp {
    var seen = std.AutoHashMap(*const UOp, void).init(g.alloc);
    var out: std.ArrayList(*const UOp) = .empty;
    visit(g, root, enter_calls, &seen, &out);
    return out.items;
}

fn visit(g: *Graph, u: *const UOp, enter_calls: bool, seen: *std.AutoHashMap(*const UOp, void), out: *std.ArrayList(*const UOp)) void {
    if (seen.contains(u)) return;
    seen.put(u, {}) catch @panic("out of memory");
    for (u.src, 0..) |s, i| {
        if (u.op == .call and i == 0 and !enter_calls) continue;
        visit(g, s, enter_calls, seen, out);
    }
    out.append(g.alloc, u) catch @panic("out of memory");
}

fn shapeOf(g: *Graph, op: Op, src: []const *const UOp, arg: Arg) Error![]const usize {
    switch (op) {
        .constant, .range, .sink, .assert => return &.{},
        .param, .buffer, .alloc => {
            const s = try g.asInts(src[0]);
            if (s.len > 1) return g.fail("buffers are flat: their shape is () or (n,)");
            return s;
        },
        .stack => {
            if (src.len == 0) return &.{};
            for (src[1..]) |s| {
                if (!sameShape(s.shape, src[0].shape)) return g.fail("a STACK's srcs must have the same shape");
            }
            return g.cat(&.{src.len}, src[0].shape);
        },
        .index => {
            const idx = src[1..];
            if (idx.len > src[0].shape.len) return g.fail("INDEX pops more axes than there are");
            var front: []const usize = &.{};
            for (idx) |i| {
                if (!i.dtype.isInt()) return g.fail("indexes must be ints");
                front = g.cat(front, i.shape);
            }
            return g.cat(front, src[0].shape[idx.len..]);
        },
        .add, .mul, .max, .xor, .shl, .div, .mod, .cmplt, .cmpne, .where => {
            for (src[1..]) |s| {
                if (!sameShape(s.shape, src[0].shape)) return g.fail("ALU srcs must have the same shape (EXPAND first)");
            }
            return src[0].shape;
        },
        .cast, .recip, .load, .store, .after, .end, .call => return src[0].shape,
        .reshape => {
            const s = try g.asInts(src[1]);
            if (prod(s) != prod(src[0].shape)) return g.fail("RESHAPE can't change the number of elements");
            return s;
        },
        .expand => return g.cat(try g.asInts(src[1]), src[0].shape),
        .permute => {
            const p = try g.asInts(src[1]);
            const old = src[0].shape;
            if (p.len != old.len) return g.fail("PERMUTE needs one entry per axis");
            const out = g.alloc.alloc(usize, p.len) catch @panic("out of memory");
            for (p, out, 0..) |axis, *o, i| {
                if (axis >= old.len or std.mem.indexOfScalar(usize, p[0..i], axis) != null)
                    return g.fail("PERMUTE needs each axis exactly once");
                o.* = old[axis];
            }
            return out;
        },
        .pad, .shrink => {
            const offsets = try g.asInts(src[1]);
            const sizes = try g.asInts(src[2]);
            const old = src[0].shape;
            if (offsets.len != old.len or sizes.len != old.len) return g.fail("PAD and SHRINK need one offset and size per axis");
            for (old, offsets, sizes) |s, off, size| {
                // PAD puts s elements at off inside size; SHRINK takes size elements from off out of s
                const ok = if (op == .pad) off + s <= size else off + size <= s;
                if (!ok) return g.fail("PAD or SHRINK out of range");
            }
            return sizes;
        },
        .reduce => {
            const pop = arg.reduce.pop;
            if (pop > src[0].shape.len) return g.fail("REDUCE pops more axes than there are");
            return src[0].shape[pop..];
        },
        .stage => {
            var front: []const usize = &.{};
            for (src[1..]) |r| front = g.cat(front, &.{@intCast(r.src[0].intValue().?)});
            return g.cat(front, src[0].shape);
        },
    }
}

fn dtypeOf(g: *Graph, op: Op, src: []const *const UOp, arg: Arg) Error!DType {
    switch (op) {
        .constant => return switch (arg) {
            .int => .weakint,
            .float => .weakfloat,
            .boolean => .bool,
            else => unreachable,
        },
        .param, .buffer, .alloc => return arg.param.dtype,
        .range => return .weakint,
        .cast => return arg.dtype,
        .cmplt, .cmpne => return .bool,
        .where => {
            if (src[0].dtype != .bool) return g.fail("WHERE's condition must be a bool");
            return lub(src[1].dtype, src[2].dtype);
        },
        .shl, .div, .mod => {
            if (!src[0].dtype.isInt() or !src[1].dtype.isInt()) return g.fail("SHL, DIV and MOD are for ints");
            return lub(src[0].dtype, src[1].dtype);
        },
        .xor => {
            if (src[0].dtype.isFloat() or src[1].dtype.isFloat()) return g.fail("XOR is for ints and bools");
            return lub(src[0].dtype, src[1].dtype);
        },
        .add, .mul, .max => return lub(src[0].dtype, src[1].dtype),
        .recip => return leastUpperFloat(src[0].dtype),
        .stack => {
            if (src.len == 0) return .void;
            var d = src[0].dtype;
            for (src[1..]) |x| d = lub(d, x.dtype);
            return d;
        },
        .store, .sink, .assert => return .void,
        .index, .load, .after, .end, .call, .reshape, .expand, .permute, .pad, .shrink, .reduce, .stage => return src[0].dtype,
    }
}
