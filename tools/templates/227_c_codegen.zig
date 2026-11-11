//
// ─── Exercise 227: from the tree to assembly ──────────────────────────
//
// The tree says what to compute. The code generator walks it and writes
// down instructions that do. The simplest scheme that always works needs
// just one promise:
//
//     genExpr(e) writes code that leaves the value of e in r0.
//
// A number: `mov r0, #n`. A binary operator has two values to deal with
// and one r0, so the first one waits on the stack while the second is
// worked out:
//
//     a - b:      <code for a>            r0 = a
//                 str r0, [sp, #-4]!      push it
//                 <code for b>            r0 = b    (however complicated b is)
//                 ldr r1, [sp], #4        pop:      r1 = a
//                 sub r0, r1, r0          r0 = a - b
//
// This is a *stack machine*, and it is why the recursion can't go wrong:
// each genExpr leaves the stack exactly as it found it. The code is
// slow (real compilers keep values in registers, which is the whole art
// of the "optimizing" in optimizing compiler), but it is correct, and
// about 300 lines.
//
// VARIABLES live in memory. Each function call gets a *frame* on the
// stack for its locals, and one register, fp (r11), points at it for as
// long as the function runs:
//
//         higher addresses
//       │ ...the caller's frame │
//       │ saved lr              │   so we can return
//       │ saved fp              │ <- fp       so the caller gets its fp back
//       │ local 0               │    fp - 4
//       │ local 1               │    fp - 8
//       │ ...                   │ <- sp       (pushes go below here)
//
// So a local is "the word at fp minus something", where the something is
// fixed when the function is compiled. The code for a function starts by
// building this (the *prologue*) and ends by taking it down again.
//
// To read or write a variable, the generator first makes its ADDRESS
// (genAddr), then loads from it or stores to it. That detour pays off at
// once: `*p = 5` and `&x` need nothing new. Whatever can stand on the
// left of an `=` is whatever genAddr can make an address for.
//
// CALLS follow the ARM convention, so that C can call your assembly and
// the other way round: the first four arguments go in r0 to r3, the
// result comes back in r0, and `bl` leaves the return address in lr.
// A function may destroy r0 to r3 and r12. Everything else, and the
// stack, it must leave as it found it.
//
// CONTROL FLOW is compare-and-branch around labels the generator makes
// up (.L1, .L2, ...):
//
//     if (c) A else B        <c>  cmp r0, #0  beq .Lelse   <A>  b .Lend
//                            .Lelse:  <B>   .Lend:
//
// The tests compile small C programs, assemble them with 216, run them
// on 218's emulator, and look at what main() returned.
//
// YOUR TASK: the pieces of CGen marked below.
//
const std = @import("std");

