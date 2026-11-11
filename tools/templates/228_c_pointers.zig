//
// ─── Exercise 228: pointers, arrays, and what types are for ───────────
//
// 227's compiler knows one kind of value, a 32-bit word, and never looks
// at a type. For ints that was enough. Three things in C are not:
//
//     int a[10];  a[3] = 5;     where is a[3]?
//     int *p;     p + 1         the next BYTE, or the next int?
//     char *s;    *s            one byte from memory, or four?
//
// All three are answered by types, and the pleasant surprise is that the
// code generator still doesn't need to learn about them. A pass between
// the parser and the generator, *lowering*, rewrites the tree so that
// everything a type implied is spelled out:
//
//     p + i       becomes   p + i * 4        when p points at ints. This
//                                            is pointer arithmetic: C
//                                            counts in elements, the
//                                            machine in bytes.
//     a[i]        becomes   *(a + i)         That is not an analogy. It
//                                            is the definition of [] in
//                                            the C standard (and why
//                                            3[a] compiles).
//     *s          is marked "one byte"       when s points at chars
//     p - q       becomes   (p - q) >> 2     for int pointers: how many
//                                            ELEMENTS apart
//
// To do this, lowering needs the type of every expression, and that is
// a small recursive function of its own, typeOf: a number is an int, a
// variable has the type it was declared with, `&x` is a pointer to
// whatever x is, `*p` is whatever p points at, and so on up the tree.
//
// One more rule completes arrays. An array is not a pointer: `int a[10]`
// is 40 bytes of the frame, and there is no word anywhere holding its
// address. But used as a value, an array *decays* into the address of
// its first element. (227's generator already does that: the value of an
// array-typed variable is its address.) So `a + i` is pointer
// arithmetic, `*(a + i)` works, and passing `a` to a function passes an
// address, which is why a C function can't tell how long an array is.
//
// With this, the compiler handles real programs: the tests end with a
// sort and a prime sieve.
//
// YOUR TASK: the pieces of CLower marked below.
//
const std = @import("std");

//@export c_lower
/// What a pointer or an array is made of. null: `t` is neither.
fn cElementOf(t: CType) ?CType {
    return switch (t) {
        .ptr => |pointee| pointee.*,
        .array => |a| ⟪a.elem.*|||???⟫,
        else => null,
    };
}

/// How far apart two neighbouring elements are. (A void* counts in bytes.)
fn cStride(element: CType) u32 {
    return @max(1, cSizeOf(element));
}

const c_char_type: CType = .char;

