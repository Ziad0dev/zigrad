// HARD MODE (zig build -Dhard): no blanks to fill in. Every function
// marked ??? has lost its whole body: write it, from its doc comment,
// its signature and the tests. The gentler version of this file is in
// exercises/, and the answer in solutions/.
//
// ─── Exercise 239: files ──────────────────────────────────────────────
//
// A block device is a row of numbered 512-byte blocks and nothing else.
// A *file system* is an agreement about what to write in those blocks so
// that "the file NOTES.TXT" means something. FAT is the simplest
// agreement in wide use: it is from 1977, and it is on the SD card in
// your camera today because everything can read it.
//
// The disk is cut into four regions, in this order:
//
//   boot sector   block 0: a table of numbers that says how big the
//                 other regions are. Every other position on the disk is
//                 computed from it.
//   the FAT       the "file allocation table", which gave the format its
//                 name (and is stored twice, in case one copy is
//                 damaged)
//   root dir      a fixed number of 32-byte entries: name, size, and
//                 where the file's data starts
//   data          the rest, cut into *clusters* of one or more blocks.
//                 For historical reasons the first cluster is number 2.
//
// A file's data is a chain of clusters, and they need not be next to
// each other: after some deleting and creating, a file's clusters are
// scattered wherever there was room. The directory entry holds only the
// FIRST cluster. The FAT holds the rest: it is an array with one 16-bit
// entry per cluster, and entry n says which cluster comes after n.
//
//     directory:  NOTES.TXT  size 3000  first cluster 2
//     FAT:        [2] = 3    [3] = 6    [6] = 0xffff (the end)
//     so the data is clusters 2, 3, 6, and the size says how much of
//     the last one counts.
//
// In other words: a linked list, with the links kept in a table of
// their own and not in the blocks. A FAT entry of 0 means the cluster is
// free, which makes deleting a file almost nothing: walk its chain
// writing zeros, and put the mark 0xe5 on the first byte of its
// directory entry. The data itself stays where it was, which is why
// deleted files can so often be recovered.
//
// Names are "8.3": eight characters and three for the extension, in
// capitals, padded with spaces, the dot not stored: "NOTES   TXT".
//
// Everything here goes through 238's SD driver, a block at a time: your
// file system, on your driver, on a model of the card.
//
// YOUR TASK: the layout arithmetic, following the chain, listing the
// directory, and deleting.
//
const std = @import("std");

/// A block device: here, the SD card, through 238's driver.
const Disk = struct {
    card: *SdCard,

    fn read(d: *Disk, n: u32, block: *[block_size]u8) !void {
        return sdReadBlock(d.card, n, block);
    }

    fn write(d: *Disk, n: u32, block: *const [block_size]u8) !void {
        return sdWriteBlock(d.card, n, block);
    }
};

/// Where everything is, in blocks ("sectors"), worked out from block 0.
const FatLayout = struct {
    sectors_per_cluster: u32,
    fat_start: u32,
    fat_sectors: u32,
    fat_copies: u32,
    root_start: u32,
    root_entries: u32,
    data_start: u32,
    /// How many clusters the data region holds. They are numbered from 2.
    clusters: u32,

    fn parse(boot: *const [block_size]u8) !FatLayout {
        ???; // write this function's body
    }

    /// The first block of a cluster. The first cluster is number 2.
    fn clusterSector(l: FatLayout, cluster: u16) u32 {
        ???; // write this function's body
    }
};

const fat_end: u16 = 0xfff8; // this or anything above: the chain ends here

const FatFile = struct {
    /// "NOTES.TXT"
    name_buf: [12]u8 = undefined,
    name_len: usize = 0,
    size: u32,
    first_cluster: u16,

    fn name(f: *const FatFile) []const u8 {
        return f.name_buf[0..f.name_len];
    }
};

/// "notes.txt" as a directory stores it: "NOTES   TXT".
fn fat83(text: []const u8) ![11]u8 {
    var raw: [11]u8 = @splat(' ');
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
    const ext = if (dot < text.len) text[dot + 1 ..] else "";
    if (dot == 0 or dot > 8 or ext.len > 3) return error.BadName;
    for (text[0..dot], 0..) |c, n| raw[n] = std.ascii.toUpper(c);
    for (ext, 0..) |c, n| raw[8 + n] = std.ascii.toUpper(c);
    return raw;
}