//@export c_gen
const CGen = struct {
    out: *std.Io.Writer,
    alloc: std.mem.Allocator,
    unit: *const CUnit,
    /// The function being generated, and how far below fp each of its
    /// locals is.
    f: *const CFunction = undefined,
    offsets: []u32 = &.{},
    /// Labels handed out so far.
    labels: u32 = 0,
    /// Where `return`, `break` and `continue` jump to right now.
    return_label: u32 = 0,
    break_label: ?u32 = null,
    continue_label: ?u32 = null,
    /// The string constants met so far: they are written out at the end.
    strings: std.ArrayList([]const u8) = .empty,

    /// One instruction.
    fn emit(g: *CGen, comptime fmt: []const u8, args: anytype) !void {
        try g.out.print("        " ++ fmt ++ "\n", args);
    }

    fn newLabel(g: *CGen) u32 {
        g.labels += 1;
        return g.labels;
    }

    fn place(g: *CGen, label: u32) !void {
        try g.out.print(".L{d}:\n", .{label});
    }

    fn push(g: *CGen) !void {
        try g.emit("str r0, [sp, #-4]!", .{});
    }

    fn pop(g: *CGen, reg: u32) !void {
        try g.emit("ldr r{d}, [sp], #4", .{reg});
    }

    /// reg = value. mov can only make "8 bits, rotated" (214); mvn makes
    /// the inverses of those; anything else comes from the literal pool.
    fn constant(g: *CGen, reg: u32, value: u32) !void {
        if (encodeImm(value) != null) {
            try g.emit("mov r{d}, #{d}", .{ reg, value });
        } else if (encodeImm(~value) != null) {
            try g.emit("mvn r{d}, #{d}", .{ reg, ~value });
        } else {
            try g.emit("ldr r{d}, =0x{x}", .{ reg, value });
        }
    }

    /// The type of something that lives in memory. A name that was never
    /// declared is taken for an int.
    fn typeOfTarget(g: *const CGen, e: *const CExpr) CType {
        switch (e.*) {
            .local => |n| return g.f.locals[n].type,
            .global => |name| {
                for (g.unit.globals) |v| {
                    if (std.mem.eql(u8, v.name, name)) return v.type;
                }
                return .int;
            },
            .deref => |d| return if (d.byte) .char else .int,
            else => return .int,
        }
    }

    /// Writes code that leaves the ADDRESS of e in r0.
    fn genAddr(g: *CGen, e: *const CExpr) anyerror!void {
        switch (e.*) {
            .local => |n| {
                const offset = g.offsets[n];
                if (encodeImm(offset) != null) {
                    try g.emit(⟪"sub r0, fp, #{d}"|||???⟫, .{offset});
                } else {
                    try g.constant(0, offset);
                    try g.emit("sub r0, fp, r0", .{});
                }
            },
            .global => |name| try g.emit("ldr r0, ={s}", .{name}),
            // The address of *p is... the value of p.
            .deref => |d| try ⟪g.genExpr(d.arg)|||???⟫,
            .index => return error.NotLowered, // 228 turns a[i] into *(a + i)
            else => return error.NotAssignable,
        }
    }

    /// Writes code that leaves the VALUE of e in r0.
    fn genExpr(g: *CGen, e: *const CExpr) anyerror!void {
        switch (e.*) {
            .num => |n| try g.constant(0, n),
            .str => |s| {
                try g.emit("ldr r0, =.Lstr{d}", .{g.strings.items.len});
                try g.strings.append(g.alloc, s);
            },
            .local, .global, .deref => {
                try g.genAddr(e);
                switch (g.typeOfTarget(e)) {
                    .array => {}, // an array's value IS its address (228)
                    .char => try g.emit("ldrb r0, [r0]", .{}),
                    else => try g.emit("ldr r0, [r0]", .{}),
                }
            },
            .index => return error.NotLowered,
            .addr => |target| try g.genAddr(target),
            .unary => |u| {
                try g.genExpr(u.arg);
                switch (u.op) {
                    .neg => try g.emit("rsb r0, r0, #0", .{}),
                    .not => try g.emit("mvn r0, r0", .{}),
                    .lnot => {
                        try g.emit("cmp r0, #0", .{});
                        try g.emit("moveq r0, #1", .{});
                        try g.emit("movne r0, #0", .{});
                    },
                }
            },
            .binary => |b| switch (b.op) {
                .log_and => {
                    // If the left side is 0, the answer is that 0, and
                    // the right side must not even run.
                    const end = g.newLabel();
                    try g.genExpr(b.lhs);
                    try g.emit("cmp r0, #0", .{});
                    try g.emit("beq .L{d}", .{end});
                    try g.genExpr(b.rhs);
                    try g.emit("cmp r0, #0", .{});
                    try g.emit("movne r0, #1", .{});
                    try g.place(end);
                },
                .log_or => {
                    const one = g.newLabel();
                    const end = g.newLabel();
                    try g.genExpr(b.lhs);
                    try g.emit("cmp r0, #0", .{});
                    try g.emit("bne .L{d}", .{one});
                    try g.genExpr(b.rhs);
                    try g.emit("cmp r0, #0", .{});
                    try g.emit("beq .L{d}", .{end});
                    try g.place(one);
                    try g.emit("mov r0, #1", .{});
                    try g.place(end);
                },
                else => {
                    // the stack machine: left, push, right, pop
                    try g.genExpr(b.lhs);
                    try g.push();
                    try g.genExpr(b.rhs);
                    try g.pop(1);
                    try g.genOperator(b.op);
                },
            },
            .assign => |a| {
                // the address waits on the stack while the value is worked out
                try g.genAddr(a.target);
                try g.push();
                try g.genExpr(a.value);
                try g.pop(1);
                if (g.typeOfTarget(a.target) == .char) {
                    try g.emit("strb r0, [r1]", .{});
                    // the value of `c = 300` is what c now holds: 44
                    try g.emit("and r0, r0, #255", .{});
                } else {
                    try g.emit(⟪"str r0, [r1]"|||???⟫, .{});
                }
                // r0 still holds the value: that is what `a = b = c` needs
            },
            .call => |c| {
                if (c.args.len > 4) return error.TooManyArguments;
                // Work the arguments out one by one, onto the stack. (Not
                // straight into r0 to r3: working out the second argument
                // would destroy the first.)
                for (c.args) |arg| {
                    try g.genExpr(arg);
                    try g.push();
                }
                // Then pop them into place. The LAST one pushed is on top.
                var reg = c.args.len;
                while (reg > 0) {
                    reg -= 1;
                    try g.pop(⟪@intCast(reg)|||???⟫);
                }
                try g.emit("bl {s}", .{c.name});
            },
            .cast => |c| {
                try g.genExpr(c.arg);
                if (c.to == .char) try g.emit("and r0, r0, #255", .{});
            },
        }
    }

    /// The left value is in r1, the right one in r0. The result goes to r0.
    fn genOperator(g: *CGen, op: CBinary) !void {
        switch (op) {
            .add => try g.emit("add r0, r1, r0", .{}),
            .sub => try g.emit(⟪"sub r0, r1, r0"|||???⟫, .{}),
            .mul => try g.emit("mul r0, r1, r0", .{}),
            .div, .mod => {
                // The processor can't divide. A function does it (230),
                // and wants the left value in r0 and the right in r1.
                try g.emit("mov r2, r0", .{});
                try g.emit("mov r0, r1", .{});
                try g.emit("mov r1, r2", .{});
                try g.emit("bl {s}", .{if (op == .div) "__divsi3" else "__modsi3"});
            },
            .shl => try g.emit("mov r0, r1, lsl r0", .{}),
            .shr => try g.emit("mov r0, r1, asr r0", .{}),
            .bit_and => try g.emit("and r0, r1, r0", .{}),
            .bit_xor => try g.emit("eor r0, r1, r0", .{}),
            .bit_or => try g.emit("orr r0, r1, r0", .{}),
            .lt, .le, .gt, .ge, .eq, .ne => {
                // A comparison's value is 1 or 0: compare, assume 0, and
                // then conditionally make it 1. The condition is the
                // operator's own name: movlt, movle, ...
                try g.emit(⟪"cmp r1, r0"|||???⟫, .{});
                try g.emit("mov r0, #0", .{});
                try g.emit("mov{s} r0, #1", .{@tagName(op)});
            },
            .log_and, .log_or => unreachable,
        }
    }

    fn genStmt(g: *CGen, s: *const CStmt) anyerror!void {
        switch (s.*) {
            .expr => |e| try g.genExpr(e),
            .block => |list| for (list) |inner| try g.genStmt(inner),
            .@"if" => |i| {
                const otherwise = g.newLabel();
                const end = g.newLabel();
                try g.genExpr(i.cond);
                try g.emit("cmp r0, #0", .{});
                try g.emit("beq .L{d}", .{⟪otherwise|||???⟫});
                try g.genStmt(i.then);
                try g.emit("b .L{d}", .{⟪end|||???⟫});
                try g.place(otherwise);
                if (i.otherwise) |o| try g.genStmt(o);
                try g.place(end);
            },
            .loop => |l| {
                //  top:   if the condition is 0, go to end
                //         the body
                //  next:  the step      <- `continue` comes here
                //         go to top
                //  end:                 <- `break` comes here
                const top = g.newLabel();
                const next = g.newLabel();
                const end = g.newLabel();
                const outer_break = g.break_label;
                const outer_continue = g.continue_label;
                g.break_label = end;
                g.continue_label = next;
                try g.place(top);
                if (l.cond) |cond| {
                    try g.genExpr(cond);
                    try g.emit("cmp r0, #0", .{});
                    try g.emit("beq .L{d}", .{end});
                }
                try g.genStmt(l.body);
                try g.place(next);
                if (l.step) |st| try g.genExpr(st);
                try g.emit("b .L{d}", .{⟪top|||???⟫});
                try g.place(end);
                g.break_label = outer_break;
                g.continue_label = outer_continue;
            },
            .ret => |value| {
                if (value) |v| try g.genExpr(v);
                try g.emit("b .L{d}", .{g.return_label});
            },
            .brk => try g.emit("b .L{d}", .{g.break_label orelse return error.NotInLoop}),
            .cont => try g.emit("b .L{d}", .{g.continue_label orelse return error.NotInLoop}),
        }
    }

    fn genFunction(g: *CGen, f: *const CFunction) !void {
        if (f.params > 4) return error.TooManyArguments;
        g.f = f;
        g.return_label = g.newLabel();
        // Lay out the frame: each local goes below the ones before it.
        // Everything takes a multiple of 4 bytes, so words stay aligned.
        g.offsets = try g.alloc.alloc(u32, f.locals.len);
        var frame_size: u32 = 0;
        for (f.locals, g.offsets) |v, *offset| {
            frame_size += alignUp(cSizeOf(v.type), 4);
            offset.* = ⟪frame_size|||???⟫;
        }

        try g.out.print("{s}:\n", .{f.name});
        // the prologue
        try g.emit("str lr, [sp, #-4]!", .{});
        try g.emit("str fp, [sp, #-4]!", .{});
        try g.emit("mov fp, sp", .{});
        if (encodeImm(frame_size) != null) {
            try g.emit("sub sp, sp, #{d}", .{frame_size});
        } else {
            try g.constant(12, frame_size);
            try g.emit("sub sp, sp, r12", .{});
        }
        // the parameters arrive in registers, and are locals like any other
        for (0..f.params) |n| {
            try g.emit("str r{d}, [fp, #-{d}]", .{ n, g.offsets[n] });
        }
        try g.genStmt(f.body);
        // The epilogue: drop the locals, restore fp, and pop the return
        // address straight into pc.
        try g.place(g.return_label);
        try g.emit("mov sp, fp", .{});
        try g.emit("ldr fp, [sp], #4", .{});
        try g.emit("ldr pc, [sp], #4", .{});
        try g.emit(".ltorg", .{}); // the function's constants: nothing runs into them here
    }

    /// The value of a global's initializer, if it is a number.
    fn constantValue(e: *const CExpr) ?u32 {
        return switch (e.*) {
            .num => |n| n,
            .unary => |u| blk: {
                const v = constantValue(u.arg) orelse break :blk null;
                break :blk switch (u.op) {
                    .neg => 0 -% v,
                    .not => ~v,
                    .lnot => @intFromBool(v == 0),
                };
            },
            .cast => |c| constantValue(c.arg),
            else => null,
        };
    }

    fn genGlobal(g: *CGen, v: CGlobal) !void {
        if (v.external) return; // somebody else's: the linker will find it
        try g.out.print("{s}:\n", .{v.name});
        if (v.init) |init| {
            if (init.* == .str and v.type == .array) {
                // char s[16] = "hi": the characters themselves, then zeros
                const len = cStringLength(init.str);
                const size = cSizeOf(v.type);
                if (v.type.array.elem.* != .char or len + 1 > size) return error.BadInitializer;
                try g.emit(".asciz \"{s}\"", .{init.str});
                if (size > len + 1) try g.emit(".space {d}", .{size - len - 1});
            } else if (init.* == .str) {
                try g.emit(".word .Lstr{d}", .{g.strings.items.len});
                try g.strings.append(g.alloc, init.str);
            } else {
                const value = constantValue(init) orelse return error.NotConstant;
                try g.emit("{s} 0x{x}", .{ if (v.type == .char) ".byte" else ".word", value });
            }
        } else {
            try g.emit(".space {d}", .{cSizeOf(v.type)});
        }
        try g.emit(".align 2", .{});
    }
};

