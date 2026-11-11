//
// ─── Exercise 230: a C library ────────────────────────────────────────
//
// A C compiler gives you a language with nothing in it. No printing, no
// strings, no memory to ask for: C the language has none of these.
// They are ordinary functions, written in C, that somebody had to
// write once and that every program is linked against. That is libc,
// and with a linker (229) you can have one. Here is the outline's
// promise coming true: this exercise is not Zig. The holes are C,
// compiled by your compiler.
//
// Four things a library has to provide, smallest first:
//
// DIVISION. Your processor has no divide instruction (ARM had none until
// 2004), and 227 compiles `/` and `%` into calls: __divsi3 and __modsi3,
// the very names GCC and LLVM call. So division is a library function,
// and it is the long division you learned at school, in binary, where
// each digit of the answer is 0 or 1:
//
//     for each bit of n, from the top:
//         bring it down:  r = r * 2 + that bit
//         if d goes into r:  subtract it, and this bit of q is 1
//
// STRINGS. A C string is a pointer to bytes that end with a 0. Nothing
// stores its length: every function walks until the 0.
//
// INPUT AND OUTPUT. putchar is 222's `putc`, in C: a pointer to the
// UART's registers, a loop that waits for "ready", and a store. That is
// all a device driver is. Everything else is built on putchar.
// Printing a number is the classic: the digits come out of n % 10 last
// digit FIRST, and recursion turns them round for free.
//
// MEMORY. malloc(n) hands out n bytes that nobody else is using, and
// free(p) takes them back. Ours keeps it simple:
//
//     heap       one big array, handed out from the bottom up
//     a block    one word holding its size (in words), then the words
//                the caller gets. malloc returns the address AFTER the
//                size word, and free steps back one word to find it.
//     free list  the blocks that came back, chained through their first
//                word. malloc looks there first, and takes the first
//                block that is big enough ("first fit").
//
// The last test runs a C program on the Verilog computer from 222: C,
// through your compiler, assembler and linker, on your processor.
//
// The C here is the compiler's dialect: int, char, pointers and arrays;
// no structs, no `unsigned`; `extern` for another file's globals; and
// functions take at most four arguments.
//
// YOUR TASK: four functions in C: udiv, strcmp, print_int, and the
// search through the free list in malloc.
//
const std = @import("std");

//@export libc
/// udiv(n, d): n / d for n >= 0 and d > 0, by long division. Work from
/// bit 30 down (bit 31 of a number that isn't negative is 0). Remember
/// that this is the function `/` is made of: it can't use `/` or `%`
/// itself.
//⟪
const libc_udiv =
    \\int udiv(int n, int d) {
    \\    int q = 0;
    \\    int r = 0;
    \\    for (int i = 30; i >= 0; i--) {
    \\        r = (r << 1) | ((n >> i) & 1);
    \\        if (r >= d) {
    \\            r -= d;
    \\            q = q | (1 << i);
    \\        }
    \\    }
    \\    return q;
    \\}
    \\
;
//|||
const libc_udiv = ???;
//⟫

const libc_division =
    \\/* Division, for a processor that has none. */
    \\
++ libc_udiv ++
    \\/* C rounds towards zero: -7 / 2 is -3, and the remainder has the
    \\   sign of the left side: -7 % 2 is -1. (Dividing by 0 gives a
    \\   meaningless number, not an error: C allows that.)
    \\
    \\   One int has no positive twin: -2147483648, whose negation is
    \\   itself. As a divisor it goes into nothing but itself. As the
    \\   left side, one b is taken off it before negating, and counted
    \\   afterwards. */
    \\int __divsi3(int a, int b) {
    \\    int negative = 0;
    \\    int taken = 0;
    \\    if (b < 0) {
    \\        if (b == -b) return a == b;
    \\        b = -b;
    \\        negative = !negative;
    \\    }
    \\    if (a < 0) {
    \\        if (a == -a) { a += b; taken = 1; }
    \\        a = -a;
    \\        negative = !negative;
    \\    }
    \\    int q = udiv(a, b) + taken;
    \\    if (negative) return -q;
    \\    return q;
    \\}
    \\int __modsi3(int a, int b) {
    \\    return a - __divsi3(a, b) * b;      /* what the division left over */
    \\}
    \\
