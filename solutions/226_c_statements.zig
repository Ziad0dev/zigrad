// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 226: statements, declarations, and whole functions ──────
//
// An expression computes a value. Everything else in C is built around
// expressions, by the same recursive descent:
//
//     statement    expression ;
//                  { statement statement ... }          a block
//                  if ( expression ) statement [else statement]
//                  while ( expression ) statement
//                  for ( init ; condition ; step ) statement
//                  return [expression] ;     break ;     continue ;
//                  a declaration:  int x = 1, *p, a[10];
//
//     function     type name ( parameters ) { statements }
//     a file       functions and global variables, one after another.
//                  `extern int x;` only says that x exists, in some
//                  other file (229), and `int f(int a);` the same for a
//                  function.
//
// Notice that a statement is found by its FIRST token. `if` starts an
// if, `{` a block, `int` a declaration, and anything else must be an
// expression. A grammar where one token of lookahead always settles what
// comes next is the kind recursive descent is good at, and C (nearly)
// is one.
//
// More sugar goes away here. `for` is a `while` in disguise:
//
//     for (init; cond; step) body      is      { init; while (cond) { body; step; } }
//
// except for one detail: `continue` inside a for must still run the
// step. So the tree's loop node keeps the step separate from the body,
// and a plain `while` is a loop with no step. And `int x = 5;` is a
// declaration followed by the expression statement `x = 5;`.
//
// DECLARATIONS AND SCOPE. A name means the variable declared most
// recently in a block that is still open:
//
//     int x;  { int x;  x = 1; }  x = 2;     two variables: the inner x
//                                            is set to 1, the outer to 2
//
// 225's parser already looks names up in `scope`, last first. What is
// left to do here is to keep `scope` right: a declaration adds the new
// variable at the end, and the end of a block removes everything the
// block added. Every declaration becomes a new entry in the function's
// list of locals, and the tree refers to locals by their number in that
// list, so after parsing, names no longer matter and two variables
// called x can't be confused.
//
// TYPES are read in two parts, C's oddest habit: a base type on the
// left (int, char), then for each declared name its own stars and
// brackets. In `int *p, a[10];` p is a pointer to int and a is an array
// of ten ints. What a type means for code is mostly its size.
//
// YOUR TASK: sizes, scope keeping, and the if and for statements.
//
const std = @import("std");

/// How many bytes a value of this type takes. An int and a pointer are 4
/// (one register), a char is 1, and an array is all its elements.
fn cSizeOf(t: CType) u32 {
    return switch (t) {
        .int, .ptr => 4,
        .char => 1,
        .void => 0,
        .array => |a| a.len * cSizeOf(a.elem.*),
    };
}

const CStmt = union(enum) {
    expr: *CExpr,
    block: []*CStmt,
    @"if": struct { cond: *CExpr, then: *CStmt, otherwise: ?*CStmt },
    /// while and for. No condition: forever.
    loop: struct { cond: ?*CExpr, body: *CStmt, step: ?*CExpr },
    ret: ?*CExpr,
    brk,
    cont,
};

const CFunction = struct {
    name: []const u8,
    ret: CType,
    /// Every variable of the function. The first `params` of them are
    /// its parameters, in order.
    locals: []CVar,
    params: u32,
    body: *CStmt,
};

const CGlobal = struct {
    name: []const u8,
    type: CType,
    /// A number or a string, if any.
    init: ?*CExpr,
    /// Declared with `extern`: it lives in another file, and this one
    /// only needs to know its type.
    external: bool = false,
};

/// One source file, parsed.
const CUnit = struct { functions: []CFunction, globals: []CGlobal };

fn cNewStmt(p: *CParser, s: CStmt) !*CStmt {
    const node = try p.alloc.create(CStmt);
    node.* = s;
    return node;
}

