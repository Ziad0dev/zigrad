//
// ─── Exercise 244: one copy of the library for everyone ───────────────
//
// 229's linker copies everything a program needs into the program.
// Every program that prints gets its own copy of print_int, of the
// division routine, of malloc and its heap. With a hundred programs on
// a disk, that is the same library a hundred times, and a bug in it is
// fixed by relinking a hundred programs. The outline calls the cure
// "space saving dynamic linking":
//
//     keep the library in ONE place, load it once, and let every
//     program find its functions at run time.
//
// The difficulty is the one from 229 again: a call needs an address,
// and now the address isn't known even when the program is linked.
// The classic answer has two parts.
//
// THE DETOUR. For every function a program imports, the linker invents
// a tiny function of the same name inside the program. A call to
// `puts` goes there, like any call within the file. The little function
// does one thing: jump to whatever address is stored in a word next to
// it, its *slot*. Fill in the slot, and every call in the program finds
// the real puts. (This table of little functions is the PLT, the
// "procedure linkage table"; the slots are the GOT.)
//
// LAZINESS. Who fills in the slots, and when? Filling them all in at
// start-up works, but most programs never call most of what they
// import. So each slot starts out pointing, not at the library, but at
// two more instructions right behind it, which ask the system's
// *dynamic linker* for help:
//
//     puts:     ldr  pc, slot       jump to wherever the slot says
//     slot:     .word stub          at first: just below
//     stub:     mov  r12, #3        "import number 3, please"
//               swi  0xd1           ask the dynamic linker
//
// The dynamic linker looks the name up in the library, writes the
// address into the slot, and jumps there itself. The function runs and
// returns to the original caller (lr was never touched). From then on,
// a call to `puts` is the detour's single `ldr pc`: the stub is never
// reached again.
//
// (r12 is the register the ARM convention sets aside for exactly this:
// a call may destroy it. Everything else must arrive untouched, since
// the arguments are in r0 to r3.)
//
// Here the dynamic linker is Zig, standing in for the operating system,
// and the library is 230's libc, linked once at 0x8000.
//
// YOUR TASK: the four lines of a PLT entry, and the dynamic linker.
//
const std = @import("std");

//@export dynlink
const dynamic_swi = 0xd1;
const library_base: u32 = 0x8000;

/// Writes the PLT entry for import number `n`, called `name`, as
/// assembly: the four lines in the picture above. The slot and the stub
/// need labels that no other entry uses: .Lslot{n} and .Lstub{n} (they
/// start with .L, so the linker keeps them private). `ldr pc, label`
/// loads the word AT a label.
fn writePltEntry(w: *std.Io.Writer, name: []const u8, n: usize) !void {
    //⟪
    try w.print("{s}:\n", .{name});
    try w.print("        ldr   pc, .Lslot{d}\n", .{n});
    try w.print(".Lslot{d}: .word .Lstub{d}\n", .{ n, n });
    try w.print(".Lstub{d}: mov r12, #{d}\n", .{ n, n });
    try w.print("        swi   {d}\n", .{dynamic_swi});
    //|||
    _ = .{ w, name, n };
    ???;
    //⟫
}

/// A program that still needs a library.
const DynamicProgram = struct {
    code: []u8,
    /// The functions it imports, in PLT order.
    imports: [][]const u8,
    /// Where the PLT begins in the program. Each entry is 16 bytes.
    plt: u32,
    arena: std.heap.ArenaAllocator,

    fn deinit(p: *DynamicProgram) void {
        p.arena.deinit();
    }

    /// The address of import n's slot.
    fn slot(p: *const DynamicProgram, n: usize) u32 {
        return p.plt + 16 * @as(u32, @intCast(n)) + 4;
    }
};