const CLower = struct {
    /// An arena: new nodes and new types are made here.
    alloc: std.mem.Allocator,
    unit: *const CUnit,
    f: *const CFunction,

    fn pointerTo(lo: *CLower, t: CType) !CType {
        const pointee = try lo.alloc.create(CType);
        pointee.* = t;
        return .{ .ptr = pointee };
    }

    fn typeOf(lo: *CLower, e: *const CExpr) anyerror!CType {
        switch (e.*) {
            .num, .unary => return .int,
            .str => return .{ .ptr = &c_char_type },
            .local => |n| return lo.f.locals[n].type,
            .global => |name| {
                for (lo.unit.globals) |v| {
                    if (std.mem.eql(u8, v.name, name)) return v.type;
                }
                return .int;
            },
            // *p is what p points at. (Of something that is no pointer:
            // an int. C would refuse; we let it through.)
            .deref => |d| return cElementOf(try lo.typeOf(d.arg)) orelse .int,
            .addr => |target| return lo.pointerTo(⟪try lo.typeOf(target)|||???⟫),
            .index => |x| return cElementOf(try lo.typeOf(x.base)) orelse .int,
            .assign => |a| return lo.typeOf(a.target),
            .cast => |c| return c.to,
            .call => |c| {
                for (lo.unit.functions) |f| {
                    if (std.mem.eql(u8, f.name, c.name)) return f.ret;
                }
                return .int;
            },
            .binary => |b| {
                if (b.op != .add and b.op != .sub) return .int;
                const left = cElementOf(try lo.typeOf(b.lhs));
                const right = cElementOf(try lo.typeOf(b.rhs));
                // pointer - pointer is a count. Otherwise, a sum with a
                // pointer (or an array) in it is a pointer to the same
                // kind of element.
                if (left != null and right != null) return .int;
                if (left orelse right) |element| return lo.pointerTo(element);
                return .int;
            },
        }
    }

    fn new(lo: *CLower, e: CExpr) !*CExpr {
        const node = try lo.alloc.create(CExpr);
        node.* = e;
        return node;
    }

    /// e * stride, or just e when the stride is 1.
    fn scaled(lo: *CLower, e: *CExpr, stride: u32) !*CExpr {
        if (stride == 1) return e;
        return lo.new(.{ .binary = .{ .op = .mul, .lhs = e, .rhs = try lo.new(.{ .num = stride }) } });
    }

    /// Rewrites the tree under e, in place.
    fn lower(lo: *CLower, e: *CExpr) anyerror!void {
        switch (e.*) {
            .num, .str, .local, .global => {},
            .unary => |u| try lo.lower(u.arg),
            .addr => |target| try lo.lower(target),
            .cast => |c| try lo.lower(c.arg),
            .call => |c| for (c.args) |arg| try lo.lower(arg),
            .assign => |a| {
                try lo.lower(a.target);
                try lo.lower(a.value);
            },
            .deref => |*d| {
                try lo.lower(d.arg);
                // one byte, if what the pointer points at is a char
                const element = cElementOf(try lo.typeOf(d.arg)) orelse CType.int;
                d.byte = ⟪element == .char|||???⟫;
            },
            .index => |x| {
                // a[i] is *(a + i). Make that tree, and lower IT: the
                // sum still needs its scaling, the * its size.
                const sum = try lo.new(.{ .binary = .{ .op = .add, .lhs = x.base, .rhs = x.at } });
                e.* = ⟪.{ .deref = .{ .arg = sum } }|||???⟫;
                try lo.lower(e);
            },
            .binary => |*b| {
                try lo.lower(b.lhs);
                try lo.lower(b.rhs);
                if (b.op != .add and b.op != .sub) return;
                const left = cElementOf(try lo.typeOf(b.lhs));
                const right = cElementOf(try lo.typeOf(b.rhs));
                if (left != null and right != null) {
                    if (b.op == .add) return error.AddingPointers;
                    // pointer - pointer: the bytes between them, divided
                    // by the stride. The strides here are 1 and 4, so a
                    // shift does the dividing.
                    if (cStride(left.?) == 4) {
                        const bytes = try lo.new(e.*);
                        e.* = .{ .binary = .{ .op = .shr, .lhs = bytes, .rhs = try lo.new(.{ .num = 2 }) } };
                    }
                } else if (left) |element| {
                    // pointer + n, pointer - n: n counts elements
                    b.rhs = try lo.scaled(b.rhs, ⟪cStride(element)|||???⟫);
                } else if (right) |element| {
                    // n + pointer
                    if (b.op == .sub) return error.SubtractingPointer;
                    b.lhs = try lo.scaled(⟪b.lhs|||???⟫, cStride(element));
                }
            },
        }
    }

    fn lowerStmt(lo: *CLower, s: *CStmt) anyerror!void {
        switch (s.*) {
            .expr => |e| try lo.lower(e),
            .block => |list| for (list) |inner| try lo.lowerStmt(inner),
            .@"if" => |i| {
                try lo.lower(i.cond);
                try lo.lowerStmt(i.then);
                if (i.otherwise) |o| try lo.lowerStmt(o);
            },
            .loop => |l| {
                if (l.cond) |cond| try lo.lower(cond);
                try lo.lowerStmt(l.body);
                if (l.step) |st| try lo.lower(st);
            },
            .ret => |value| if (value) |v| try lo.lower(v),
            .brk, .cont => {},
        }
    }
};

/// The whole compiler: C in, assembly out. The caller frees the
/// assembly. If it fails and `err_line` isn't null, the line of a syntax
/// error is put there.
fn cCompile(gpa: std.mem.Allocator, source: []const u8, err_line: ?*u32) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const unit = try cParse(arena.allocator(), source, err_line);
    for (unit.functions) |*f| {
        var lo: CLower = .{ .alloc = arena.allocator(), .unit = &unit, .f = f };
        try lo.lowerStmt(f.body);
    }
    return cGenerate(gpa, &unit);
}

/// Compiles C, puts `assembly` after it (for functions written by hand),
/// and runs the lot on the emulator. The caller frees the output.
fn cRun(gpa: std.mem.Allocator, source: []const u8, assembly: []const u8, input: []const u8) !CRun {
    var line: u32 = 0;
    const compiled = cCompile(gpa, source, &line) catch |err| {
        std.debug.print("the compiler says {s} (if it is about syntax: line {d})\n", .{ @errorName(err), line });
        return err;
    };
    defer gpa.free(compiled);
    const whole = try std.mem.concat(gpa, u8, &.{ compiled, assembly });
    defer gpa.free(whole);
    return runAssembly(gpa, whole, input);
}
//@end