;

/// strcmp(a, b): 0 if the strings are the same; otherwise negative if a
/// comes first in the dictionary, positive if b does. Walk both while
/// their characters are equal, stopping at the end; the answer is the
/// difference of the two characters where the walk stopped.
//⟪
const libc_strcmp =
    \\int strcmp(char *a, char *b) {
    \\    while (*a && *a == *b) {
    \\        a++;
    \\        b++;
    \\    }
    \\    return *a - *b;
    \\}
    \\
;
//|||
const libc_strcmp = ???;
//⟫

const libc_strings =
    \\int strlen(char *s) {
    \\    int n = 0;
    \\    while (s[n]) n++;
    \\    return n;
    \\}
    \\char *strcpy(char *to, char *from) {
    \\    char *start = to;
    \\    while (*to++ = *from++) ;
    \\    return start;
    \\}
    \\char *memcpy(char *to, char *from, int n) {
    \\    for (int i = 0; i < n; i++) to[i] = from[i];
    \\    return to;
    \\}
    \\char *memset(char *to, int value, int n) {
    \\    for (int i = 0; i < n; i++) to[i] = value;
    \\    return to;
    \\}
    \\
++ libc_strcmp;

/// print_int(n): n in decimal, through putchar, with a '-' in front if
/// it is negative. The digit that n % 10 gives is the LAST one: so first
/// print everything before it (that is n / 10, if there is anything),
/// and then this digit. '0' + 7 is the character '7'.
///
/// For a negative n, don't start with n = -n: the most negative int,
/// -2147483648, has no positive twin, and -n is n again. Take its last
/// digit off while it is still negative instead: -257 % 10 is -7, so
/// the digit is '0' - n % 10, and what comes before it is -(n / 10),
/// which is positive and always fits.
//⟪
const libc_print_int =
    \\int print_int(int n) {
    \\    if (n < 0) {
    \\        putchar('-');
    \\        if (n <= -10) print_int(-(n / 10));
    \\        putchar('0' - n % 10);
    \\        return 0;
    \\    }
    \\    if (n >= 10) print_int(n / 10);
    \\    putchar('0' + n % 10);
    \\    return 0;
    \\}
    \\
;
//|||
const libc_print_int = ???;
//⟫

const libc_io =
    \\/* The UART (222): word 0 sends, word 1 is the status, word 2 receives. */
    \\int putchar(int c) {
    \\    int *uart = (int *)0x10000000;
    \\    while ((uart[1] & 1) == 0) ;      /* wait until it can send */
    \\    uart[0] = c;
    \\    return c;
    \\}
    \\int getchar() {
    \\    int *uart = (int *)0x10000000;
    \\    while ((uart[1] & 2) == 0) ;      /* wait until a byte is there */
    \\    return uart[2];
    \\}
    \\int puts(char *s) {
    \\    while (*s) putchar(*s++);
    \\    return 0;
    \\}
    \\int print_hex(int n) {
    \\    for (int shift = 28; shift >= 0; shift -= 4) putchar("0123456789abcdef"[(n >> shift) & 15]);
    \\    return 0;
    \\}
    \\
++ libc_print_int;

/// Inside malloc: the search for a free block of at least `words` words.
/// `link` points at the word that holds the address of the next free
/// block to look at (to begin with, that word is the variable free_list
/// itself). While there is a block there:
///   - if it is big enough (its size is in block[0]): take it out of the
///     chain, by making *link skip to the block after it (block[1]), and
///     return the address of its word 1, as a char *;
///   - otherwise move on: link becomes the address of this block's own
///     "next" word.
//⟪
const libc_first_fit =
    \\    while (*link) {
    \\        int *block = *link;
    \\        if (block[0] >= words) {
    \\            *link = (int *)block[1];
    \\            return (char *)(block + 1);
    \\        }
    \\        link = (int **)(block + 1);
    \\    }
    \\
