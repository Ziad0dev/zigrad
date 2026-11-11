// HARD MODE (zig build -Dhard): no blanks to fill in. Every function
// marked ??? has lost its whole body: write it, from its doc comment,
// its signature and the tests. The gentler version of this file is in
// exercises/, and the answer in solutions/.
//
// ─── Exercise 225: expressions, as a tree ─────────────────────────────
//
// The tokens  1 + 2 * 3  are flat. Their meaning is not: the
// multiplication happens first. The parser's job is to find the shape
// that the flat text only implies, and say it out loud as a tree:
//
//         +                  written here as   (+ 1 (* 2 3))
//        / \
//       1   *                Each operator is a node; what it works on
//          / \               hangs below it. Once the tree exists, no
//         2   3              later stage needs to know about precedence.
//
// The method is *recursive descent*: one function per kind of thing, and
// each function calls the ones for the things it is made of.
//
//     primary   42   "text"   name   name(args)   (expression)
//     postfix   a primary, then any number of [index] or ++ or --
//     unary     - ~ ! * & ++ --  in front of a unary, or (type) in front
//               of one (a cast), or else a postfix
//     binary    unaries with * / % + - << >> < <= > >= == != & ^ | && ||
//               between them
//     assign    a binary, and then maybe = or += or -= and an ASSIGN
//
// Two of those lines hide the two classic decisions.
//
// PRECEDENCE AND ASSOCIATIVITY. Every binary operator has a strength.
// parseBinary(min) reads a unary, then keeps taking operators as long as
// they are at least `min` strong. For each, it reads the right-hand side
// with a call to itself, and what it passes as the new minimum decides
// how equals group:
//
//     a - b - c    must be (a - b) - c: the right side of the first `-`
//                  must NOT swallow the second one. So the right side
//                  only takes operators STRONGER than this one.
//
// That is called precedence climbing, and one loop of it replaces the
// ten nearly identical functions (one per level) of a textbook parser.
//
// Assignment groups the other way. a = b = c is a = (b = c), which falls
// out by itself if the right-hand side of `=` is parsed by parseAssign.
//
// SUGAR. Some syntax is only a nicer spelling of other syntax, and the
// parser can translate it away at once, so nothing later ever sees it:
//
//     a += b    is    a = a + b
//     ++a       is    a = a + 1
//     a++       is    (a = a + 1) - 1     the old value, as C wants
//
// (C says `a` is worked out once in `a += b`. Here it is worked out
// twice, which only matters if working it out has side effects.)
//
// This parser is shared by the next three exercises. It already knows
// about *types* and *local variables*, which 226 will fill in. Here,
// every name is a global.
//
// YOUR TASK: the pieces of CParser marked below.
//
const std = @import("std");

const CType = union(enum) {
    int,
    char,
    void,
    ptr: *const CType,
    array: struct { elem: *const CType, len: u32 },
};

const CUnary = enum { neg, not, lnot };

const CBinary = enum { mul, div, mod, add, sub, shl, shr, lt, le, gt, ge, eq, ne, bit_and, bit_xor, bit_or, log_and, log_or };

const CExpr = union(enum) {
    num: u32,
    /// The text between the quotes, escapes and all.
    str: []const u8,
    /// A variable of the function: its number in the function's list.
    local: u32,
    /// Any other name: a global variable, or a function.
    global: []const u8,
    unary: struct { op: CUnary, arg: *CExpr },
    /// *p. `byte` is for 228: read one byte there, and not a word.
    deref: struct { arg: *CExpr, byte: bool = false },
    /// &x
    addr: *CExpr,
    binary: struct { op: CBinary, lhs: *CExpr, rhs: *CExpr },
    assign: struct { target: *CExpr, value: *CExpr },
    call: struct { name: []const u8, args: []*CExpr },
    /// a[i]
    index: struct { base: *CExpr, at: *CExpr },
    cast: struct { to: CType, arg: *CExpr },
};

const CVar = struct { name: []const u8, type: CType };

const CBinaryInfo = struct { text: []const u8, op: CBinary, strength: u8 };