/// Where a directory entry is on the disk.
const DirSlot = struct { sector: u32, offset: usize };

const Fat = struct {
    disk: *Disk,
    layout: FatLayout,

    fn mount(disk: *Disk) !Fat {
        var boot: [block_size]u8 = undefined;
        try disk.read(0, &boot);
        return .{ .disk = disk, .layout = try FatLayout.parse(&boot) };
    }

    /// The FAT's entry for a cluster: the cluster after it. Entries are
    /// 16 bits, low byte first, so 256 fit in a block.
    fn after(fat: *Fat, cluster: u16) !u16 {
        ???; // write this function's body
    }

    /// Changes a cluster's entry, in every copy of the FAT.
    fn setAfter(fat: *Fat, cluster: u16, value: u16) !void {
        for (0..fat.layout.fat_copies) |copy| {
            const sector = fat.layout.fat_start + @as(u32, @intCast(copy)) * fat.layout.fat_sectors + cluster / 256;
            var block: [block_size]u8 = undefined;
            try fat.disk.read(sector, &block);
            std.mem.writeInt(u16, block[@as(usize, cluster % 256) * 2 ..][0..2], value, .little);
            try fat.disk.write(sector, &block);
        }
    }

    const Walker = struct {
        fat: *Fat,
        entry: u32 = 0,
        block: [block_size]u8 = undefined,
        slot: DirSlot = undefined,

        /// The next entry of the root directory that is a file, or null
        /// at the end. An entry whose first byte is 0 has never been
        /// used, and neither has any after it: stop. An entry whose
        /// first byte is 0xe5 was deleted: skip it.
        fn nextFile(w: *Walker) !?FatFile {
            ???; // write this function's body
        }
    };

    /// Every file in the root directory. The caller frees the list.
    fn list(fat: *Fat, alloc: std.mem.Allocator) ![]FatFile {
        var files: std.ArrayList(FatFile) = .empty;
        errdefer files.deinit(alloc);
        var w: Walker = .{ .fat = fat };
        while (try w.nextFile()) |file| try files.append(alloc, file);
        return files.toOwnedSlice(alloc);
    }

    const Found = struct { file: FatFile, slot: DirSlot };

    fn find(fat: *Fat, text: []const u8) !Found {
        const want = try fat83(text);
        var w: Walker = .{ .fat = fat };
        while (try w.nextFile()) |file| {
            // a name we could not have written ourselves is not the one
            const have = fat83(file.name()) catch continue;
            if (std.mem.eql(u8, &want, &have)) return .{ .file = file, .slot = w.slot };
        }
        return error.FileNotFound;
    }

    /// A file's contents. The caller frees them.
    fn read(fat: *Fat, alloc: std.mem.Allocator, text: []const u8) ![]u8 {
        ???; // write this function's body
    }

    /// Deletes a file: every cluster of its chain becomes free (0), and
    /// its directory entry gets the mark 0xe5.
    fn remove(fat: *Fat, text: []const u8) !void {
        ???; // write this function's body
    }

    /// The first free cluster at or after `from`.
    fn findFree(fat: *Fat, from: u16) !u16 {
        var cluster: u32 = from;
        while (cluster < fat.layout.clusters + 2) : (cluster += 1) {
            if (try fat.after(@intCast(cluster)) == 0) return @intCast(cluster);
        }
        return error.DiskFull;
    }

    /// Whether `count` clusters are free.
    fn hasRoom(fat: *Fat, count: usize) !bool {
        var free: usize = 0;
        var from: u16 = 2;
        while (free < count) : (free += 1) {
            from = (fat.findFree(from) catch |err| return if (err == error.DiskFull) false else err) + 1;
        }
        return true;
    }

    /// Makes a new file. Two things are checked before anything is
    /// written, so that a refusal leaves the disk as it was: that no
    /// file has this name already, and that the data fits.
    fn create(fat: *Fat, text: []const u8, data: []const u8) !void {
        const raw_name = try fat83(text);
        if (fat.find(text)) |_| return error.FileExists else |err| if (err != error.FileNotFound) return err;
        const cluster_bytes = fat.layout.sectors_per_cluster * block_size;
        if (!try fat.hasRoom((data.len + cluster_bytes - 1) / cluster_bytes)) return error.DiskFull;
        // a directory entry that is free: never used, or deleted
        var slot: ?DirSlot = null;
        var block: [block_size]u8 = undefined;
        find_slot: for (0..(fat.layout.root_entries + 15) / 16) |s| {
            const sector = fat.layout.root_start + @as(u32, @intCast(s));
            try fat.disk.read(sector, &block);
            for (0..16) |e| {
                if (s * 16 + e >= fat.layout.root_entries) break;
                if (block[e * 32] == 0 or block[e * 32] == 0xe5) {
                    slot = .{ .sector = sector, .offset = e * 32 };
                    break :find_slot;
                }
            }
        }
        const where = slot orelse return error.DirectoryFull;
        // the data: a cluster at a time, each linked from the one before
        var first: u16 = 0;
        var previous: u16 = 0;
        var done: usize = 0;
        while (done < data.len) {
            const cluster = try fat.findFree(2);
            try fat.setAfter(cluster, 0xffff);
            if (previous == 0) first = cluster else try fat.setAfter(previous, cluster);
            previous = cluster;
            for (0..fat.layout.sectors_per_cluster) |k| {
                var out: [block_size]u8 = @splat(0);
                const n = @min(block_size, data.len - done);
                @memcpy(out[0..n], data[done..][0..n]);
                try fat.disk.write(fat.layout.clusterSector(cluster) + @as(u32, @intCast(k)), &out);
                done += n;
            }
        }
        try fat.disk.read(where.sector, &block);
        const raw = block[where.offset..][0..32];
        @memset(raw, 0);
        @memcpy(raw[0..11], &raw_name);
        raw[11] = 0x20; // "archive": an ordinary file
        std.mem.writeInt(u16, raw[26..28], first, .little);
        std.mem.writeInt(u32, raw[28..32], @intCast(data.len), .little);
        try fat.disk.write(where.sector, &block);
    }
};