/// After the base type: stars, a name, and maybe [length]. Empty
/// brackets, as in `char s[]`, make a pointer: that is what an array
/// parameter is.
fn cParseDeclarator(p: *CParser, base: CType) !CVar {
    var t = try p.parsePointers(base);
    const name = p.next();
    if (name.kind != .ident) return error.SyntaxError;
    if (p.eat("[")) {
        const elem = try p.alloc.create(CType);
        elem.* = t;
        if (p.eat("]")) {
            t = .{ .ptr = elem };
        } else {
            const len = p.next();
            if (len.kind != .num) return error.SyntaxError;
            try p.expect("]");
            t = .{ .array = .{ .elem = elem, .len = len.num } };
        }
    }
    return .{ .name = name.text, .type = t };
}

/// Adds a variable to the function, visible from here on. Returns its
/// number. The same name twice in one block is an error; in an inner
/// block it is fine, and hides the outer one.
fn cDeclare(p: *CParser, v: CVar) !u32 {
    for (p.scope.items[p.block_start..]) |n| {
        if (std.mem.eql(u8, p.locals.items[n].name, v.name)) return error.Redeclared;
    }
    const number: u32 = @intCast(p.locals.items.len);
    try p.locals.append(p.alloc, v);
    try p.scope.append(p.alloc, number);
    return number;
}

/// `int x = 1, *p, a[10];` with the base type already read. The
/// variables are declared, and what is left for the tree is the
/// assignments.
fn cParseLocals(p: *CParser, base: CType) !*CStmt {
    var inits: std.ArrayList(*CStmt) = .empty;
    while (true) {
        const n = try cDeclare(p, try cParseDeclarator(p, base));
        if (p.eat("=")) {
            const target = try p.new(.{ .local = n });
            const assign = try p.new(.{ .assign = .{ .target = target, .value = try p.parseAssign() } });
            try inits.append(p.alloc, try cNewStmt(p, .{ .expr = assign }));
        }
        if (!p.eat(",")) break;
    }
    try p.expect(";");
    return cNewStmt(p, .{ .block = inits.items });
}

/// The statements up to the closing brace; the opening one has been
/// read. Whatever they declare can be seen until the block ends.
fn cParseBlock(p: *CParser) anyerror!*CStmt {
    const outer_len = p.scope.items.len;
    const outer_start = p.block_start;
    p.block_start = outer_len;
    var list: std.ArrayList(*CStmt) = .empty;
    while (!p.eat("}")) {
        if (p.peek().kind == .eof) return error.SyntaxError;
        try list.append(p.alloc, try cParseStmt(p));
    }
    p.scope.items.len = outer_len;
    p.block_start = outer_start;
    return cNewStmt(p, .{ .block = list.items });
}

fn cParseStmt(p: *CParser) anyerror!*CStmt {
    if (p.eat("{")) return cParseBlock(p);
    if (p.eat(";")) return cNewStmt(p, .{ .block = &.{} });
    if (p.parseBaseType()) |base| return cParseLocals(p, base);
    if (p.eat("if")) {
        try p.expect("(");
        const cond = try p.parseExpr();
        try p.expect(")");
        const then = try cParseStmt(p);
        // The else is optional. (And in  if (a) if (b) x; else y;  this
        // line is why the else belongs to the NEAREST if: the inner call
        // gets to look for it first.)
        const otherwise: ?*CStmt = if (p.eat("else")) try cParseStmt(p) else null;
        return cNewStmt(p, .{ .@"if" = .{ .cond = cond, .then = then, .otherwise = otherwise } });
    }
    if (p.eat("while")) {
        try p.expect("(");
        const cond = try p.parseExpr();
        try p.expect(")");
        return cNewStmt(p, .{ .loop = .{ .cond = cond, .body = try cParseStmt(p), .step = null } });
    }
    if (p.eat("for")) {
        // for (init; cond; step) body  becomes  { init; loop }. Each of
        // the three parts may be missing. A variable declared in the
        // init lives until the loop ends.
        const outer_len = p.scope.items.len;
        const outer_start = p.block_start;
        p.block_start = outer_len;
        try p.expect("(");
        const init = try cParseStmt(p); // a declaration, an expression statement, or just ;
        const cond: ?*CExpr = if (p.sees(";")) null else try p.parseExpr();
        try p.expect(";");
        const step: ?*CExpr = if (p.sees(")")) null else try p.parseExpr();
        try p.expect(")");
        const body = try cParseStmt(p);
        p.scope.items.len = outer_len;
        p.block_start = outer_start;
        const loop = try cNewStmt(p, .{ .loop = .{ .cond = cond, .body = body, .step = step } });
        const both = try p.alloc.alloc(*CStmt, 2);
        both[0] = init;
        both[1] = loop;
        return cNewStmt(p, .{ .block = both });
    }
    if (p.eat("return")) {
        const value: ?*CExpr = if (p.sees(";")) null else try p.parseExpr();
        try p.expect(";");
        return cNewStmt(p, .{ .ret = value });
    }
    if (p.eat("break")) {
        try p.expect(";");
        return cNewStmt(p, .brk);
    }
    if (p.eat("continue")) {
        try p.expect(";");
        return cNewStmt(p, .cont);
    }
    const e = try p.parseExpr();
    try p.expect(";");
    return cNewStmt(p, .{ .expr = e });
}