/// The binary operators, weakest first. Equal strength: same line in C's
/// precedence table.
const c_binary_ops = [_]CBinaryInfo{
    .{ .text = "||", .op = .log_or, .strength = 1 },
    .{ .text = "&&", .op = .log_and, .strength = 2 },
    .{ .text = "|", .op = .bit_or, .strength = 3 },
    .{ .text = "^", .op = .bit_xor, .strength = 4 },
    .{ .text = "&", .op = .bit_and, .strength = 5 },
    .{ .text = "==", .op = .eq, .strength = 6 },
    .{ .text = "!=", .op = .ne, .strength = 6 },
    .{ .text = "<", .op = .lt, .strength = 7 },
    .{ .text = "<=", .op = .le, .strength = 7 },
    .{ .text = ">", .op = .gt, .strength = 7 },
    .{ .text = ">=", .op = .ge, .strength = 7 },
    .{ .text = "<<", .op = .shl, .strength = 8 },
    .{ .text = ">>", .op = .shr, .strength = 8 },
    .{ .text = "+", .op = .add, .strength = 9 },
    .{ .text = "-", .op = .sub, .strength = 9 },
    .{ .text = "*", .op = .mul, .strength = 10 },
    .{ .text = "/", .op = .div, .strength = 10 },
    .{ .text = "%", .op = .mod, .strength = 10 },
};

const CParser = struct {
    toks: []const CToken,
    at: usize = 0,
    /// Every node of the tree is allocated here. Use an arena, and free
    /// the whole tree at once.
    alloc: std.mem.Allocator,
    /// The variables of the function being parsed (226).
    locals: std.ArrayList(CVar) = .empty,
    /// The variables whose names can be seen right now, as numbers in
    /// `locals`. The ones declared last are at the end.
    scope: std.ArrayList(u32) = .empty,
    /// Where in `scope` the block being parsed began (226).
    block_start: usize = 0,

    fn peek(p: *const CParser) CToken {
        return p.toks[p.at];
    }

    fn next(p: *CParser) CToken {
        const tok = p.toks[p.at];
        if (tok.kind != .eof) p.at += 1;
        return tok;
    }

    /// Is the next token this punctuation or keyword?
    fn sees(p: *const CParser, text: []const u8) bool {
        const tok = p.peek();
        return (tok.kind == .punct or tok.kind == .keyword) and std.mem.eql(u8, tok.text, text);
    }

    /// Takes the next token if it is this punctuation or keyword.
    fn eat(p: *CParser, text: []const u8) bool {
        if (!p.sees(text)) return false;
        p.at += 1;
        return true;
    }

    fn expect(p: *CParser, text: []const u8) !void {
        if (!p.eat(text)) return error.SyntaxError;
    }

    /// After an error: the line of the token the parser stopped at.
    fn line(p: *const CParser) u32 {
        return p.peek().line;
    }

    fn new(p: *CParser, e: CExpr) !*CExpr {
        const node = try p.alloc.create(CExpr);
        node.* = e;
        return node;
    }

    /// A copy of a whole tree. The sugar needs it: in a = a + b the two
    /// `a`s must be two trees, because 228 will rewrite trees in place.
    fn clone(p: *CParser, e: *const CExpr) !*CExpr {
        return p.new(switch (e.*) {
            .num, .str, .local, .global => e.*,
            .unary => |u| .{ .unary = .{ .op = u.op, .arg = try p.clone(u.arg) } },
            .deref => |d| .{ .deref = .{ .arg = try p.clone(d.arg), .byte = d.byte } },
            .addr => |a| .{ .addr = try p.clone(a) },
            .binary => |b| .{ .binary = .{ .op = b.op, .lhs = try p.clone(b.lhs), .rhs = try p.clone(b.rhs) } },
            .assign => |a| .{ .assign = .{ .target = try p.clone(a.target), .value = try p.clone(a.value) } },
            .call => |c| blk: {
                const args = try p.alloc.alloc(*CExpr, c.args.len);
                for (args, c.args) |*to, from| to.* = try p.clone(from);
                break :blk .{ .call = .{ .name = c.name, .args = args } };
            },
            .index => |x| .{ .index = .{ .base = try p.clone(x.base), .at = try p.clone(x.at) } },
            .cast => |c| .{ .cast = .{ .to = c.to, .arg = try p.clone(c.arg) } },
        });
    }

    /// The local variable with this name that can be seen from here. If
    /// two can (an inner block declared the name again), the one declared
    /// LAST wins: so look from the end of `scope`.
    fn lookup(p: *const CParser, name: []const u8) ?u32 {
        ???; // write this function's body
    }

    /// `int`, `char` or `void`, if one is next.
    fn parseBaseType(p: *CParser) ?CType {
        if (p.eat("int")) return .int;
        if (p.eat("char")) return .char;
        if (p.eat("void")) return .void;
        return null;
    }

    /// Any number of `*`: each makes a pointer to the type so far.
    fn parsePointers(p: *CParser, base: CType) !CType {
        var t = base;
        while (p.eat("*")) {
            const pointee = try p.alloc.create(CType);
            pointee.* = t;
            t = .{ .ptr = pointee };
        }
        return t;
    }

    fn startsType(tok: CToken) bool {
        return tok.is(.keyword, "int") or tok.is(.keyword, "char") or tok.is(.keyword, "void");
    }

    fn parsePrimary(p: *CParser) anyerror!*CExpr {
        ???; // write this function's body
    }

    /// e = e + 1 or e = e - 1: what ++ and -- mean.
    fn step(p: *CParser, target: *CExpr, op: CBinary) !*CExpr {
        try needTarget(target);
        const sum = try p.new(.{ .binary = .{ .op = op, .lhs = try p.clone(target), .rhs = try p.new(.{ .num = 1 }) } });
        return p.new(.{ .assign = .{ .target = target, .value = sum } });
    }

    fn parsePostfix(p: *CParser) anyerror!*CExpr {
        ???; // write this function's body
    }

    fn parseUnary(p: *CParser) anyerror!*CExpr {
        ???; // write this function's body
    }

    fn binaryInfo(tok: CToken) ?CBinaryInfo {
        if (tok.kind != .punct) return null;
        for (c_binary_ops) |info| {
            if (std.mem.eql(u8, tok.text, info.text)) return info;
        }
        return null;
    }

    /// Precedence climbing: a unary, then every operator that is at
    /// least `min` strong, each with its right-hand side.
    fn parseBinary(p: *CParser, min: u8) anyerror!*CExpr {
        ???; // write this function's body
    }

    /// Only these can be assigned to, or have their address taken.
    fn needTarget(e: *const CExpr) !void {
        switch (e.*) {
            .local, .global, .deref, .index => {},
            else => return error.NotAssignable,
        }
    }

    fn parseAssign(p: *CParser) anyerror!*CExpr {
        ???; // write this function's body
    }

    fn parseExpr(p: *CParser) anyerror!*CExpr {
        return p.parseAssign();
    }
};