/// How many characters the text of a string literal stands for: each
/// escape (\n, \", ...) is two characters of text and one of string.
fn cStringLength(text: []const u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') i += 1;
        n += 1;
    }
    return n;
}

/// The assembly for a parsed file. The caller frees it.
fn cGenerate(alloc: std.mem.Allocator, unit: *const CUnit) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var g: CGen = .{ .out = &out.writer, .alloc = arena.allocator(), .unit = unit };
    for (unit.functions) |*f| try g.genFunction(f);
    for (unit.globals) |v| try g.genGlobal(v);
    for (g.strings.items, 0..) |s, n| {
        try out.writer.print(".Lstr{d}:\n        .asciz \"{s}\"\n        .align 2\n", .{ n, s });
    }
    return out.toOwnedSlice();
}

/// What runs first: set up a stack at the top of 64 KB, call main, and
/// stop. main's result is left in r0.
const c_start =
    \\_start: mov   sp, #0x10000
    \\        bl    main
    \\        swi   0
    \\
;

const CRun = struct { result: u32, output: []u8 };

/// Assembles `asm_source` (after c_start), runs it on the emulator with
/// `input` at the UART, and returns main's result and what was sent. The
/// caller frees the output.
fn runAssembly(gpa: std.mem.Allocator, asm_source: []const u8, input: []const u8) !CRun {
    const whole = try std.mem.concat(gpa, u8, &.{ c_start, asm_source });
    defer gpa.free(whole);
    var line_no: usize = 0;
    var prog = assemble(gpa, whole, 0, &line_no) catch |err| {
        var lines = std.mem.splitScalar(u8, whole, '\n');
        var n: usize = 1;
        while (lines.next()) |text| : (n += 1) {
            if (n == line_no) std.debug.print("the assembler says {s} about line {d} of the compiler's output:\n{s}\n", .{ @errorName(err), n, text });
        }
        return err;
    };
    defer prog.deinit(gpa);
    var board = try Board.init(gpa, 0x10000);
    defer board.deinit();
    board.load(0, prog.code);
    board.uart_in = input;
    var cpu: Cpu = .{};
    const event = cpu.run(&board, 5_000_000) orelse return error.RanTooLong;
    if (event != .swi) {
        std.debug.print("the program stopped at pc = 0x{x}: {any}\n", .{ cpu.r[PC], event });
        return error.ProgramCrashed;
    }
    return .{ .result = cpu.r[0], .output = try gpa.dupe(u8, board.uart_out.items) };
}
//@end