/// A whole file. `p` must have an arena for its allocator.
fn cParseUnit(p: *CParser) !CUnit {
    var functions: std.ArrayList(CFunction) = .empty;
    var globals: std.ArrayList(CGlobal) = .empty;
    while (p.peek().kind != .eof) {
        const external = p.eat("extern");
        const base = p.parseBaseType() orelse return error.SyntaxError;
        const first = try cParseDeclarator(p, base);
        if (!p.eat("(")) {
            // global variables: `int x = 1, y;`
            var v = first;
            while (true) {
                const init: ?*CExpr = if (p.eat("=")) try p.parseBinary(1) else null;
                try globals.append(p.alloc, .{ .name = v.name, .type = v.type, .init = init, .external = external });
                if (!p.eat(",")) break;
                v = try cParseDeclarator(p, base);
            }
            try p.expect(";");
            continue;
        }
        // a function: its parameters are its first locals
        p.locals = .empty;
        p.scope = .empty;
        p.block_start = 0;
        if (!p.eat(")")) {
            if (p.sees("void") and p.toks[p.at + 1].is(.punct, ")")) {
                p.at += 2; // f(void): no parameters
            } else {
                while (true) {
                    const param_base = p.parseBaseType() orelse return error.SyntaxError;
                    _ = try cDeclare(p, try cParseDeclarator(p, param_base));
                    if (!p.eat(",")) break;
                }
                try p.expect(")");
            }
        }
        const params: u32 = @intCast(p.locals.items.len);
        if (p.eat(";")) continue; // only a promise that the function exists somewhere
        try p.expect("{");
        const body = try cParseBlock(p);
        try functions.append(p.alloc, .{ .name = first.name, .ret = first.type, .locals = p.locals.items, .params = params, .body = body });
    }
    return .{ .functions = functions.items, .globals = globals.items };
}

/// Parses C source. Everything is allocated in `arena`. If it fails and
/// `err_line` isn't null, the line of the mistake is put there.
fn cParse(arena: std.mem.Allocator, source: []const u8, err_line: ?*u32) !CUnit {
    var p: CParser = .{ .toks = try cLex(arena, source), .alloc = arena };
    return cParseUnit(&p) catch |err| {
        if (err_line) |l| l.* = p.line();
        return err;
    };
}

