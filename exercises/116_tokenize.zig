//
// ─── Exercise 116: text to numbers ─────────────────────────────────────
//
// Chapter 22: language modeling, the task behind every LLM. Models eat
// numbers, so text must become a list of integers ("tokens") first, and
// come back out at the end.
//
// The simplest scheme: one token per distinct character. Collect the
// characters that appear, sort them, and number them 0, 1, 2, ...:
//
//     "hello"  ->  vocab: e h l o   ->   h=1 e=0 l=2 l=2 o=3   ->  [1, 0, 2, 2, 3]
//
// encode maps characters to ids, decode maps them back. The round trip
// must be perfect: decode(encode(text)) == text.
//
// Character-level tokens make sequences long (one token per letter), so
// real LLMs use subword tokens (next exercise).
//
// YOUR TASK: build the vocabulary, encode and decode.
//
const std = @import("std");

const Vocab = struct {
    chars: [256]u8 = undefined, //       id -> character
    ids: [256]?u8 = @splat(null), //     character -> id
    size: usize = 0,

    fn build(text: []const u8) Vocab {
        var seen: [256]bool = @splat(false);
        for (text) |ch| seen[ch] = true;
        var v: Vocab = .{};
        for (seen, 0..) |present, ch| { // in byte order: sorted
            if (!present) continue;
            v.chars[v.size] = @intCast(ch);
            v.ids[ch] = ???;
            v.size += 1;
        }
        return v;
    }

    fn encode(v: Vocab, text: []const u8, out: []u8) void {
        for (text, out) |ch, *o| o.* = ???;
    }

    fn decode(v: Vocab, ids: []const u8, out: []u8) void {
        for (ids, out) |id, *o| o.* = ???;
    }
};

test "hello" {
    const v = Vocab.build("hello");
    try std.testing.expectEqual(4, v.size);
    var ids: [5]u8 = undefined;
    v.encode("hello", &ids);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 2, 3 }, &ids);
}

test "round trip" {
    const text = "the quick brown fox jumps over the lazy dog";
    const v = Vocab.build(text);
    var ids: [text.len]u8 = undefined;
    var back: [text.len]u8 = undefined;
    v.encode(text, &ids);
    v.decode(&ids, &back);
    try std.testing.expectEqualStrings(text, &back);
    try std.testing.expectEqual(27, v.size); // 26 letters and a space
}