const ta = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

/// Compiles and runs a C program. What did main return?
fn run(source: []const u8) !u32 {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    var line: u32 = 0;
    const unit = cParse(arena.allocator(), source, &line) catch |err| {
        std.debug.print("line {d} of the C: {s}\n", .{ line, @errorName(err) });
        return err;
    };
    const text = try cGenerate(ta, &unit);
    defer ta.free(text);
    const ran = try runAssembly(ta, text, "");
    defer ta.free(ran.output);
    return ran.result;
}

fn expectMain(want: i32, comptime body: []const u8) !void {
    try expectEqual(@as(u32, @bitCast(want)), try run("int main() { " ++ body ++ " }"));
}

test "numbers and arithmetic" {
    try expectMain(42, "return 42;");
    try expectMain(7, "return 1 + 2 * 3;");
    try expectMain(9, "return (1 + 2) * 3;");
    try expectMain(-4, "return 1 - 2 - 3;");
    try expectMain(2, "return 1 - (2 - 3);");
    try expectMain(0x12345678, "return 0x12345678;");
    try expectMain(-1, "return -1;");
    try expectMain(1000, "return 1000;");
    try expectMain(-1000, "return -1000;");
    try expectMain(40, "return 5 << 3;");
    try expectMain(-2, "return -16 >> 3;");
    try expectMain(1, "return 13 & 3;");
    try expectMain(15, "return 12 | 3;");
    try expectMain(6, "return 5 ^ 3;");
    try expectMain(-6, "return ~5;");
    try expectMain(5, "return - -5;");
}

