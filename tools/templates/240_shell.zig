//
// ─── Exercise 240: a shell ────────────────────────────────────────────
//
// The outline's list for this point reads: "init, shell, download, cat,
// ls, rm". Those are the programs that make a computer feel like one:
// you type a line, something happens, and you get to type another.
//
// A shell is a loop:
//
//     print a prompt
//     read a line
//     split it into words          cat notes.txt   ->   "cat", "notes.txt"
//     the first word names a command; the rest are its arguments
//     run it; go round again
//
// The split is the one clever line of C in it, and every C program you
// have ever started was handed its result: main(argc, argv). It makes
// no copies. It walks the line once, writes a 0 over the space after
// each word, and collects pointers to where the words begin:
//
//     line:   c a t _ n o t e s . t x t \0
//     after:  c a t\0 n o t e s . t x t \0
//             ^       ^
//           argv[0]  argv[1]                    argc = 2
//
// The commands here work on a small file system that lives in memory:
// eight files of up to 255 bytes, in three arrays. (The calls it offers,
// find a name, read, create, delete, are the ones 239's FAT offers too.
// A shell doesn't care what is underneath. Swapping this for FAT on the
// SD card, in C, is the natural next step from here.)
//
//     ls                 the names and sizes
//     cat NAME           a file's contents
//     put NAME WORDS...  make a file holding the words (the outline's
//                        "download": getting a file onto the machine)
//     rm NAME            delete
//     echo WORDS...      say them
//     exit               stop the machine
//
// It is C, compiled by your compiler, linked against your libc, and the
// last test runs it on your processor in gates: every layer of this
// part so far, in one transcript.
//
// YOUR TASK: split(), find(), and the commands cat and rm.
//
const std = @import("std");

//@export shell
/// split(line, argv, max): cut `line` into words in place, as described
/// above. Words are separated by one or more spaces. At most `max` words
/// are collected. Returns how many.
//⟪
const shell_split =
    \\int split(char *line, char **argv, int max) {
    \\    int argc = 0;
    \\    while (*line) {
    \\        while (*line == ' ') *line++ = 0;
    \\        if (*line == 0 || argc == max) break;
    \\        argv[argc++] = line;
    \\        while (*line && *line != ' ') line++;
    \\    }
    \\    return argc;
    \\}
    \\
;
//|||
const shell_split = ???;
//⟫

/// find(name): the number of the file with that name, or -1. File i
/// exists if used[i] is not 0, and its name starts at names + i * 16.
//⟪
const shell_find =
    \\int find(char *name) {
    \\    for (int i = 0; i < 8; i++) {
    \\        if (used[i] && strcmp(names + i * 16, name) == 0) return i;
    \\    }
    \\    return -1;
    \\}
    \\
;
//|||
const shell_find = ???;
//⟫

/// cat(name): print the file's bytes (sizes[i] of them, from
/// data + i * 256) with putchar; if there is no such file, say
/// "cat: no such file\n" with puts. rm(name): the file no longer exists
/// (its used[] becomes 0); or "rm: no such file\n".
//⟪
const shell_cat_rm =
    \\int cat(char *name) {
    \\    int i = find(name);
    \\    if (i < 0) return puts("cat: no such file\n");
    \\    for (int k = 0; k < sizes[i]; k++) putchar(data[i * 256 + k]);
    \\    return 0;
    \\}
    \\int rm(char *name) {
    \\    int i = find(name);
    \\    if (i < 0) return puts("rm: no such file\n");
    \\    used[i] = 0;
    \\    return 0;
    \\}
    \\
;
//|||
const shell_cat_rm = ???;
//⟫

const shell_c =
    \\/* The file system: eight files, in memory. */
    \\char names[128];        /* 16 bytes each */
    \\char data[2048];        /* 256 bytes each */
    \\int sizes[8];
    \\int used[8];
    \\
++ shell_find ++ shell_cat_rm ++
    \\int ls() {
    \\    for (int i = 0; i < 8; i++) {
    \\        if (!used[i]) continue;
    \\        puts(names + i * 16);
    \\        putchar(' ');
    \\        print_int(sizes[i]);
    \\        putchar('\n');
    \\    }
    \\    return 0;
    \\}
    \\/* A file made of the words, with spaces between and a newline after. */
    \\int put(int argc, char **argv) {
    \\    int i = find(argv[1]);
    \\    for (int k = 0; i < 0 && k < 8; k++) if (!used[k]) i = k;
    \\    if (i < 0) return puts("put: no room\n");
    \\    if (strlen(argv[1]) > 15) return puts("put: name too long\n");
    \\    strcpy(names + i * 16, argv[1]);
    \\    char *to = data + i * 256;
    \\    int n = 0;
    \\    for (int w = 2; w < argc; w++) {
    \\        if (w > 2) to[n++] = ' ';
    \\        for (char *p = argv[w]; *p && n < 254; p++) to[n++] = *p;
    \\    }
    \\    to[n++] = '\n';
    \\    sizes[i] = n;
    \\    used[i] = 1;
    \\    return 0;
    \\}
    \\