/// Writes an empty FAT16 file system over the whole card: 2 blocks per
/// cluster, two FATs of 2 blocks each, 32 directory entries.
fn fatFormat(disk: *Disk) !void {
    const total: u32 = @intCast(disk.card.disk.len / block_size);
    var block: [block_size]u8 = @splat(0);
    for (1..7) |n| try disk.write(@intCast(n), &block);
    block[0] = 0xeb; // a jump over the table, for PCs that boot from this
    block[1] = 0x3c;
    block[2] = 0x90;
    @memcpy(block[3..11], "ZIGRAD  ");
    std.mem.writeInt(u16, block[11..13], block_size, .little);
    block[13] = 2; // blocks per cluster
    std.mem.writeInt(u16, block[14..16], 1, .little); // reserved: this block
    block[16] = 2; // copies of the FAT
    std.mem.writeInt(u16, block[17..19], 32, .little); // root directory entries
    std.mem.writeInt(u16, block[19..21], @intCast(total), .little);
    block[21] = 0xf8; // "a hard disk"
    std.mem.writeInt(u16, block[22..24], 2, .little); // blocks per FAT
    block[510] = 0x55;
    block[511] = 0xaa;
    try disk.write(0, &block);
    // entries 0 and 1 of the FAT belong to no cluster
    var fat = try Fat.mount(disk);
    try fat.setAfter(0, 0xfff8);
    try fat.setAfter(1, 0xffff);
}

const ta = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

const Rig = struct {
    card: SdCard,
    disk: Disk = undefined,

    /// A formatted 64 KB card.
    fn init() !*Rig {
        const rig = try ta.create(Rig);
        const bytes = try ta.alloc(u8, 128 * block_size);
        @memset(bytes, 0x77); // an old card, full of junk
        rig.* = .{ .card = .{ .disk = bytes } };
        rig.disk = .{ .card = &rig.card };
        try sdInit(&rig.card);
        try fatFormat(&rig.disk);
        return rig;
    }

    fn deinit(rig: *Rig) void {
        ta.free(rig.card.disk);
        ta.destroy(rig);
    }
};

fn pattern(comptime len: usize, seed: u8) [len]u8 {
    var bytes: [len]u8 = undefined;
    for (&bytes, 0..) |*b, n| b.* = @truncate(n * 31 + seed + n / 256);
    return bytes;
}