fn writeCType(w: *std.Io.Writer, t: CType) !void {
    switch (t) {
        .int, .char, .void => try w.writeAll(@tagName(t)),
        .ptr => |pointee| {
            try writeCType(w, pointee.*);
            try w.writeAll("*");
        },
        .array => |a| {
            try writeCType(w, a.elem.*);
            try w.print("[{d}]", .{a.len});
        },
    }
}

/// The tree as text: (operator operand operand). `locals` gives the
/// local variables their names back.
fn writeCExpr(w: *std.Io.Writer, e: *const CExpr, locals: []const CVar) !void {
    switch (e.*) {
        .num => |n| try w.print("{d}", .{n}),
        .str => |s| try w.print("\"{s}\"", .{s}),
        .local => |n| try w.writeAll(locals[n].name),
        .global => |name| try w.writeAll(name),
        .unary => |u| {
            try w.writeAll(switch (u.op) {
                .neg => "(- ",
                .not => "(~ ",
                .lnot => "(! ",
            });
            try writeCExpr(w, u.arg, locals);
            try w.writeAll(")");
        },
        .deref => |d| {
            try w.writeAll(if (d.byte) "(*b " else "(* ");
            try writeCExpr(w, d.arg, locals);
            try w.writeAll(")");
        },
        .addr => |a| {
            try w.writeAll("(& ");
            try writeCExpr(w, a, locals);
            try w.writeAll(")");
        },
        .binary => |b| {
            const text = for (c_binary_ops) |info| {
                if (info.op == b.op) break info.text;
            } else unreachable;
            try w.print("({s} ", .{text});
            try writeCExpr(w, b.lhs, locals);
            try w.writeAll(" ");
            try writeCExpr(w, b.rhs, locals);
            try w.writeAll(")");
        },
        .assign => |a| {
            try w.writeAll("(= ");
            try writeCExpr(w, a.target, locals);
            try w.writeAll(" ");
            try writeCExpr(w, a.value, locals);
            try w.writeAll(")");
        },
        .call => |c| {
            try w.print("(call {s}", .{c.name});
            for (c.args) |arg| {
                try w.writeAll(" ");
                try writeCExpr(w, arg, locals);
            }
            try w.writeAll(")");
        },
        .index => |x| {
            try w.writeAll("(index ");
            try writeCExpr(w, x.base, locals);
            try w.writeAll(" ");
            try writeCExpr(w, x.at, locals);
            try w.writeAll(")");
        },
        .cast => |c| {
            try w.writeAll("(cast ");
            try writeCType(w, c.to);
            try w.writeAll(" ");
            try writeCExpr(w, c.arg, locals);
            try w.writeAll(")");
        },
    }
}