++ shell_split ++
    \\int read_line(char *line, int max) {
    \\    int n = 0;
    \\    while (1) {
    \\        int c = getchar();
    \\        if (c == '\n') break;
    \\        if (n < max - 1) line[n++] = c;
    \\    }
    \\    line[n] = 0;
    \\    return n;
    \\}
    \\int main() {
    \\    char line[80];
    \\    char *argv[8];
    \\    while (1) {
    \\        puts("$ ");
    \\        read_line(line, 80);
    \\        int argc = split(line, argv, 8);
    \\        if (argc == 0) continue;
    \\        char *command = argv[0];
    \\        if (strcmp(command, "exit") == 0) break;
    \\        else if (strcmp(command, "ls") == 0) ls();
    \\        else if (strcmp(command, "cat") == 0 && argc == 2) cat(argv[1]);
    \\        else if (strcmp(command, "rm") == 0 && argc == 2) rm(argv[1]);
    \\        else if (strcmp(command, "put") == 0 && argc >= 2) put(argc, argv);
    \\        else if (strcmp(command, "echo") == 0) {
    \\            for (int w = 1; w < argc; w++) { if (w > 1) putchar(' '); puts(argv[w]); }
    \\            putchar('\n');
    \\        }
    \\        else { puts(command); puts(": what?\n"); }
    \\    }
    \\    return 0;
    \\}
    \\
;
//@end

const ta = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// What the shell prints when `script` is typed at it.
fn expectSession(want: []const u8, script: []const u8) !void {
    const ran = try runC(ta, shell_c, script);
    defer ta.free(ran.output);
    try expectEqualStrings(want, ran.output);
}

test "split, on its own" {
    const ran = try runC(ta, shell_split ++
        \\char line[40];
        \\char *words[4];
        \\int show(char *text, int max) {
        \\    strcpy(line, text);
        \\    int n = split(line, words, max);
        \\    print_int(n);
        \\    for (int i = 0; i < n; i++) { putchar('['); puts(words[i]); putchar(']'); }
        \\    putchar('\n');
        \\    return 0;
        \\}
        \\int main() {
        \\    show("cat notes.txt", 4);
        \\    show("   lots   of    space   ", 4);
        \\    show("one", 4);
        \\    show("", 4);
        \\    show("    ", 4);
        \\    show("a b c d e f", 4);
        \\    show("a b c d e f", 2);
        \\    return 0;
        \\}
    , "");
    defer ta.free(ran.output);
    try expectEqualStrings(
        \\2[cat][notes.txt]
        \\3[lots][of][space]
        \\1[one]
        \\0
        \\0
        \\4[a][b][c][d]
        \\2[a][b]
        \\
    , ran.output);
}

test "a session" {
    try expectSession(
        \\$ hello there
        \\$ $ $ notes.txt 13
        \\$ buy more RAM
        \\$ $ notes.txt 13
        \\b 2
        \\$ x
        \\$ $ cat: no such file
        \\$ notes.txt 13
        \\$ rm: no such file
        \\$ frobnicate: what?
        \\$ 
    ,
        \\echo hello   there
        \\
        \\put notes.txt buy more RAM
        \\ls
        \\cat notes.txt
        \\put b x
        \\ls
        \\cat b
        \\rm b
        \\cat b
        \\ls
        \\rm b
        \\frobnicate the widgets
        \\exit
        \\
    );
}

test "names that share a beginning, a file replaced, and a full disk" {
    try expectSession(
        \\$ $ $ one
        \\$ two
        \\$ $ three
        \\$ note 6
        \\notes 4
        \\$ $ $ $ $ $ $ put: no room
        \\$ 8
        \\$ $ $ 9
        \\
    ++ "$ ",
        \\put note one
        \\put notes two
        \\cat note
        \\cat notes
        \\put note three
        \\cat note
        \\ls
        \\put f3 3
        \\put f4 4
        \\put f5 5
        \\put f6 6
        \\put f7 7
        \\put f8 8
        \\put f9 9
        \\cat f8
        \\rm f5
        \\put f9 9
        \\cat f9
        \\exit
        \\
    );
}

test "the shell, on the computer you built" {
    const image = try buildProgram(ta, &.{ shell_c, libc_c }, &.{}, 0);
    defer ta.free(image);
    const sent = try runOnSocPaced(ta, image, "put a hi\ncat a\nexit\n", true);
    defer ta.free(sent);
    try expectEqualStrings("$ $ hi\n$ ", sent);
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