test "the layout" {
    var rig = try Rig.init();
    defer rig.deinit();
    const fat = try Fat.mount(&rig.disk);
    try expectEqual(@as(u32, 1), fat.layout.fat_start);
    try expectEqual(@as(u32, 5), fat.layout.root_start); // after 1 reserved block and 2 FATs of 2
    try expectEqual(@as(u32, 7), fat.layout.data_start); // 32 entries of 32 bytes are 2 blocks
    try expectEqual(@as(u32, 7), fat.layout.clusterSector(2));
    try expectEqual(@as(u32, 9), fat.layout.clusterSector(3));
    try expectEqual(@as(u32, 27), fat.layout.clusterSector(12));
    try expectEqual(@as(u32, 60), fat.layout.clusters); // 121 blocks of data: 60 pairs, and one left over
    // a different disk: 4 blocks per cluster, 3 reserved, one FAT of 9, 512 entries
    var boot: [block_size]u8 = @splat(0);
    std.mem.writeInt(u16, boot[11..13], 512, .little);
    boot[13] = 4;
    boot[14] = 3;
    boot[16] = 1;
    std.mem.writeInt(u16, boot[17..19], 512, .little);
    boot[22] = 9;
    try expectError(error.NotFat, FatLayout.parse(&boot));
    boot[510] = 0x55;
    boot[511] = 0xaa;
    const other = try FatLayout.parse(&boot);
    try expectEqual(@as(u32, 12), other.root_start);
    try expectEqual(@as(u32, 44), other.data_start);
    try expectEqual(@as(u32, 44 + 4 * 98), other.clusterSector(100));
    try expectEqual(@as(u32, 0), other.clusters); // no size given yet
    // a size too big for 16 bits is kept further on: room for 24989
    // clusters, but a table of 9 blocks only has entries for 2302
    std.mem.writeInt(u32, boot[32..36], 100_000, .little);
    try expectEqual(@as(u32, 9 * 256 - 2), (try FatLayout.parse(&boot)).clusters);
    boot[22] = 200;
    try expectEqual(@as(u32, (100_000 - 203 - 32) / 4), (try FatLayout.parse(&boot)).clusters);
    std.mem.writeInt(u16, boot[19..21], 1000, .little); // the 16-bit size wins when it is there
    try expectEqual(@as(u32, (1000 - 203 - 32) / 4), (try FatLayout.parse(&boot)).clusters);
}

test "the table is more than one block long" {
    var rig = try Rig.init();
    defer rig.deinit();
    var fat = try Fat.mount(&rig.disk);
    for ([_]u16{ 254, 255, 256, 257, 300, 511 }) |cluster| try fat.setAfter(cluster, 1000 + cluster);
    for ([_]u16{ 511, 300, 257, 256, 255, 254 }) |cluster| try expectEqual(1000 + cluster, try fat.after(cluster));
    try expectEqual(@as(u16, 0), try fat.after(258));
}

test "files in, files out" {
    var rig = try Rig.init();
    defer rig.deinit();
    var fat = try Fat.mount(&rig.disk);
    const big = pattern(3000, 1);
    const exact = pattern(1024, 2);
    try fat.create("hello.txt", "Hello, FAT!\n");
    try fat.create("BIG.BIN", &big);
    try fat.create("empty", "");
    try fat.create("exact.dat", &exact);

    const files = try fat.list(ta);
    defer ta.free(files);
    try expectEqual(@as(usize, 4), files.len);
    try expectEqualStrings("HELLO.TXT", files[0].name());
    try expectEqualStrings("BIG.BIN", files[1].name());
    try expectEqualStrings("EMPTY", files[2].name());
    try expectEqualStrings("EXACT.DAT", files[3].name());
    try expectEqual(@as(u32, 12), files[0].size);
    try expectEqual(@as(u32, 3000), files[1].size);
    try expectEqual(@as(u16, 2), files[0].first_cluster);
    try expectEqual(@as(u16, 3), files[1].first_cluster);
    try expectEqual(@as(u16, 6), files[3].first_cluster); // BIG took 3, 4 and 5

    // the chain of BIG.BIN, straight from the table
    try expectEqual(@as(u16, 4), try fat.after(3));
    try expectEqual(@as(u16, 5), try fat.after(4));
    try expect(try fat.after(5) >= fat_end);
    try expect(try fat.after(2) >= fat_end);
    try expectEqual(@as(u16, 0), try fat.after(7)); // free

    inline for (.{ .{ "hello.txt", "Hello, FAT!\n" }, .{ "big.bin", &big }, .{ "EMPTY", "" }, .{ "Exact.Dat", &exact } }) |pair| {
        const data = try fat.read(ta, pair[0]);
        defer ta.free(data);
        try expectEqualSlices(u8, pair[1], data);
    }
    try expectError(error.FileNotFound, fat.read(ta, "nope.txt"));
    try expectError(error.BadName, fat.read(ta, "muchtoolong.txt"));
}

