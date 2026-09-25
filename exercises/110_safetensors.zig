//
// ─── Exercise 110: loading real weights ────────────────────────────────
//
// The last piece: getting a trained model's weights off disk. Most models
// on Hugging Face ship as *safetensors* files, and tinygrad reads them
// with nn.state.safe_load. The format is refreshingly simple:
//
//     8 bytes     N, the header length, as a little-endian u64
//     N bytes     a JSON header:
//                   { "w1": { "dtype": "F32", "shape": [2, 3],
//                             "data_offsets": [0, 24] },
//                     ... }
//     the rest    raw tensor bytes, back to back
//
// data_offsets are [begin, end) byte positions, counted from the start of
// the raw data (right after the header). A tensor's bytes are just its
// numbers in row-major order (chapter 2), so loading can even be a
// zero-copy view of a memory-mapped file. That's what "safe" is about,
// too: unlike Python pickles, loading can't run any code.
//
// Zig notes: std.json.parseFromSlice(std.json.Value, ...) parses any JSON
// into a tree of objects and arrays. std.mem.readInt reads a fixed-size
// integer from bytes.
//
// YOUR TASK: read the header length, and slice out a tensor's numbers.
//
const std = @import("std");

const Tensor = struct {
    shape: []const usize,
    data: []const f32,
};

/// Find tensor `name` in a safetensors file. Returned slices point into
/// `file` and `alloc`.
fn load(alloc: std.mem.Allocator, file: []const u8, name: []const u8) !Tensor {
    const header_len: usize = @intCast(???);
    const header = file[8..][0..header_len];
    const raw = file[??? ..];

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, header, .{});
    const info = parsed.value.object.get(name) orelse return error.NoSuchTensor;
    if (!std.mem.eql(u8, info.object.get("dtype").?.string, "F32")) return error.NotF32;

    const dims = info.object.get("shape").?.array.items;
    const shape = try alloc.alloc(usize, dims.len);
    for (dims, shape) |d, *s| s.* = @intCast(d.integer);

    const offsets = info.object.get("data_offsets").?.array.items;
    const begin: usize = @intCast(offsets[0].integer);
    const end: usize = @intCast(offsets[1].integer);
    const bytes = ???;

    const data = try alloc.alloc(f32, bytes.len / 4);
    for (data, 0..) |*d, i| d.* = @bitCast(std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little));
    return .{ .shape = shape, .data = data };
}

/// Build a safetensors file in memory.
fn save(alloc: std.mem.Allocator, w1: []const f32, b1: []const f32) ![]u8 {
    const header = try std.fmt.allocPrint(alloc,
        \\{{"w1":{{"dtype":"F32","shape":[2,3],"data_offsets":[0,{d}]}},"b1":{{"dtype":"F32","shape":[3],"data_offsets":[{d},{d}]}}}}
    , .{ w1.len * 4, w1.len * 4, (w1.len + b1.len) * 4 });
    const file = try alloc.alloc(u8, 8 + header.len + (w1.len + b1.len) * 4);
    std.mem.writeInt(u64, file[0..8], header.len, .little);
    @memcpy(file[8..][0..header.len], header);
    var at = 8 + header.len;
    for ([_][]const f32{ w1, b1 }) |t| {
        for (t) |v| {
            std.mem.writeInt(u32, file[at..][0..4], @bitCast(v), .little);
            at += 4;
        }
    }
    return file;
}

test "round trip through the format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const w1 = [_]f32{ 1, -2, 3.5, 0.25, 5, -6 };
    const b1 = [_]f32{ 0.1, 0.2, 0.3 };
    const file = try save(alloc, &w1, &b1);

    const w = try load(alloc, file, "w1");
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, w.shape);
    try std.testing.expectEqualSlices(f32, &w1, w.data);

    const b = try load(alloc, file, "b1");
    try std.testing.expectEqualSlices(usize, &.{3}, b.shape);
    try std.testing.expectEqualSlices(f32, &b1, b.data);

    try std.testing.expectError(error.NoSuchTensor, load(alloc, file, "w2"));
}