test "comparisons and logic" {
    try expectMain(1, "return 1 < 2;");
    try expectMain(0, "return 2 < 1;");
    try expectMain(0, "return 2 < 2;");
    try expectMain(1, "return 2 <= 2;");
    try expectMain(1, "return 3 > 2;");
    try expectMain(0, "return 2 > 3;");
    try expectMain(1, "return 2 >= 2;");
    try expectMain(0, "return 1 >= 2;");
    try expectMain(1, "return -1 < 1;"); // ints are signed
    try expectMain(1, "return 3 == 3;");
    try expectMain(0, "return 3 == 4;");
    try expectMain(1, "return 3 != 4;");
    try expectMain(1, "return !0;");
    try expectMain(0, "return !7;");
    try expectMain(1, "return 2 && 3;");
    try expectMain(0, "return 2 && 0;");
    try expectMain(0, "return 0 && 3;");
    try expectMain(1, "return 0 || 3;");
    try expectMain(1, "return 2 || 0;");
    try expectMain(0, "return 0 || 0;");
    try expectMain(6, "return 1 + 2 * (3 > 2) + 3 * (4 == 4);");
}

test "local variables" {
    try expectMain(3, "int a = 1; int b = 2; return a + b;");
    try expectMain(12, "int a; int b; a = b = 6; return a + b;");
    try expectMain(6, "int a = 5; a += 3; a++; ++a; a -= 2; a--; --a; return a;");
    try expectMain(5, "int a = 5; int b = a++; return b;");
    try expectMain(6, "int a = 5; int b = ++a; return b;");
    try expectMain(1, "int a = 1; { int a = 2; a = 3; } return a;");
    try expectMain(44, "char c = 300; return c;"); // a char keeps 8 bits
    try expectMain(44, "return (char)300;");
    // enough locals that a plain `sub r0, fp, #n` can't reach the last
    try expectMain(1107, "int a[300]; int b = 1100; int c = 7; return b + c;");
}