test "deleting, and a file in pieces" {
    var rig = try Rig.init();
    defer rig.deinit();
    var fat = try Fat.mount(&rig.disk);
    const a = pattern(2000, 3); // clusters 2, 3
    const b = pattern(1500, 4); // clusters 4, 5
    const c = pattern(3500, 5); // will need four
    try fat.create("a.bin", &a);
    try fat.create("b.bin", &b);
    try fat.remove("a.bin");
    try expectError(error.FileNotFound, fat.read(ta, "a.bin"));
    try expectEqual(@as(u16, 0), try fat.after(2));
    try expectEqual(@as(u16, 0), try fat.after(3));
    try expectEqual(@as(u16, 5), try fat.after(4)); // b is untouched
    // both copies of the table agree
    var first: [block_size]u8 = undefined;
    var second: [block_size]u8 = undefined;
    try rig.disk.read(1, &first);
    try rig.disk.read(3, &second);
    try expectEqualSlices(u8, &first, &second);
    // deleting only marks: a's bytes are still on the disk
    var block: [block_size]u8 = undefined;
    try rig.disk.read(7, &block);
    try expectEqualSlices(u8, a[0..512], &block);

    // c goes where there is room: a's old clusters, then past b
    try fat.create("c.bin", &c);
    try expectEqual(@as(u16, 3), try fat.after(2));
    try expectEqual(@as(u16, 6), try fat.after(3));
    try expectEqual(@as(u16, 7), try fat.after(6));
    const files = try fat.list(ta);
    defer ta.free(files);
    try expectEqual(@as(usize, 2), files.len);
    try expectEqualStrings("C.BIN", files[0].name()); // it took a's directory entry too
    try expectEqualStrings("B.BIN", files[1].name());
    const got_c = try fat.read(ta, "c.bin");
    defer ta.free(got_c);
    try expectEqualSlices(u8, &c, got_c);
    const got_b = try fat.read(ta, "b.bin");
    defer ta.free(got_b);
    try expectEqualSlices(u8, &b, got_b);

    // a deleted entry in the middle doesn't end the listing
    try fat.create("d.txt", "d");
    try fat.remove("b.bin");
    const fewer = try fat.list(ta);
    defer ta.free(fewer);
    try expectEqual(@as(usize, 2), fewer.len);
    try expectEqualStrings("D.TXT", fewer[1].name());
}

test "a full disk says so, and stays as it was" {
    var rig = try Rig.init();
    defer rig.deinit();
    var fat = try Fat.mount(&rig.disk);
    // 60 clusters of 1024 bytes: fill 58
    const most = pattern(58 * 1024, 6);
    try fat.create("most.bin", &most);
    const before = try ta.dupe(u8, rig.card.disk);
    defer ta.free(before);
    const too_big = pattern(2 * 1024 + 1, 7);
    try expectError(error.DiskFull, fat.create("toobig.bin", &too_big));
    try expectEqualSlices(u8, before, rig.card.disk);
    try expectError(error.FileExists, fat.create("MOST.BIN", "x"));
    try expectEqualSlices(u8, before, rig.card.disk);
    // exactly the last two clusters, 60 and 61, which end at the card's last whole pair of blocks
    const fits = pattern(2 * 1024, 8);
    try fat.create("fits.bin", &fits);
    try expectEqual(@as(u16, 61), try fat.after(60));
    try expect(try fat.after(61) >= fat_end);
    const got = try fat.read(ta, "fits.bin");
    defer ta.free(got);
    try expectEqualSlices(u8, &fits, got);
    try expectError(error.DiskFull, fat.create("one.txt", "x"));
    try fat.create("none.txt", ""); // an empty file needs no cluster
    try fat.remove("fits.bin");
    try fat.create("one.txt", "x");
}