/// Links objects into a program at address 0, leaving every function
/// that none of them defines to be found at run time.
fn linkDynamic(gpa: std.mem.Allocator, objects: []const Object) !DynamicProgram {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    // the imports: names that are called but defined nowhere
    var imports: std.ArrayList([]const u8) = .empty;
    for (objects) |o| {
        for (o.relocs) |reloc| {
            const defined = for (objects) |other| {
                if (other.find(reloc.name) != null) break true;
            } else false;
            const listed = for (imports.items) |have| {
                if (std.mem.eql(u8, have, reloc.name)) break true;
            } else false;
            if (defined or listed) continue;
            if (reloc.kind != .call24) return error.ImportedData; // only functions can take the detour
            try imports.append(alloc, try alloc.dupe(u8, reloc.name));
        }
    }
    // The PLT is one more object file, which the linker writes itself.
    var plt_text: std.Io.Writer.Allocating = .init(alloc);
    for (imports.items, 0..) |name, n| try writePltEntry(&plt_text.writer, name, n);
    var all: std.ArrayList(Object) = .empty;
    try all.appendSlice(alloc, objects);
    try all.append(alloc, try assembleObject(alloc, plt_text.written(), null));
    const image = try linkObjects(alloc, all.items, 0, null);
    const plt = if (imports.items.len > 0) image.symbols.get(imports.items[0]).? else 0;
    return .{ .code = image.code, .imports = imports.items, .plt = plt, .arena = arena };
}

/// The library, linked once, and where its functions are.
const Library = struct {
    image: Image,
    arena: std.heap.ArenaAllocator,

    fn deinit(l: *Library) void {
        l.arena.deinit();
    }
};

/// Compiles C files into objects, in `alloc` (an arena).
fn compileObjects(alloc: std.mem.Allocator, c_files: []const []const u8) ![]Object {
    const objects = try alloc.alloc(Object, c_files.len);
    for (c_files, objects) |source, *o| o.* = try assembleObject(alloc, try cCompile(alloc, source, null), null);
    return objects;
}

fn buildLibrary(gpa: std.mem.Allocator, c_files: []const []const u8) !Library {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const objects = try compileObjects(arena.allocator(), c_files);
    return .{ .image = try linkObjects(arena.allocator(), objects, library_base, null), .arena = arena };
}

const DynamicRun = struct {
    result: u32,
    output: []u8,
    /// How many times the dynamic linker was asked.
    lookups: usize,
};

/// Runs a program with the library loaded beside it. The caller frees
/// the output.
fn runDynamic(gpa: std.mem.Allocator, program: *const DynamicProgram, library: *const Library) !DynamicRun {
    var board = try Board.init(gpa, 0x10000);
    defer board.deinit();
    board.load(0, program.code);
    board.load(library_base, library.image.code);
    var cpu: Cpu = .{};
    var lookups: usize = 0;
    for (0..20_000_000) |_| {
        switch (cpu.step(&board)) {
            .ok => {},
            .swi => |number| {
                if (number != dynamic_swi) return .{ .result = cpu.r[0], .output = try gpa.dupe(u8, board.uart_out.items), .lookups = lookups };
                // The dynamic linker. r12 says which import; find it in
                // the library; from now on the slot leads straight
                // there; and so do we, this once.
                lookups += 1;
                const n = cpu.r[12];
                if (n >= program.imports.len) return error.BadImport;
                //⟪
                const address = library.image.symbols.get(program.imports[n]) orelse return error.SymbolNotInLibrary;
                try board.write(program.slot(n), 4, address);
                cpu.r[PC] = address;
                //|||
                ???;
                //⟫
            },
            else => return error.ProgramCrashed,
        }
    }
    return error.RanTooLong;
}
//@end

const ta = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

/// A program from C files, linked dynamically (with c_start in front).
fn buildDynamic(c_files: []const []const u8) !DynamicProgram {
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const alloc = arena.allocator();
    var objects: std.ArrayList(Object) = .empty;
    try objects.append(alloc, try assembleObject(alloc, c_start, null));
    try objects.appendSlice(alloc, try compileObjects(alloc, c_files));
    return linkDynamic(ta, objects.items);
}

const hello_c =
    \\int main() {
    \\    puts("six times seven is ");
    \\    print_int(6 * 7);
    \\    putchar('\n');
    \\    return strlen("four");
    \\}
;

