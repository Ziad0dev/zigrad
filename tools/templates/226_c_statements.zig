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

//@export c_parse
/// How many bytes a value of this type takes. An int and a pointer are 4
/// (one register), a char is 1, and an array is all its elements.
fn cSizeOf(t: CType) u32 {
    return switch (t) {
        .int, .ptr => 4,
        .char => 1,
        .void => 0,
        .array => |a| ⟪a.len * cSizeOf(a.elem.*)|||???⟫,
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

/// A function that is declared (`char *pick(int n);`) but not defined
/// in this file.
const CDeclared = struct { name: []const u8, ret: CType };

/// One source file, parsed.
const CUnit = struct { functions: []CFunction, globals: []CGlobal, declared: []CDeclared = &.{} };

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
    try p.scope.append(p.alloc, ⟪number|||???⟫);
    return number;
}

/// `int x = 1, *p, a[10];` with the base type already read. The
/// variables are declared, and what is left for the tree is the
/// assignments.
fn cParseLocals(p: *CParser, base: CType) !*CStmt {
    var inits: std.ArrayList(*CStmt) = .empty;
    while (true) {
        const n = try cDeclare(p, try cParseDeclarator(p, base));
        if (p.sees("=") and p.locals.items[n].type == .array) {
            // `char s[16] = "hi";` copies the string in; our dialect
            // doesn't do that for local arrays: assign the elements
            return error.ArrayInitializer;
        }
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
    return cParseBlockFrom(p, p.scope.items.len);
}

/// cParseBlock, where this block's own names start at `start` in the
/// scope. A function's body starts at 0, so that its parameters count
/// as declared in it: in C, `int f(int a) { int a; }` declares a twice.
fn cParseBlockFrom(p: *CParser, start: usize) anyerror!*CStmt {
    const outer_len = p.scope.items.len;
    const outer_start = p.block_start;
    p.block_start = start;
    var list: std.ArrayList(*CStmt) = .empty;
    while (!p.eat("}")) {
        if (p.peek().kind == .eof) return error.SyntaxError;
        try list.append(p.alloc, try cParseStmt(p));
    }
    p.scope.items.len = ⟪outer_len|||???⟫;
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
        const otherwise: ?*CStmt = ⟪if (p.eat("else")) try cParseStmt(p) else null|||???⟫;
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
        const loop = try cNewStmt(p, ⟪.{ .loop = .{ .cond = cond, .body = body, .step = step } }|||???⟫);
        const both = try p.alloc.alloc(*CStmt, 2);
        both[0] = ⟪init|||???⟫;
        both[1] = ⟪loop|||???⟫;
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
    var declared: std.ArrayList(CDeclared) = .empty;
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
        if (p.eat(";")) {
            // only a promise that the function exists somewhere; what it
            // returns still matters to whoever calls it (228)
            try declared.append(p.alloc, .{ .name = first.name, .ret = first.type });
            continue;
        }
        try p.expect("{");
        const body = try cParseBlockFrom(p, 0);
        try functions.append(p.alloc, .{ .name = first.name, .ret = first.type, .locals = p.locals.items, .params = params, .body = body });
    }
    return .{ .functions = functions.items, .globals = globals.items, .declared = declared.items };
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
//@end

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
    try expectError(error.Redeclared, cParse(alloc, "int f(int a) { int a = 2; return a; }", &line)); // the body is the parameters' block
    // not errors: a new block may reuse a name
    _ = try cParse(alloc, "int f(int a) { int b; { int a; int b; } { int b; } }", &line);
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include c_lex
//@include c_expr