/// A statement as text, on one line.
fn writeCStmt(w: *std.Io.Writer, s: *const CStmt, locals: []const CVar) !void {
    switch (s.*) {
        .expr => |e| {
            try writeCExpr(w, e, locals);
            try w.writeAll(";");
        },
        .block => |list| {
            try w.writeAll("{");
            for (list) |inner| {
                try w.writeAll(" ");
                try writeCStmt(w, inner, locals);
            }
            try w.writeAll(" }");
        },
        .@"if" => |i| {
            try w.writeAll("if ");
            try writeCExpr(w, i.cond, locals);
            try w.writeAll(" ");
            try writeCStmt(w, i.then, locals);
            if (i.otherwise) |o| {
                try w.writeAll(" else ");
                try writeCStmt(w, o, locals);
            }
        },
        .loop => |l| {
            try w.writeAll("loop ");
            if (l.cond) |c| try writeCExpr(w, c, locals) else try w.writeAll("forever");
            try w.writeAll(" ");
            try writeCStmt(w, l.body, locals);
            if (l.step) |st| {
                try w.writeAll(" step ");
                try writeCExpr(w, st, locals);
            }
        },
        .ret => |value| {
            try w.writeAll("return");
            if (value) |v| {
                try w.writeAll(" ");
                try writeCExpr(w, v, locals);
            }
            try w.writeAll(";");
        },
        .brk => try w.writeAll("break;"),
        .cont => try w.writeAll("continue;"),
    }
}

const ta = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

/// The body of the function `name` in `source`, as text.
fn bodyOf(arena: std.mem.Allocator, source: []const u8, name: []const u8) ![]const u8 {
    const unit = try cParse(arena, source, null);
    for (unit.functions) |f| {
        if (!std.mem.eql(u8, f.name, name)) continue;
        var out: std.Io.Writer.Allocating = .init(arena);
        try writeCStmt(&out.writer, f.body, f.locals);
        return out.written();
    }
    return error.NoSuchFunction;
}

fn expectBody(want: []const u8, comptime statements: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    try expectEqualStrings(want, try bodyOf(arena.allocator(), "int f(int n, int m) { " ++ statements ++ " }", "f"));
}

fn typeText(arena: std.mem.Allocator, t: CType) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeCType(&out.writer, t);
    return out.written();
}

test "sizes" {
    const int: CType = .int;
    const char: CType = .char;
    const row: CType = .{ .array = .{ .elem = &int, .len = 10 } };
    const text: CType = .{ .array = .{ .elem = &char, .len = 7 } };
    const ptr: CType = .{ .ptr = &text };
    try expectEqual(@as(u32, 4), cSizeOf(int));
    try expectEqual(@as(u32, 1), cSizeOf(char));
    try expectEqual(@as(u32, 40), cSizeOf(row));
    try expectEqual(@as(u32, 7), cSizeOf(text));
    try expectEqual(@as(u32, 4), cSizeOf(ptr)); // a pointer to anything is one address
    try expectEqual(@as(u32, 120), cSizeOf(.{ .array = .{ .elem = &row, .len = 3 } }));
    try expectEqual(@as(u32, 12), cSizeOf(.{ .array = .{ .elem = &ptr, .len = 3 } }));
}

test "simple statements" {
    try expectBody("{ (= n (+ n 1)); return (* n m); }", "n = n + 1; return n * m;");
    try expectBody("{ { } { { } (call g); } return; }", "; { {} g(); } return;");
    try expectBody("{ loop (< n m) (= n (+ n 1)); }", "while (n < m) ++n;");
    try expectBody("{ loop 1 { if (== n 3) break; if m continue; (= n (- n 1)); } }", "while (1) { if (n == 3) break; if (m) continue; n -= 1; }");
}

test "if and else" {
    try expectBody("{ if n (= m 1); }", "if (n) m = 1;");
    try expectBody("{ if n (= m 1); else (= m 2); }", "if (n) m = 1; else m = 2;");
    try expectBody("{ if n { (= m 1); } else if m { (= n 2); } else { (= n 3); } }", "if (n) { m = 1; } else if (m) { n = 2; } else { n = 3; }");
    // the dangling else: it belongs to the nearest if
    try expectBody("{ if n if m (call a); else (call b); }", "if (n) if (m) a(); else b();");
    try expectBody("{ if n { if m (call a); } else (call b); }", "if (n) { if (m) a(); } else b();");
}