test "a PLT entry" {
    var text: std.Io.Writer.Allocating = .init(ta);
    defer text.deinit();
    try writePltEntry(&text.writer, "puts", 3);
    var prog = try assemble(ta, text.written(), 0x100, null);
    defer prog.deinit(ta);
    try expectEqual(@as(usize, 16), prog.code.len);
    try expectEqual(@as(u32, 0x100), try prog.syms.get("puts"));
    try expectEqual(@as(u32, 0xe51ff004), prog.word(0x100)); // ldr pc, [pc, #-4]: the next word
    try expectEqual(@as(u32, 0x108), prog.word(0x104)); // the slot: at first, the stub
    try expectEqual(@as(u32, 0xe3a0c003), prog.word(0x108)); // mov r12, #3
    try expectEqual(@as(u32, 0xef0000d1), prog.word(0x10c)); // swi 0xd1
}

test "a program that brings no library of its own" {
    var library = try buildLibrary(ta, &.{libc_c});
    defer library.deinit();
    var program = try buildDynamic(&.{hello_c});
    defer program.deinit();
    try expectEqual(@as(usize, 4), program.imports.len);
    try expectEqualStrings("puts", program.imports[0]);
    try expectEqualStrings("strlen", program.imports[3]);
    const ran = try runDynamic(ta, &program, &library);
    defer ta.free(ran.output);
    try expectEqualStrings("six times seven is 42\n", ran.output);
    try expectEqual(@as(u32, 4), ran.result);
    try expectEqual(@as(usize, 4), ran.lookups);

    // the space saved: the same program with its own copy of the library
    const static = try buildProgram(ta, &.{ hello_c, libc_c }, &.{}, 0);
    defer ta.free(static);
    try expect(program.code.len < 400);
    try expect(static.len > 20 * program.code.len);
}

test "lazy: each import is looked up once, and only if it is called" {
    var library = try buildLibrary(ta, &.{libc_c});
    defer library.deinit();
    var program = try buildDynamic(&.{
        \\int main() {
        \\    for (int i = 0; i < 50; i++) putchar('a' + i % 26);
        \\    if (strlen("") == 1) { print_int(1); print_hex(1); malloc(1); }
        \\    return 0;
        \\}
    });
    defer program.deinit();
    // imported: putchar, strlen, print_int, print_hex, malloc, and __modsi3 for the %
    try expectEqual(@as(usize, 6), program.imports.len);
    const ran = try runDynamic(ta, &program, &library);
    defer ta.free(ran.output);
    try expectEqual(@as(usize, 50), ran.output.len);
    try expectEqualStrings("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwx", ran.output);
    // 50 calls to putchar and 50 to __modsi3, one to strlen: three lookups
    try expectEqual(@as(usize, 3), ran.lookups);
}

test "arguments and results pass through the detour untouched" {
    var library = try buildLibrary(ta, &.{
        \\int mix(int a, int b, int c, int d) { return a * 1000 + b * 100 + c * 10 + d; }
        \\int twice(int n) { return mix(0, 0, n, n) * 2; }
    });
    defer library.deinit();
    var program = try buildDynamic(&.{
        \\int main() { return mix(1, 2, 3, 4) + mix(4, 3, 2, 1) + twice(1); }
    });
    defer program.deinit();
    const ran = try runDynamic(ta, &program, &library);
    defer ta.free(ran.output);
    try expectEqual(@as(u32, 1234 + 4321 + 22), ran.result);
    try expectEqual(@as(usize, 2), ran.lookups);
}

test "what the library doesn't have" {
    var library = try buildLibrary(ta, &.{libc_c});
    defer library.deinit();
    var program = try buildDynamic(&.{"int main() { return launch_missiles(3); }"});
    defer program.deinit();
    try expectError(error.SymbolNotInLibrary, runDynamic(ta, &program, &library));
    // a variable can't be imported through a table of functions
    try expectError(error.ImportedData, buildDynamic(&.{"extern int somewhere; int main() { return somewhere; }"}));
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
//@include linker
//@include libc
//@include arm_enc
//@include arm_alu
//@include arm_asm_line
//@include arm_asm
//@include arm_emu