;
//|||
const libc_first_fit = ???;
//⟫

const libc_memory =
    \\int heap[2048];         /* 8 KB to hand out */
    \\int heap_used;          /* how many of its words have been */
    \\int *free_list;         /* the blocks that came back */
    \\
    \\char *malloc(int bytes) {
    \\    int words = (bytes + 3) >> 2;
    \\    if (words < 1) words = 1;         /* a free block needs one word, for the chain */
    \\    int **link = &free_list;
    \\
++ libc_first_fit ++
    \\    /* nothing fits: cut a new block off the heap */
    \\    if (heap_used + 1 + words > 2048) return 0;
    \\    int *fresh = heap + heap_used;
    \\    heap_used += 1 + words;
    \\    fresh[0] = words;
    \\    return (char *)(fresh + 1);
    \\}
    \\int free(char *p) {
    \\    if (p == 0) return 0;             /* what a failed malloc returned: nothing to give back */
    \\    int *block = (int *)p - 1;        /* back to the size word */
    \\    block[1] = (int)free_list;        /* chain it in at the front */
    \\    free_list = block;
    \\    return 0;
    \\}
    \\
;

/// The library, as one C file.
const libc_c = libc_division ++ libc_strings ++ libc_io ++ libc_memory;

/// Compiles `program` (C), links it with the library, and runs it on the
/// emulator. The caller frees the output.
fn runC(gpa: std.mem.Allocator, program: []const u8, input: []const u8) !CRun {
    const image = try buildProgram(gpa, &.{ program, libc_c }, &.{}, 0);
    defer gpa.free(image);
    return runImage(gpa, image, input);
}
//@end

const ta = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn expectResult(want: i32, program: []const u8) !void {
    const ran = try runC(ta, program, "");
    defer ta.free(ran.output);
    try expectEqual(@as(u32, @bitCast(want)), ran.result);
}

fn expectOutput(want: []const u8, program: []const u8, input: []const u8) !void {
    const ran = try runC(ta, program, input);
    defer ta.free(ran.output);
    try expectEqualStrings(want, ran.output);
}

test "division" {
    try expectResult(3, "int main() { return 7 / 2; }");
    try expectResult(1, "int main() { return 7 % 2; }");
    try expectResult(0, "int main() { return 0 / 5; }");
    try expectResult(0, "int main() { return 3 / 5; }");
    try expectResult(3, "int main() { return 3 % 5; }");
    try expectResult(1, "int main() { return 5 / 5; }");
    try expectResult(0x7fffffff, "int main() { return 0x7fffffff / 1; }");
    try expectResult(1, "int main() { return 0x7fffffff / 0x7fffffff; }");
    try expectResult(0x3fffffff, "int main() { return 0x7fffffff / 2; }");
    try expectResult(0x7ffffffe, "int main() { return 0x7ffffffe % 0x7fffffff; }");
    // a whole table, checked inside the program: a == (a / b) * b + a % b,
    // and the remainder is smaller than b
    try expectResult(0,
        \\int main() {
        \\    int bad = 0;
        \\    for (int a = 0; a < 3000; a += 37) {
        \\        for (int b = 1; b < 40; b += 3) {
        \\            int q = a / b;
        \\            int r = a % b;
        \\            if (q * b + r != a || r < 0 || r >= b) bad++;
        \\        }
        \\    }
        \\    return bad;
        \\}
    );
}

test "division rounds towards zero" {
    try expectResult(-3, "int main() { return -7 / 2; }");
    try expectResult(-3, "int main() { return 7 / -2; }");
    try expectResult(3, "int main() { return -7 / -2; }");
    try expectResult(-1, "int main() { return -7 % 2; }");
    try expectResult(1, "int main() { return 7 % -2; }");
    try expectResult(-1, "int main() { return -7 % -2; }");
}