const ta = std.testing.allocator;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

/// Parses one expression, which must be the whole source, and prints it.
fn treeOf(arena: std.mem.Allocator, source: []const u8) ![]const u8 {
    var p: CParser = .{ .toks = try cLex(arena, source), .alloc = arena };
    const e = try p.parseExpr();
    if (p.peek().kind != .eof) return error.SyntaxError;
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeCExpr(&out.writer, e, p.locals.items);
    return out.written();
}

fn expectTree(want: []const u8, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    try expectEqualStrings(want, try treeOf(arena.allocator(), source));
}

fn expectParseError(want: anyerror, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    try expectError(want, treeOf(arena.allocator(), source));
}

test "precedence" {
    try expectTree("(+ 1 (* 2 3))", "1 + 2 * 3");
    try expectTree("(+ (* 1 2) 3)", "1 * 2 + 3");
    try expectTree("(* (+ 1 2) 3)", "(1 + 2) * 3");
    try expectTree("(|| a (&& b (| c (^ d (& e (== f (< g (<< h (+ i (* j k))))))))))", "a || b && c | d ^ e & f == g < h << i + j * k");
    try expectTree("(|| (&& (| (^ (& (== (< (<< (+ (* a b) c) d) e) f) g) h) i) j) k)", "a * b + c << d < e == f & g ^ h | i && j || k");
    try expectTree("(== (& x 1) 0)", "(x & 1) == 0");
    try expectTree("(& x (== 1 0))", "x & 1 == 0"); // C's famous trap
}

test "associativity" {
    try expectTree("(- (- a b) c)", "a - b - c");
    try expectTree("(/ (/ a b) c)", "a / b / c");
    try expectTree("(- (+ (- a b) c) d)", "a - b + c - d");
    try expectTree("(% (* (/ a b) c) d)", "a / b * c % d");
    try expectTree("(>= (> (<= (< a b) c) d) e)", "a < b <= c > d >= e");
    try expectTree("(!= (== a b) c)", "a == b != c");
    try expectTree("(>> (<< a b) c)", "a << b >> c");
    try expectTree("(= a (= b c))", "a = b = c");
    try expectTree("(= a (+ (= b 1) 2))", "a = (b = 1) + 2");
}

test "unary and postfix" {
    try expectTree("(- (- x))", "- -x");
    try expectTree("(+ (- a) (! (~ b)))", "-a + !~b");
    try expectTree("(* (- a) b)", "-a * b");
    try expectTree("(* (* p))", "**p");
    try expectTree("(= (* p) (& x))", "*p = &x");
    try expectTree("(- (index a (+ i 1)))", "-a[i + 1]");
    try expectTree("(index (index a 1) 2)", "a[1][2]");
    try expectTree("(& (index a 3))", "&a[3]");
    try expectTree("(call f)", "f()");
    try expectTree("(call f 1 (+ x 2) (call g y))", "f(1, x + 2, g(y))");
    try expectTree("(+ (call f (= a 1)) 2)", "f(a = 1) + 2");
    try expectTree("(call puts \"hi\\n\")", "puts(\"hi\\n\")");
}