test "for is a while with a step" {
    try expectBody("{ { (= n 0); loop (< n 10) (call g n); step (= n (+ n 1)) } }", "for (n = 0; n < 10; ++n) g(n);");
    try expectBody("{ { { (= i 0); } loop (< i n) { (= m (+ m i)); } step (- (= i (+ i 1)) 1) } return m; }", "for (int i = 0; i < n; i++) { m += i; } return m;");
    try expectBody("{ { { } loop forever { break; } } }", "for (;;) { break; }");
    try expectBody("{ { { } loop n { } } }", "for (; n;) ;");
}

test "declarations: every one is a new local" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const alloc = arena.allocator();
    const unit = try cParse(alloc,
        \\int f(int n, char *s) {
        \\    int x = 1, *p, a[10];
        \\    char buf[80], **argv;
        \\    { int x = 2; n = x; }
        \\    for (int i = 0; i < n; i++) { int x; x = i; }
        \\    for (int i = 9; i; i--) ;
        \\    return x + i;
        \\}
    , null);
    const f = unit.functions[0];
    try expectEqual(@as(u32, 2), f.params);
    const want = [_]struct { []const u8, []const u8 }{
        .{ "n", "int" },       .{ "s", "char*" },
        .{ "x", "int" },       .{ "p", "int*" },
        .{ "a", "int[10]" },   .{ "buf", "char[80]" },
        .{ "argv", "char**" }, .{ "x", "int" },
        .{ "i", "int" },       .{ "x", "int" },
        .{ "i", "int" },
    };
    try expectEqual(want.len, f.locals.len);
    for (want, f.locals) |w, v| {
        try expectEqualStrings(w[0], v.name);
        try expectEqualStrings(w[1], try typeText(alloc, v.type));
    }
    const body = f.body.block;
    // { int x = 2; n = x; }: the inner x is local 7
    try expectEqual(@as(u32, 7), body[2].block[0].block[0].expr.assign.target.local);
    try expectEqual(@as(u32, 7), body[2].block[1].expr.assign.value.local);
    // the first loop's i is local 8, and the x in its body local 9
    const first_loop = body[3].block[1].loop;
    try expectEqual(@as(u32, 8), first_loop.cond.?.binary.lhs.local);
    try expectEqual(@as(u32, 9), first_loop.body.block[1].expr.assign.target.local);
    try expectEqual(@as(u32, 8), first_loop.body.block[1].expr.assign.value.local);
    // the second loop has its own i
    try expectEqual(@as(u32, 10), body[4].block[1].loop.cond.?.local);
    // after the blocks and loops: x is the outer one again, and no i is left, so it reads as a global
    const sum = body[5].ret.?.binary;
    try expectEqual(@as(u32, 2), sum.lhs.local);
    try expectEqualStrings("i", sum.rhs.global);
}

test "a file: functions, prototypes and globals" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const alloc = arena.allocator();
    const unit = try cParse(alloc,
        \\int putc(int c);              /* a promise: defined elsewhere */
        \\int count = 3, *where;
        \\char *greeting = "hello";
        \\char line[64];
        \\int limit = -1;
        \\extern int ticks;
        \\void say(char s[]) { while (*s) putc(*s++); }
        \\char *name(void) { return greeting; }
        \\int main() { say(name()); return count; }
    , null);
    try expectEqual(@as(usize, 3), unit.functions.len);
    try expectEqualStrings("say", unit.functions[0].name);
    try expectEqualStrings("void", try typeText(alloc, unit.functions[0].ret));
    try expectEqualStrings("char*", try typeText(alloc, unit.functions[0].locals[0].type));
    try expectEqualStrings("char*", try typeText(alloc, unit.functions[1].ret));
    try expectEqual(@as(u32, 0), unit.functions[1].params);
    try expectEqual(@as(u32, 0), unit.functions[2].params);
    try expectEqual(@as(usize, 6), unit.globals.len);
    try expect(unit.globals[5].external and !unit.globals[4].external);
    try expectEqualStrings("count", unit.globals[0].name);
    try expectEqual(@as(u32, 3), unit.globals[0].init.?.num);
    try expectEqualStrings("int*", try typeText(alloc, unit.globals[1].type));
    try expect(unit.globals[1].init == null);
    try expectEqualStrings("hello", unit.globals[2].init.?.str);
    try expectEqualStrings("char[64]", try typeText(alloc, unit.globals[3].type));
    try expectEqual(CUnary.neg, unit.globals[4].init.?.unary.op);
    var out: std.Io.Writer.Allocating = .init(alloc);
    try writeCStmt(&out.writer, unit.functions[0].body, unit.functions[0].locals);
    try expectEqualStrings("{ loop (* s) (call putc (* (- (= s (+ s 1)) 1))); }", out.written());
}