test "the int with no positive twin" {
    // -2147483648: C can't even write it as a literal
    const lowest = "int main() { int lowest = -0x7fffffff - 1; ";
    try expectResult(-214748364, lowest ++ "return lowest / 10; }");
    try expectResult(214748364, lowest ++ "return lowest / -10; }");
    try expectResult(-8, lowest ++ "return lowest % 10; }");
    try expectResult(-8, lowest ++ "return lowest % -10; }");
    try expectResult(-0x40000000, lowest ++ "return lowest / 2; }");
    try expectResult(std.math.minInt(i32), lowest ++ "return lowest / 1; }");
    try expectResult(1, lowest ++ "return lowest / lowest; }");
    try expectResult(0, lowest ++ "return lowest % lowest; }");
    try expectResult(0, lowest ++ "return 0x7fffffff / lowest; }");
    try expectResult(0x7fffffff, lowest ++ "return 0x7fffffff % lowest; }");
    try expectResult(-5, lowest ++ "return -5 % lowest; }");
}

test "strings" {
    try expectResult(0, "int main() { return strcmp(\"abc\", \"abc\"); }");
    try expectResult(0, "int main() { return strcmp(\"\", \"\"); }");
    try expectResult(-1, "int main() { return strcmp(\"abc\", \"abd\"); }");
    try expectResult(2, "int main() { return strcmp(\"abe\", \"abc\"); }");
    try expectResult('c', "int main() { return strcmp(\"abc\", \"ab\"); }");
    try expectResult(-'c', "int main() { return strcmp(\"ab\", \"abc\"); }");
    try expectResult(-'a', "int main() { return strcmp(\"\", \"a\"); }");
    try expectResult('b' - 'a', "int main() { return strcmp(\"b\", \"abc\"); }");
    try expectResult(5 * 100 + 5,
        \\char buf[16];
        \\int main() {
        \\    memset(buf, 'x', 16);
        \\    strcpy(buf, "hello");
        \\    if (buf[5] != 0 || buf[6] != 'x') return 0;
        \\    if (strcmp(buf, "hello")) return 1;
        \\    memcpy(buf + 6, buf, 6);
        \\    return strlen(buf) * 100 + strlen(buf + 6);
        \\}
    );
}

test "printing" {
    try expectOutput("hello, world\n", "int main() { puts(\"hello, world\\n\"); return 0; }", "");
    try expectOutput("0 7 10 42 -5 -9 -10 -11 -100 1000000 2147483647 -2147483647 -2147483648 ",
        \\int show(int n) { print_int(n); putchar(' '); return 0; }
        \\int main() {
        \\    show(0); show(7); show(10); show(42); show(-5); show(-9); show(-10); show(-11); show(-100); show(1000000);
        \\    show(0x7fffffff); show(-0x7fffffff); show(-0x7fffffff - 1);
        \\    return 0;
        \\}
    , "");
    try expectOutput("0000002a deadbeef", "int main() { print_hex(42); putchar(' '); print_hex(0xdeadbeef); return 0; }", "");
    // input: add up numbers typed on the serial port
    try expectOutput("12+30+958=1000\n",
        \\int main() {
        \\    int total = 0;
        \\    int n = 0;
        \\    int c;
        \\    while ((c = getchar()) != '\n') {
        \\        if (c == ' ') { print_int(n); putchar('+'); total += n; n = 0; }
        \\        else n = n * 10 + c - '0';
        \\    }
        \\    print_int(n); putchar('='); print_int(total + n); putchar('\n');
        \\    return 0;
        \\}
    , "12 30 958\n");
}

