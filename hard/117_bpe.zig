// HARD MODE (zig build -Dhard): no blanks to fill in. Every function
// marked ??? has lost its whole body: write it, from its doc comment,
// its signature and the tests. The gentler version of this file is in
// exercises/, and the answer in solutions/.
//
// ─── Exercise 117: byte-pair encoding ──────────────────────────────────
//
// GPT-style models use *byte-pair encoding* (BPE): start from single bytes
// and repeatedly MERGE the most common adjacent pair into a new token.
//
//     aaabdaaabac          most common pair: "aa"  -> new token Z
//     ZabdZabac            most common pair: "ab"  -> new token Y
//     ZYdZYac              most common pair: "ZY"  -> new token X
//     XdXac                no pair appears twice: stop
//
// Common words end up as single tokens and rare words split into pieces,
// so sequences get much shorter than with characters (116) while any text
// can still be encoded. Decoding expands each merged token back into its
// pair, recursively, until only bytes remain.
//
// Ties (two pairs equally common) go to the smaller pair (first id, then
// second), so the result is deterministic.
//
// YOUR TASK: count the pairs, apply a merge, and decode.
//
const std = @import("std");

const Pair = [2]u32;

/// The most frequent adjacent pair, if some pair occurs at least twice.
fn mostFrequent(alloc: std.mem.Allocator, tokens: []const u32) !?Pair {
    ???; // write this function's body
}

/// Replace every occurrence of `pair` (left to right) with `new_id`.
fn merge(alloc: std.mem.Allocator, tokens: []const u32, pair: Pair, new_id: u32) ![]u32 {
    ???; // write this function's body
}

/// Expand a token back into bytes. merges[k] is the pair token 256 + k was made from.
fn decode(alloc: std.mem.Allocator, merges: []const Pair, tok: u32, out: *std.ArrayList(u8)) !void {
    ???; // write this function's body
}

test "the classic example" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const text = "aaabdaaabac";
    var tokens: []u32 = try alloc.alloc(u32, text.len);
    for (text, tokens) |ch, *t| t.* = ch;

    var merges: std.ArrayList(Pair) = .empty;
    while (try mostFrequent(alloc, tokens)) |pair| {
        const id: u32 = @intCast(256 + merges.items.len);
        try merges.append(alloc, pair);
        tokens = try merge(alloc, tokens, pair, id);
    }
    try std.testing.expectEqual(3, merges.items.len);
    try std.testing.expectEqual(Pair{ 'a', 'a' }, merges.items[0]);
    try std.testing.expectEqual(Pair{ 'a', 'b' }, merges.items[1]);
    try std.testing.expectEqualSlices(u32, &.{ 258, 'd', 258, 'a', 'c' }, tokens); // XdXac

    // a pair's first token at the very end: there's no pair to merge there
    try std.testing.expectEqualSlices(u32, &.{ 9, 1 }, try merge(alloc, &.{ 1, 2, 1 }, .{ 1, 2 }, 9));
    // but a whole pair at the very end is merged
    try std.testing.expectEqualSlices(u32, &.{ 3, 9 }, try merge(alloc, &.{ 3, 1, 2 }, .{ 1, 2 }, 9));

    var back: std.ArrayList(u8) = .empty;
    for (tokens) |t| try decode(alloc, merges.items, t, &back);
    try std.testing.expectEqualStrings(text, back.items);
}
