//
// ─── Exercise 224: C, cut into words ──────────────────────────────────
//
// Chapter 45: a "high" level language. The computer boots, and the only
// way to program it is assembly, one instruction per line. The next
// five exercises build the tool that ended that era: a compiler, for
// (most of) C. Everything above it in this part, the libc, the
// bootloader, the operating system, is then written in C and compiled by
// *your* compiler.
//
// A compiler is a pipeline, and each stage is small:
//
//     text ──lexer──> tokens ──parser──> a tree ──code generator──> assembly
//          224              225, 226           227, 228
//
// and then your own assembler (216) makes the bytes.
//
// The lexer's job is to stop everything after it from ever thinking
// about characters. It turns
//
//     x = (y+42) * 0x1f;   // answer
//
// into the *tokens*   x  =  (  y  +  42  )  *  0x1f  ;   with spaces and
// comments gone. A token has a kind, its text, and (for a number) its
// value:
//
//     ident     a name: letters, digits and _, not starting with a digit
//     keyword   a name the language keeps for itself: int, while, ...
//     num       42, 0x1f, and also 'a': a character IS a small number
//     str       "text"; the token's text is what is between the quotes
//     punct     an operator or a bracket: + == ( ; ...
//     eof       the end, so the parser never runs off the array
//
// One rule decides every ambiguity: *longest match*, also called maximal
// munch. `>>=` is one token and not `>` `>=`; `intx` is one name and not
// the keyword `int` followed by `x`; `a+++b` is `a ++ + b`, whatever its
// author hoped. Take the longest thing that can be a token, then start
// again right after it.
//
// YOUR TASK: the pieces of cLex() marked below.
//
const std = @import("std");

//@export c_lex
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
            while (i < source.len and source[i] != ⟪'\n'|||???⟫) i += 1;
        } else if (std.mem.startsWith(u8, source[i..], "/*")) {
            // a comment to the next */, which may be lines away
            const end = std.mem.indexOfPos(u8, source, i + 2, "*/") orelse return error.UnterminatedComment;
            line += @intCast(std.mem.count(u8, source[i..end], "\n"));
            i = ⟪end + 2|||???⟫;
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
                if (⟪std.mem.eql(u8, text, kw)|||???⟫) kind = .keyword;
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
                i += ⟪if (source[i] == '\\') 2 else 1|||???⟫;
            }
            if (i >= source.len) return error.UnterminatedString;
            i += 1;
            try toks.append(alloc, .{ .kind = .str, .text = source[start + 1 .. i - 1], .line = line });
        } else {
            const found = for (c_puncts) |p| {
                if (⟪std.mem.startsWith(u8, source[i..], p)|||???⟫) break p;
            } else return error.BadCharacter;
            i += found.len;
            try toks.append(alloc, .{ .kind = .punct, .text = source[start..i], .line = line });
        }
    }
    try toks.append(alloc, .{ .kind = .eof, .text = "", .line = line });
    return toks.toOwnedSlice(alloc);
}
//@end

const ta = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

/// The tokens' texts with spaces between them, each with a letter for
/// its kind in front: i(dent) k(eyword) n(um) s(tr) p(unct).
fn spell(source: []const u8) ![]u8 {
    const toks = try cLex(ta, source);
    defer ta.free(toks);
    var out: std.Io.Writer.Allocating = .init(ta);
    errdefer out.deinit();
    for (toks) |tok| {
        if (tok.kind == .eof) break;
        try out.writer.print("{c}:{s} ", .{ @tagName(tok.kind)[0], tok.text });
    }
    return out.toOwnedSlice();
}

fn expectSpelled(want: []const u8, source: []const u8) !void {
    const got = try spell(source);
    defer ta.free(got);
    try expectEqualStrings(want, got);
}

test "names, keywords and numbers" {
    try expectSpelled("i:x p:= p:( i:y p:+ n:42 p:) p:* n:0x1f p:; ", "x = (y+42) * 0x1f;   // answer");
    try expectSpelled("k:int i:interest p:; k:while i:whiles i:_if k:if i:int3 ", "int interest; while whiles _if if int3");
    const toks = try cLex(ta, "42 0x1f 0 'a' '\\n' '\\'' 4294967295");
    defer ta.free(toks);
    const values = [_]u32{ 42, 31, 0, 97, 10, 39, 0xffffffff };
    for (values, toks[0..values.len]) |want, tok| {
        try expectEqual(CTok.num, tok.kind);
        try expectEqual(want, tok.num);
    }
    try expectEqual(CTok.eof, toks[values.len].kind);
    try expectError(error.BadNumber, cLex(ta, "12ab"));
    try expectError(error.BadNumber, cLex(ta, "4294967296"));
    try expectError(error.BadCharacter, cLex(ta, "a $ b"));
    try expectError(error.BadCharacter, cLex(ta, "'ab'"));
    try expectError(error.BadEscape, cLex(ta, "'\\q'"));
}

test "longest match" {
    try expectSpelled("i:a p:++ p:+ i:b ", "a+++b");
    try expectSpelled("i:a p:<< p:= i:b p:<= i:c p:< p:- i:d ", "a<<=b<=c<-d");
    try expectSpelled("i:p p:&& i:q p:& p:&& i:r p:|| p:| ", "p&&q& &&r|||");
    try expectSpelled("i:i p:-- p:-- p:= n:1 p:!= p:!= p:== ", "i----=1!=!===");
    try expectSpelled("p:* i:p p:[ n:0 p:] p:= p:~ i:x p:^ i:y p:% n:3 p:, p:{ p:} ", "*p[0]=~x^y%3,{}");
}

test "strings and comments" {
    try expectSpelled("i:puts p:( s:hi // there p:) p:; ", "puts(\"hi // there\"); // a comment");
    try expectSpelled("s:say \\\"hi\\\"\\n i:x ", "\"say \\\"hi\\\"\\n\" x");
    try expectSpelled("s: s:a ", "\"\"\"a\"");
    try expectSpelled("i:a i:b ", "a /* gone * / still gone */ b");
    try expectSpelled("i:a p:/ i:b p:* i:c ", "a / b * c");
    try expectSpelled("i:a i:b ", "a/**/b");
    try expectSpelled("s:x\\\" i:y ", "\"x\\\"\" y");
    try expectError(error.UnterminatedString, cLex(ta, "\"abc"));
    try expectError(error.UnterminatedString, cLex(ta, "\"abc\\\""));
    try expectError(error.UnterminatedString, cLex(ta, "\"abc\ndef\""));
    try expectError(error.UnterminatedComment, cLex(ta, "a /* b"));
    try expectError(error.UnterminatedComment, cLex(ta, "a /*/ b"));
}

test "line numbers" {
    const toks = try cLex(ta,
        \\int x; // one
        \\/* two
        \\   three */ int y;
        \\
        \\"five" z
    );
    defer ta.free(toks);
    const lines = [_]u32{ 1, 1, 1, 3, 3, 3, 5, 5, 5 };
    try expectEqual(lines.len, toks.len);
    for (lines, toks) |want, tok| try expectEqual(want, tok.line);
    try std.testing.expect(toks[6].is(.str, "five"));
    try std.testing.expect(!toks[7].is(.keyword, "z"));
}