test "short circuits: the right side must not run" {
    try expectMain(10, "int a = 10; 0 && (a = 20); return a;");
    try expectMain(20, "int a = 10; 1 && (a = 20); return a;");
    try expectMain(10, "int a = 10; 1 || (a = 20); return a;");
    try expectMain(20, "int a = 10; 0 || (a = 20); return a;");
}

test "if, while, for" {
    try expectMain(1, "if (2 > 1) return 1; return 2;");
    try expectMain(2, "if (2 < 1) return 1; return 2;");
    try expectMain(3, "if (0) return 1; else if (0) return 2; else return 3;");
    try expectMain(7, "int a = 0; if (1) a = 7; else a = 8; return a;");
    try expectMain(8, "int a = 0; if (0) a = 7; else a = 8; return a;");
    try expectMain(55, "int s = 0; int i = 1; while (i <= 10) { s += i; i++; } return s;");
    try expectMain(55, "int s = 0; for (int i = 1; i <= 10; i++) s += i; return s;");
    try expectMain(0, "int s = 0; for (int i = 5; i < 5; i++) s += 1; return s;");
    try expectMain(12, "int s = 0; for (int i = 0; i < 4; i++) for (int j = 0; j < 3; j++) s++; return s;");
}

test "break and continue" {
    try expectMain(5, "int i = 0; while (1) { if (i == 5) break; i++; } return i;");
    // continue in a for still runs the step: 1 + 3 + 5 + 7 + 9
    try expectMain(25, "int s = 0; for (int i = 0; i < 10; i++) { if ((i & 1) == 0) continue; s += i; } return s;");
    // break leaves only the inner loop
    try expectMain(30, "int s = 0; for (int i = 0; i < 10; i++) { for (int j = 0; j < 10; j++) { if (j == 3) break; s++; } } return s;");
    // and after an inner loop, continue belongs to the outer one again
    try expectMain(4, "int s = 0; for (int i = 0; i < 8; i++) { while (0) { } if (i & 1) continue; s++; } return s;");
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const unit = try cParse(arena.allocator(), "int main() { break; }", null);
    try expectError(error.NotInLoop, cGenerate(ta, &unit));
}