test "sugar" {
    try expectTree("(= a (+ a 5))", "a += 5");
    try expectTree("(= a (- a (* b 2)))", "a -= b * 2");
    try expectTree("(= (index a i) (+ (index a i) (= b (+ b 1))))", "a[i] += b += 1");
    try expectTree("(= x (+ x 1))", "++x");
    try expectTree("(= x (- x 1))", "--x");
    try expectTree("(- (= x (+ x 1)) 1)", "x++");
    try expectTree("(+ (= x (- x 1)) 1)", "x--");
    try expectTree("(* (- (= p (+ p 1)) 1))", "*p++");
    try expectTree("(= (* p) (+ (* p) 1))", "++*p");
    try expectTree("(+ (- (= a (+ a 1)) 1) b)", "a+++b");
}

test "casts" {
    try expectTree("(cast int x)", "(int)x");
    try expectTree("(* (cast char* p))", "*(char *)p");
    try expectTree("(+ (cast int** (- x)) 1)", "(int **)-x + 1");
    try expectTree("(= (* (cast int* 268435456)) c)", "*(int *)0x10000000 = c");
}

test "local variables, and which one a name means" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p: CParser = .{ .toks = try cLex(alloc, "x + y + z"), .alloc = alloc };
    // As if we were here:  int x; int y; { int x;  <here>  }
    try p.locals.appendSlice(alloc, &.{ .{ .name = "x", .type = .int }, .{ .name = "y", .type = .int }, .{ .name = "x", .type = .char } });
    try p.scope.appendSlice(alloc, &.{ 0, 1, 2 });
    const e = try p.parseExpr();
    try std.testing.expectEqual(@as(u32, 2), e.binary.lhs.binary.lhs.local); // the inner x
    try std.testing.expectEqual(@as(u32, 1), e.binary.lhs.binary.rhs.local);
    try expectEqualStrings("z", e.binary.rhs.global);
    // the inner block has ended: its x can no longer be seen
    p.scope.items.len = 2;
    p.at = 0;
    try std.testing.expectEqual(@as(u32, 0), (try p.parseExpr()).binary.lhs.binary.lhs.local);
}

test "what is not an expression" {
    try expectParseError(error.SyntaxError, "1 +");
    try expectParseError(error.SyntaxError, "(1 + 2");
    try expectParseError(error.SyntaxError, "1 2");
    try expectParseError(error.SyntaxError, "f(1,)");
    try expectParseError(error.SyntaxError, "a[1");
    try expectParseError(error.SyntaxError, "* ;");
    try expectParseError(error.NotAssignable, "1 = x");
    try expectParseError(error.NotAssignable, "a + b = c");
    try expectParseError(error.NotAssignable, "f() += 1");
    try expectParseError(error.NotAssignable, "5++");
    try expectParseError(error.NotAssignable, "&(a + b)");
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

const CTok = enum { ident, keyword, num, str, punct, eof };

const CToken = struct {
    kind: CTok,
    /// The characters of the token, a slice of the source.
    text: []const u8,
    /// For a num: its value.
    num: u32 = 0,
    /// Which line it is on, counting from 1: for error messages.
    line: u32,

    fn is(tok: CToken, kind: CTok, text: []const u8) bool {
        return tok.kind == kind and std.mem.eql(u8, tok.text, text);
    }
};

const c_keywords = [_][]const u8{ "int", "char", "void", "if", "else", "while", "for", "return", "break", "continue", "extern" };

/// Punctuation, longest first: the first one that matches is the longest
/// that does.
const c_puncts = [_][]const u8{
    "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "++", "--", "+=", "-=",
    "+",  "-",  "*",  "/",  "%",  "&",  "|",  "^",  "~",  "!",  "<",  ">",
    "=",  "(",  ")",  "{",  "}",  "[",  "]",  ";",  ",",
};

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// What the character after a backslash stands for.
fn cEscape(c: u8) !u8 {
    return switch (c) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '0' => 0,
        '\\', '\'', '"' => c,
        else => error.BadEscape,
    };
}