test "malloc and free" {
    // blocks don't overlap, and are where the layout says
    try expectResult(0,
        \\extern int heap[2048];
        \\int main() {
        \\    char *a = malloc(5);         /* 2 words */
        \\    char *b = malloc(4);         /* 1 word */
        \\    char *c = malloc(0);         /* still 1 word */
        \\    if (a != (char *)heap + 4) return 1;
        \\    if (b != a + 12) return 2;   /* a's 8 bytes, and b's size word */
        \\    if (c != b + 8) return 3;
        \\    memset(a, 1, 8); memset(b, 2, 4); memset(c, 3, 4);
        \\    if (a[7] != 1 || b[0] != 2 || b[3] != 2 || c[0] != 3) return 4;
        \\    if (heap[0] != 2 || heap[3] != 1) return 5;  /* the size words survived */
        \\    return 0;
        \\}
    );
    // freed blocks come back: the first one that fits
    try expectResult(0,
        \\extern int heap_used;
        \\int main() {
        \\    char *small = malloc(4);
        \\    char *big = malloc(64);
        \\    char *mid = malloc(16);
        \\    char *keep = malloc(4);
        \\    int used = heap_used;
        \\    free(small); free(mid); free(big);       /* the list is now: big, mid, small */
        \\    if (malloc(100) != keep + 8) return 1;   /* nothing fits: new, after keep */
        \\    used += 26;
        \\    if (malloc(12) != big) return 2;         /* first fit, though mid is the snugger one */
        \\    if (malloc(12) != mid) return 3;         /* big is gone from the list */
        \\    if (malloc(4) != small) return 4;
        \\    if (heap_used != used) return 5;         /* none of those three grew the heap */
        \\    free(mid); free(small);                  /* the list: small, mid */
        \\    if (malloc(16) != mid) return 6;         /* small is skipped, and stays in the list */
        \\    if (malloc(1) != small) return 7;
        \\    if (malloc(1) != keep + 8 + 104) return 8;
        \\    return 0;
        \\}
    );
    // and when the heap is used up, malloc says so
    try expectResult(2,
        \\int main() {
        \\    int n = 0;
        \\    while (malloc(4000)) n++;
        \\    return n;
        \\}
    );
    // which is why free must leave a 0 alone
    try expectResult(7,
        \\extern int *free_list;
        \\int main() {
        \\    free(malloc(9000));
        \\    free(0);
        \\    if (free_list) return 1;
        \\    char *p = malloc(4);
        \\    *p = 7;
        \\    return *p;
        \\}
    );
}

test "a linked list of primes, on the heap" {
    try expectOutput("29 23 19 17 13 11 7 5 3 2 \n",
        \\int *list;           /* each node: [0] a prime, [1] the next node */
        \\int is_prime(int n) {
        \\    for (int d = 2; d * d <= n; d++) if (n % d == 0) return 0;
        \\    return 1;
        \\}
        \\int main() {
        \\    for (int n = 2; n < 30; n++) {
        \\        if (!is_prime(n)) continue;
        \\        int *node = (int *)malloc(8);
        \\        node[0] = n;
        \\        node[1] = (int)list;
        \\        list = node;
        \\    }
        \\    for (int *p = list; p; p = (int *)p[1]) { print_int(p[0]); putchar(' '); }
        \\    putchar('\n');
        \\    return 0;
        \\}
    , "");
}

test "C on the processor you built" {
    const image = try buildProgram(ta, &.{
        \\int main() {
        \\    puts("6 * 7 = ");
        \\    print_int(6 * 7);
        \\    putchar('\n');
        \\    return 0;
        \\}
        ,
        libc_c,
    }, &.{}, 0);
    defer ta.free(image);
    const sent = try runOnSoc(ta, image, "");
    defer ta.free(sent);
    try expectEqualStrings("6 * 7 = 42\n", sent);
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
//@include verilog_sim
//@include v_uart_tx
//@include v_uart_rx
//@include uart_decode
//@include arm_enc
//@include arm_alu
//@include arm_asm_line
//@include arm_asm
//@include arm_emu
//@include v_datapath
//@include v_cpu
//@include v_cpu_mem
//@include soc
