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
    var counts = std.AutoHashMap(Pair, usize).init(alloc);
    defer counts.deinit();
    for (0..tokens.len -| 1) |i| {
        const gop = try counts.getOrPut(.{ tokens[i], tokens[i + 1] });
        if (!gop.found_existing) gop.value_ptr.* = 0;
        ⟪gop.value_ptr.* += 1;|||???⟫
    }
    var best: ?Pair = null;
    var best_count: usize = 1;
    var it = counts.iterator();
    while (it.next()) |e| {
        const p = e.key_ptr.*;
        const c = e.value_ptr.*;
        const smaller = if (best) |b| (p[0] < b[0] or (p[0] == b[0] and p[1] < b[1])) else true;
        if (c > best_count or (c == best_count and best != null and smaller)) {
            best = p;
            best_count = c;
        }
    }
    return best;
}

/// Replace every occurrence of `pair` (left to right) with `new_id`.
fn merge(alloc: std.mem.Allocator, tokens: []const u32, pair: Pair, new_id: u32) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    var i: usize = 0;
    while (i < tokens.len) {
        if (⟪i + 1 < tokens.len and tokens[i] == pair[0] and tokens[i + 1] == pair[1]|||???⟫) {
            try out.append(alloc, new_id);
            i += 2;
        } else {
            try out.append(alloc, tokens[i]);
            i += 1;
        }
    }
    return out.items;
}

/// Expand a token back into bytes. merges[k] is the pair token 256 + k was made from.
fn decode(alloc: std.mem.Allocator, merges: []const Pair, tok: u32, out: *std.ArrayList(u8)) !void {
    if (tok < 256) return out.append(alloc, @intCast(tok));
    const pair = merges[tok - 256];
    ⟪try decode(alloc, merges, pair[0], out);|||???⟫
    ⟪try decode(alloc, merges, pair[1], out);|||???⟫
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

    var back: std.ArrayList(u8) = .empty;
    for (tokens) |t| try decode(alloc, merges.items, t, &back);
    try std.testing.expectEqualStrings(text, back.items);
}