const ta = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const declarations =
    \\int g; int table[8]; char *msg; char name[16];
    \\char *pick(int n);
    \\int f(int n, int *p, char *s, char **argv) { int a[10]; char buf[80]; int *q;
;

/// The statement `expression;` inside a function with the declarations
/// above: its type, and its tree after lowering.
fn lowered(arena: std.mem.Allocator, comptime expression: []const u8) ![2][]const u8 {
    const unit = try cParse(arena, declarations ++ expression ++ "; }\nchar *pick(int n) { return 0; }", null);
    const f = &unit.functions[0];
    var lo: CLower = .{ .alloc = arena, .unit = &unit, .f = f };
    const e = f.body.block[3].expr;
    var type_text: std.Io.Writer.Allocating = .init(arena);
    try writeCType(&type_text.writer, try lo.typeOf(e));
    try lo.lower(e);
    var tree: std.Io.Writer.Allocating = .init(arena);
    try writeCExpr(&tree.writer, e, f.locals);
    return .{ type_text.written(), tree.written() };
}

fn expectLowered(want_type: []const u8, want_tree: []const u8, comptime expression: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const got = try lowered(arena.allocator(), expression);
    try expectEqualStrings(want_type, got[0]);
    try expectEqualStrings(want_tree, got[1]);
}

test "the type of an expression" {
    try expectLowered("int", "(+ n 1)", "n + 1");
    try expectLowered("int*", "p", "p");
    try expectLowered("int", "(* p)", "*p");
    try expectLowered("int**", "(& p)", "&p");
    try expectLowered("int*", "(& n)", "&n");
    try expectLowered("char", "(*b s)", "*s");
    try expectLowered("char*", "(* argv)", "*argv");
    try expectLowered("char", "(*b (* argv))", "**argv");
    try expectLowered("int[10]", "a", "a");
    try expectLowered("int[10]*", "(& a)", "&a");
    try expectLowered("char*", "\"hi\"", "\"hi\"");
    try expectLowered("char", "(*b \"hi\")", "*\"hi\"");
    try expectLowered("int", "g", "g");
    try expectLowered("int", "undeclared", "undeclared");
    try expectLowered("char*", "msg", "msg");
    try expectLowered("char*", "(call pick 1)", "pick(1)");
    try expectLowered("char", "(*b (call pick 1))", "*pick(1)");
    try expectLowered("int", "(call other 1)", "other(1)");
    try expectLowered("char*", "(cast char* p)", "(char *)p");
    try expectLowered("char", "(*b (cast char* p))", "*(char *)p");
    try expectLowered("int*", "(= q p)", "q = p");
    try expectLowered("int", "(< p q)", "p < q");
}

test "pointer arithmetic counts in elements" {
    try expectLowered("int*", "(+ p (* n 4))", "p + n");
    try expectLowered("int*", "(- p (* 1 4))", "p - 1");
    try expectLowered("int*", "(+ (* n 4) p)", "n + p");
    try expectLowered("char*", "(+ s n)", "s + n");
    try expectLowered("char**", "(+ argv (* 1 4))", "argv + 1");
    try expectLowered("int*", "(+ a (* 2 4))", "a + 2"); // an array decays to a pointer
    try expectLowered("char*", "(+ buf 2)", "buf + 2");
    try expectLowered("int*", "(+ (+ p (* 1 4)) (* 2 4))", "p + 1 + 2");
    try expectLowered("int", "(>> (- p q) 2)", "p - q");
    try expectLowered("int", "(- s msg)", "s - msg");
    try expectLowered("int", "(+ (>> (- (+ p (* n 4)) a) 2) 1)", "p + n - a + 1");
    try expectLowered("int", "(* (+ p (* 1 4)))", "*(p + 1)");
    try expectLowered("int*", "(- (= p (+ p (* 1 4))) (* 1 4))", "p++");
    try expectLowered("char", "(*b (- (= s (+ s 1)) 1))", "*s++");
    try expectLowered("int*", "(= q (+ q (* n 4)))", "q += n");
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    try expectError(error.AddingPointers, lowered(arena.allocator(), "p + q"));
    try expectError(error.SubtractingPointer, lowered(arena.allocator(), "n - p"));
}

test "indexing is sugar" {
    try expectLowered("int", "(* (+ a (* n 4)))", "a[n]");
    try expectLowered("int", "(* (+ p (* 0 4)))", "p[0]");
    try expectLowered("char", "(*b (+ buf n))", "buf[n]");
    try expectLowered("char", "(*b (+ \"abc\" 1))", "\"abc\"[1]");
    try expectLowered("char*", "(* (+ argv (* 1 4)))", "argv[1]");
    try expectLowered("char", "(*b (+ (* (+ argv (* 1 4))) 2))", "argv[1][2]");
    try expectLowered("int", "(* (+ (* 3 4) a))", "3[a]");
    try expectLowered("int", "(* (+ table (* (* (+ a (* n 4))) 4)))", "table[a[n]]");
    try expectLowered("int*", "(& (* (+ a (* 3 4))))", "&a[3]");
    try expectLowered("int", "(= (* (+ a (* n 4))) (+ (* (+ a (* n 4))) 1))", "a[n] += 1");
    try expectLowered("char", "(= (*b (+ name 0)) (*b s))", "name[0] = *s");
}

fn expectRuns(want: i32, source: []const u8) !void {
    const ran = try cRun(ta, source, "", "");
    defer ta.free(ran.output);
    try expectEqual(@as(u32, @bitCast(want)), ran.result);
}

test "arrays and pointers, running" {
    try expectRuns(60,
        \\int main() { int a[3]; a[0] = 10; a[1] = 20; a[2] = 30; return a[0] + a[1] + a[2]; }
    );
    // a local array doesn't run into its neighbours
    try expectRuns(1234,
        \\int main() {
        \\    int before = 12; int a[4]; int after = 34;
        \\    for (int i = 0; i < 4; i++) a[i] = 99;
        \\    return before * 100 + after;
        \\}
    );
    try expectRuns(45,
        \\int sum(int *p, int n) { int s = 0; while (n--) s += *p++; return s; }
        \\int main() { int a[10]; for (int i = 0; i < 10; i++) a[i] = i; return sum(a, 10); }
    );
    try expectRuns(7,
        \\int main() { int a[10]; int *p = &a[2]; int *q = a + 9; return q - p; }
    );
    try expectRuns(5,
        \\int strlen(char *s) { char *p = s; while (*p) p++; return p - s; }
        \\int main() { return strlen("hello"); }
    );
    // chars are bytes, in memory too
    try expectRuns(0x04030201,
        \\int main() { int x; char *p = (char *)&x; p[0] = 1; p[1] = 2; p[2] = 3; p[3] = 4; return x; }
    );
    try expectRuns(0x7856,
        \\int main() { int x = 0x12345678; char *p = (char *)&x; return p[0] * 256 + p[1]; }
    );
    try expectRuns('c' * 256 + 'y',
        \\char *names[3];
        \\int main() { names[0] = "ab"; names[1] = "cd"; names[2] = "xyz"; return names[1][0] * 256 + names[2][1]; }
    );
}

test "strings: reversing one in place" {
    const ran = try cRun(ta,
        \\char buf[16];
        \\int copy(char *to, char *from) { int n = 0; while (to[n] = from[n]) n++; return n; }
        \\int reverse(char *s, int n) {
        \\    for (int i = 0; i < (n >> 1); i++) { char t = s[i]; s[i] = s[n - 1 - i]; s[n - 1 - i] = t; }
        \\    return 0;
        \\}
        \\int main() {
        \\    int n = copy(buf, "stressed");
        \\    reverse(buf, n);
        \\    for (int i = 0; buf[i]; i++) putc(buf[i]);
        \\    return n;
        \\}
    ,
        \\putc:   mov   r1, #0x10000000
        \\        str   r0, [r1]
        \\        mov   pc, lr
    , "");
    defer ta.free(ran.output);
    try expectEqual(@as(u32, 8), ran.result);
    try expectEqualStrings("desserts", ran.output);
}

test "real programs: a sort and a sieve" {
    try expectRuns(123456789,
        \\int data[9];
        \\int sort(int *a, int n) {
        \\    for (int i = 1; i < n; i++) {
        \\        int x = a[i];
        \\        int j = i;
        \\        while (j > 0 && a[j - 1] > x) { a[j] = a[j - 1]; j--; }
        \\        a[j] = x;
        \\    }
        \\    return 0;
        \\}
        \\int main() {
        \\    data[0] = 5; data[1] = 3; data[2] = 9; data[3] = 1; data[4] = 7;
        \\    data[5] = 2; data[6] = 8; data[7] = 4; data[8] = 6;
        \\    sort(data, 9);
        \\    int n = 0;
        \\    for (int i = 0; i < 9; i++) n = n * 10 + data[i];
        \\    return n;
        \\}
    );
    // how many primes are below 1000?
    try expectRuns(168,
        \\char composite[1000];
        \\int main() {
        \\    int count = 0;
        \\    for (int i = 2; i < 1000; i++) {
        \\        if (composite[i]) continue;
        \\        count++;
        \\        for (int j = i * i; j < 1000; j += i) composite[j] = 1;
        \\    }
        \\    return count;
        \\}
    );
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
//@include arm_enc
//@include arm_alu
//@include arm_asm_line
//@include arm_asm
//@include arm_emu