test "functions" {
    try expectEqual(@as(u32, 42), try run(
        \\int answer() { return 42; }
        \\int main() { return answer(); }
    ));
    // the order of the arguments, and arguments that are calls themselves
    try expectEqual(@as(u32, 1234), try run(
        \\int digits(int a, int b, int c, int d) { return a * 1000 + b * 100 + c * 10 + d; }
        \\int one() { return 1; }
        \\int main() { return digits(one(), one() + one(), 3, digits(0, 0, 0, 4)); }
    ));
    try expectEqual(@as(u32, 9), try run(
        \\int sub(int a, int b) { return a - b; }
        \\int main() { return sub(10, sub(3, 2)); }
    ));
    // recursion: every call has its own frame
    try expectEqual(@as(u32, 3628800), try run(
        \\int fact(int n) { if (n < 2) return 1; return n * fact(n - 1); }
        \\int main() { return fact(10); }
    ));
    try expectEqual(@as(u32, 610), try run(
        \\int fib(int n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); }
        \\int main() { return fib(15); }
    ));
    // a caller's locals survive a call
    try expectEqual(@as(u32, 77), try run(
        \\int clobber(int a, int b, int c, int d) { int x = 1; int y = 2; int z = 3; return 0; }
        \\int main() { int a = 70; int b = 7; clobber(9, 9, 9, 9); return a + b; }
    ));
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const unit = try cParse(arena.allocator(), "int main() { return f(1, 2, 3, 4, 5); }", null);
    try expectError(error.TooManyArguments, cGenerate(ta, &unit));
}

test "globals, addresses, and assigning through a pointer" {
    try expectEqual(@as(u32, 15), try run(
        \\int count = 5;
        \\int total;
        \\int bump() { count = count + 1; total += count; return 0; }
        \\int main() { bump(); bump(); return total + (count == 7) * 2; }
    ));
    try expectEqual(@as(u32, 21), try run(
        \\int swap(int *a, int *b) { int t = *a; *a = *b; *b = t; return 0; }
        \\int main() { int x = 1; int y = 2; swap(&x, &y); return x * 10 + y; }
    ));
    try expectEqual(@as(u32, 9), try run(
        \\int g = 4;
        \\int main() { int *p = &g; int **pp = &p; **pp = **pp + 5; return g; }
    ));
    try expectEqual(@as(u32, 124), try run(
        \\char *text = "hello";
        \\int limit = -4;
        \\char flag = 'x';
        \\int main() { if (text == 0 || "" == 0) return 0; return flag - limit; }
    ));
    // a[i] has to wait for 228
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const unit = try cParse(arena.allocator(), "int main() { int a[2]; return a[0]; }", null);
    try expectError(error.NotLowered, cGenerate(ta, &unit));
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include c_lex
//@include c_expr
//@include c_parse
//@include arm_enc
//@include arm_alu
//@include arm_asm_line
//@include arm_asm
//@include arm_emu