const expect = std.testing.expect;

test "errors, and where they are" {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const alloc = arena.allocator();
    var line: u32 = 0;
    try expectError(error.SyntaxError, cParse(alloc, "int main() {\n  int x = 1;\n  x = ;\n}", &line));
    try expectEqual(@as(u32, 3), line);
    try expectError(error.SyntaxError, cParse(alloc, "int main() {\n  return 1\n}\n", &line));
    try expectEqual(@as(u32, 3), line); // the missing ; is noticed at the }
    try expectError(error.SyntaxError, cParse(alloc, "int main() { if (1) {", &line));
    try expectError(error.SyntaxError, cParse(alloc, "main() { }", &line));
    try expectError(error.SyntaxError, cParse(alloc, "int f(int) { }", &line));
    try expectError(error.Redeclared, cParse(alloc, "int f() {\n int x;\n char x;\n}", &line));
    try expectEqual(@as(u32, 3), line);
    try expectError(error.Redeclared, cParse(alloc, "int f(int a, int a) { }", &line));
    try expectError(error.Redeclared, cParse(alloc, "int f() { for (int i = 0, i = 1;;) ; }", &line));
    // not errors: a new block may reuse a name
    _ = try cParse(alloc, "int f(int a) { int b; { int a; int b; } { int b; } }", &line);
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
            // is one token, and so is the mistake 12ab). Base 0 means:
            // look at the prefix. 0x is hexadecimal.
            while (i < source.len and isNameChar(source[i])) i += 1;
            const value = std.fmt.parseInt(u32, source[start..i], 0) catch return error.BadNumber;
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
        var i = p.scope.items.len;
        while (i > 0) {
            i -= 1;
            const n = p.scope.items[i];
            if (std.mem.eql(u8, p.locals.items[n].name, name)) return n;
        }
        return null;
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
        const tok = p.next();
        switch (tok.kind) {
            .num => return p.new(.{ .num = tok.num }),
            .str => return p.new(.{ .str = tok.text }),
            .ident => {
                if (p.eat("(")) {
                    // a call: expressions with commas between, up to the )
                    var args: std.ArrayList(*CExpr) = .empty;
                    if (!p.eat(")")) {
                        while (true) {
                            try args.append(p.alloc, try p.parseExpr());
                            if (!p.eat(",")) break;
                        }
                        try p.expect(")");
                    }
                    return p.new(.{ .call = .{ .name = tok.text, .args = args.items } });
                }
                if (p.lookup(tok.text)) |n| return p.new(.{ .local = n });
                return p.new(.{ .global = tok.text });
            },
            else => {},
        }
        if (tok.is(.punct, "(")) {
            // brackets leave no node: they only decided the tree's shape
            const inside = try p.parseExpr();
            try p.expect(")");
            return inside;
        }
        p.at -= @intFromBool(tok.kind != .eof); // point the error at this token
        return error.SyntaxError;
    }

    /// e = e + 1 or e = e - 1: what ++ and -- mean.
    fn step(p: *CParser, target: *CExpr, op: CBinary) !*CExpr {
        try needTarget(target);
        const sum = try p.new(.{ .binary = .{ .op = op, .lhs = try p.clone(target), .rhs = try p.new(.{ .num = 1 }) } });
        return p.new(.{ .assign = .{ .target = target, .value = sum } });
    }

    fn parsePostfix(p: *CParser) anyerror!*CExpr {
        var e = try p.parsePrimary();
        while (true) {
            if (p.eat("[")) {
                const at = try p.parseExpr();
                try p.expect("]");
                e = try p.new(.{ .index = .{ .base = e, .at = at } });
            } else if (p.eat("++")) {
                // the stepped value, minus one again: the value from before
                const stepped = try p.step(e, .add);
                e = try p.new(.{ .binary = .{ .op = .sub, .lhs = stepped, .rhs = try p.new(.{ .num = 1 }) } });
            } else if (p.eat("--")) {
                const stepped = try p.step(e, .sub);
                e = try p.new(.{ .binary = .{ .op = .add, .lhs = stepped, .rhs = try p.new(.{ .num = 1 }) } });
            } else return e;
        }
    }

    fn parseUnary(p: *CParser) anyerror!*CExpr {
        // What follows a unary operator is again a unary: - - x, *p++, !*p.
        if (p.eat("-")) return p.new(.{ .unary = .{ .op = .neg, .arg = try p.parseUnary() } });
        if (p.eat("~")) return p.new(.{ .unary = .{ .op = .not, .arg = try p.parseUnary() } });
        if (p.eat("!")) return p.new(.{ .unary = .{ .op = .lnot, .arg = try p.parseUnary() } });
        if (p.eat("*")) return p.new(.{ .deref = .{ .arg = try p.parseUnary() } });
        if (p.eat("&")) {
            const arg = try p.parseUnary();
            try needTarget(arg); // only something that lives in memory has an address
            return p.new(.{ .addr = arg });
        }
        if (p.eat("++")) return p.step(try p.parseUnary(), .add);
        if (p.eat("--")) return p.step(try p.parseUnary(), .sub);
        if (p.sees("(") and startsType(p.toks[p.at + 1])) {
            // a cast: (type) in front of a unary
            p.at += 1;
            const to = try p.parsePointers(p.parseBaseType().?);
            try p.expect(")");
            return p.new(.{ .cast = .{ .to = to, .arg = try p.parseUnary() } });
        }
        return p.parsePostfix();
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
        var lhs = try p.parseUnary();
        while (binaryInfo(p.peek())) |info| {
            if (info.strength < min) break; // too weak: it belongs to someone above us
            p.at += 1;
            // the right-hand side takes only operators stronger than this one
            const rhs = try p.parseBinary(info.strength + 1);
            lhs = try p.new(.{ .binary = .{ .op = info.op, .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    /// Only these can be assigned to, or have their address taken.
    fn needTarget(e: *const CExpr) !void {
        switch (e.*) {
            .local, .global, .deref, .index => {},
            else => return error.NotAssignable,
        }
    }

    fn parseAssign(p: *CParser) anyerror!*CExpr {
        const lhs = try p.parseBinary(1);
        if (p.eat("=")) {
            try needTarget(lhs);
            // a = b = c is a = (b = c)
            return p.new(.{ .assign = .{ .target = lhs, .value = try p.parseAssign() } });
        }
        for ([_]CBinaryInfo{ .{ .text = "+=", .op = .add, .strength = 0 }, .{ .text = "-=", .op = .sub, .strength = 0 } }) |sugar| {
            if (!p.eat(sugar.text)) continue;
            try needTarget(lhs);
            const sum = try p.new(.{ .binary = .{ .op = sugar.op, .lhs = try p.clone(lhs), .rhs = try p.parseAssign() } });
            return p.new(.{ .assign = .{ .target = lhs, .value = sum } });
        }
        return lhs;
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