/// The tokens of `source`, ending with an eof token. Their text points
/// into `source`. The caller frees the slice.
fn cLex(alloc: std.mem.Allocator, source: []const u8) ![]CToken {
    var toks: std.ArrayList(CToken) = .empty;
    errdefer toks.deinit(alloc);
    var line: u32 = 1;
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        const start = i;
        if (c == '\n') {
            line += 1;
            i += 1;
        } else if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
        } else if (std.mem.startsWith(u8, source[i..], "//")) {
            // a comment to the end of the line: stop AT the newline, so
            // that the branch above still counts it
            while (i < source.len and source[i] != '\n') i += 1;
        } else if (std.mem.startsWith(u8, source[i..], "/*")) {
            // a comment to the next */, which may be lines away
            const end = std.mem.indexOfPos(u8, source, i + 2, "*/") orelse return error.UnterminatedComment;
            line += @intCast(std.mem.count(u8, source[i..end], "\n"));
            i = end + 2;
        } else if (std.ascii.isDigit(c)) {
            // A number runs on while there are name characters (so 0x1f
            // is one token, and so is the mistake 12ab). Decimal, or
            // hexadecimal after 0x. (C reads 017 as octal, 15: we refuse
            // a leading 0 instead of quietly reading it as 17. Zig's 0b,
            // 0o and 1_000 aren't C either.)
            while (i < source.len and isNameChar(source[i])) i += 1;
            const text = source[start..i];
            const hex = std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X");
            if (!hex and (text.len > 1 and text[0] == '0')) return error.BadNumber;
            if (std.mem.indexOfScalar(u8, text, '_') != null) return error.BadNumber;
            const value = std.fmt.parseInt(u32, if (hex) text[2..] else text, if (hex) 16 else 10) catch return error.BadNumber;
            try toks.append(alloc, .{ .kind = .num, .text = source[start..i], .num = value, .line = line });
        } else if (isNameChar(c)) {
            while (i < source.len and isNameChar(source[i])) i += 1;
            const text = source[start..i];
            var kind: CTok = .ident;
            for (c_keywords) |kw| {
                // the WHOLE name must be the keyword: `interest` is not `int`
                if (std.mem.eql(u8, text, kw)) kind = .keyword;
            }
            try toks.append(alloc, .{ .kind = kind, .text = text, .line = line });
        } else if (c == '\'') {
            // 'a' or '\n': a number
            if (i + 2 >= source.len) return error.BadCharacter;
            var value: u8 = source[i + 1];
            i += 2;
            if (value == '\\') {
                value = try cEscape(source[i]);
                i += 1;
            }
            if (i >= source.len or source[i] != '\'') return error.BadCharacter;
            i += 1;
            try toks.append(alloc, .{ .kind = .num, .text = source[start..i], .num = value, .line = line });
        } else if (c == '"') {
            // Up to the closing quote. A backslash protects the character
            // after it, so that \" doesn't end the string.
            i += 1;
            while (i < source.len and source[i] != '"') {
                if (source[i] == '\n') return error.UnterminatedString;
                // an escape must be one we know (the same as for 'a'),
                // and the assembler (216) knows the same ones, except \'
                if (source[i] == '\\' and i + 1 < source.len) {
                    if (source[i + 1] == '\n') return error.UnterminatedString;
                    _ = try cEscape(source[i + 1]);
                    if (source[i + 1] == '\'') return error.BadEscape;
                }
                i += if (source[i] == '\\') 2 else 1;
            }
            if (i >= source.len) return error.UnterminatedString;
            i += 1;
            try toks.append(alloc, .{ .kind = .str, .text = source[start + 1 .. i - 1], .line = line });
        } else {
            const found = for (c_puncts) |p| {
                if (std.mem.startsWith(u8, source[i..], p)) break p;
            } else return error.BadCharacter;
            i += found.len;
            try toks.append(alloc, .{ .kind = .punct, .text = source[start..i], .line = line });
        }
    }
    try toks.append(alloc, .{ .kind = .eof, .text = "", .line = line });
    return toks.toOwnedSlice(alloc);
}