test "entries that are not files" {
    var rig = try Rig.init();
    defer rig.deinit();
    var fat = try Fat.mount(&rig.disk);
    try fat.create("a.txt", "a");
    // What a card formatted elsewhere has in its directory: the
    // volume's label, a piece of a long name, a directory. And a file
    // whose name has a character that ours never do.
    var block: [block_size]u8 = undefined;
    try rig.disk.read(fat.layout.root_start, &block);
    for ([_]u8{ 0x08, 0x0f, 0x10 }, 1..) |attributes, n| {
        const raw = block[n * 32 ..][0..32];
        @memset(raw, 0);
        @memcpy(raw[0..11], if (attributes == 0x0f) "Am.y. .l.o." else "ZIGRAD     ");
        raw[11] = attributes;
    }
    @memset(block[4 * 32 ..][0..32], 0);
    @memcpy(block[4 * 32 ..][0..11], "ODD.NAMETXT");
    block[4 * 32 + 11] = 0x20;
    try rig.disk.write(fat.layout.root_start, &block);
    try fat.create("b.txt", "b");
    const files = try fat.list(ta);
    defer ta.free(files);
    try expectEqual(@as(usize, 3), files.len);
    try expectEqualStrings("A.TXT", files[0].name());
    try expectEqualStrings("ODD.NAME.TXT", files[1].name()); // listed, though no name we can ask for finds it
    try expectEqualStrings("B.TXT", files[2].name());
    const got = try fat.read(ta, "b.txt");
    defer ta.free(got);
    try expectEqualStrings("b", got);
    try expectError(error.FileNotFound, fat.read(ta, "zigrad"));
    try fat.create("zigrad", "now a file"); // the label doesn't take the name
}

test "a directory of more than one block, and a full one" {
    var rig = try Rig.init();
    defer rig.deinit();
    var fat = try Fat.mount(&rig.disk);
    var name_buf: [12]u8 = undefined;
    for (0..32) |n| {
        const text = try std.fmt.bufPrint(&name_buf, "f{d}.txt", .{n});
        try fat.create(text, text);
    }
    try expectError(error.DirectoryFull, fat.create("more.txt", "x"));
    const files = try fat.list(ta);
    defer ta.free(files);
    try expectEqual(@as(usize, 32), files.len);
    const data = try fat.read(ta, "f20.txt"); // in the directory's second block
    defer ta.free(data);
    try expectEqualStrings("f20.txt", data);
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

/// The SD card's 7-bit CRC: long division like 231's, but most
/// significant bit first, with the constant 0x09, in a 7-bit register.
fn crc7(bytes: []const u8) u7 {
    var crc: u7 = 0;
    for (bytes) |byte| {
        for (0..8) |k| {
            const bit_in: u1 = @truncate(byte >> @intCast(7 - k));
            const top: u1 = @truncate(crc >> 6);
            crc <<= 1;
            if (top != bit_in) crc ^= 0x09;
        }
    }
    return crc;
}

/// The six bytes of a command.
fn sdCommand(cmd: u6, arg: u32) [6]u8 {
    var frame_bytes: [6]u8 = undefined;
    frame_bytes[0] = 0x40 | @as(u8, cmd);
    std.mem.writeInt(u32, frame_bytes[1..5], arg, .big);
    frame_bytes[5] = @as(u8, crc7(frame_bytes[0..5])) << 1 | 1;
    return frame_bytes;
}

const block_size = 512;

/// Sends a command and returns the card's R1. `spi` is anything with
/// exchange(byte) u8. The card may send up to 8 bytes of 0xff first.
fn sdSend(spi: anytype, cmd: u6, arg: u32) u8 {
    for (sdCommand(cmd, arg)) |byte| _ = spi.exchange(byte);
    for (0..8) |_| {
        const r1 = spi.exchange(0xff);
        if (r1 & 0x80 == 0) return r1;
    }
    return 0xff;
}

/// Wakes the card up.
fn sdInit(spi: anytype) !void {
    // a card wants to see 74 clock ticks before the first command
    for (0..10) |_| _ = spi.exchange(0xff);
    if (sdSend(spi, 0, 0) != 0x01) return error.NoCard;
    for (0..100) |_| {
        if (sdSend(spi, 1, 0) == 0x00) return;
    }
    return error.CardNotReady;
}

/// Reads block number `block`.
fn sdReadBlock(spi: anytype, block: u32, out: *[block_size]u8) !void {
    // the card counts in bytes, in 32 bits: 4 GB, 2^23 blocks, at most
    if (block >= 1 << 23) return error.BlockTooFar;
    if (sdSend(spi, 17, block * block_size) != 0x00) return error.ReadRefused;
    // wait for the start token, but not forever
    var tries: usize = 0;
    while (spi.exchange(0xff) != 0xfe) {
        tries += 1;
        if (tries == 100) return error.NoData;
    }
    for (out) |*byte| byte.* = spi.exchange(0xff);
    _ = spi.exchange(0xff); // the two CRC bytes
    _ = spi.exchange(0xff);
}

/// Writes block number `block`.
fn sdWriteBlock(spi: anytype, block: u32, data: *const [block_size]u8) !void {
    if (block >= 1 << 23) return error.BlockTooFar;
    if (sdSend(spi, 24, block * block_size) != 0x00) return error.WriteRefused;
    _ = spi.exchange(0xfe);
    for (data) |byte| _ = spi.exchange(byte);
    _ = spi.exchange(0xff);
    _ = spi.exchange(0xff);
    // the card answers xxx00101 for "accepted"
    if (spi.exchange(0xff) & 0x1f != 0x05) return error.WriteFailed;
}

/// A model of an SD card on the other end of the wire. `disk` is its
/// contents, a multiple of 512 bytes.
const SdCard = struct {
    disk: []u8,
    ready_after: u8 = 2,
    ready: bool = false,
    command: [6]u8 = undefined,
    have: usize = 0,
    /// what it will send next
    reply: [block_size + 8]u8 = undefined,
    reply_len: usize = 0,
    reply_at: usize = 0,
    /// a write in progress: the address, and how many bytes have arrived (the token first)
    writing: ?u32 = null,
    written: usize = 0,
    /// how many bytes went over the wire, for the curious
    exchanged: usize = 0,

    fn say(card: *SdCard, bytes: []const u8) void {
        @memcpy(card.reply[0..bytes.len], bytes);
        card.reply_len = bytes.len;
        card.reply_at = 0;
    }

    fn exchange(card: *SdCard, mosi: u8) u8 {
        card.exchanged += 1;
        if (card.reply_at < card.reply_len) {
            card.reply_at += 1;
            return card.reply[card.reply_at - 1];
        }
        if (card.writing) |addr| {
            if (card.written == 0 and mosi != 0xfe) return 0xff; // waiting for the token
            card.written += 1;
            if (card.written >= 2 and card.written <= block_size + 1) card.disk[addr + card.written - 2] = mosi;
            if (card.written == block_size + 3) {
                card.writing = null;
                card.say(&.{0xe5}); // accepted
            }
            return 0xff;
        }
        if (card.have == 0 and mosi & 0xc0 != 0x40) return 0xff; // idle
        card.command[card.have] = mosi;
        card.have += 1;
        if (card.have < 6) return 0xff;
        card.have = 0;
        const cmd = card.command[0] & 0x3f;
        const arg = std.mem.readInt(u32, card.command[1..5], .big);
        if (card.command[5] != @as(u8, crc7(card.command[0..5])) << 1 | 1) {
            card.say(&.{ 0xff, 0x09 }); // CRC error
        } else if (cmd == 0) {
            card.ready = false;
            card.ready_after = 2;
            card.say(&.{ 0xff, 0x01 });
        } else if (cmd == 1) {
            if (card.ready_after > 0) card.ready_after -= 1 else card.ready = true;
            card.say(&.{ 0xff, @intFromBool(!card.ready) });
        } else if (!card.ready or (cmd != 17 and cmd != 24)) {
            card.say(&.{ 0xff, 0x05 }); // illegal command
        } else if (arg % block_size != 0 or @as(u64, arg) + block_size > card.disk.len) {
            card.say(&.{ 0xff, 0x41 }); // address error
        } else if (cmd == 17) {
            card.say(&.{ 0xff, 0x00, 0xff, 0xff, 0xff, 0xfe });
            @memcpy(card.reply[6..][0..block_size], card.disk[arg..][0..block_size]);
            card.reply_len = 6 + block_size + 2;
        } else {
            card.say(&.{ 0xff, 0x00 });
            card.writing = arg;
            card.written = 0;
        }
        return 0xff;
    }
};
