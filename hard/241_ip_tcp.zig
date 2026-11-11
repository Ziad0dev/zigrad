// HARD MODE (zig build -Dhard): no blanks to fill in. Every function
// marked ??? has lost its whole body: write it, from its doc comment,
// its signature and the tests. The gentler version of this file is in
// exercises/, and the answer in solutions/.
//
// ─── Exercise 241: packets ────────────────────────────────────────────
//
// Chapter 47: a browser. The last stretch of the outline goes from one
// computer to all of them. A web page arrives through four layers, each
// wrapped inside the one below like letters in envelopes:
//
//     Ethernet frame (231)    gets a packet to the next machine on the wire
//       IP packet             gets it across the world, hop by hop, to an ADDRESS
//         TCP segment         makes a reliable stream to a PORT on that machine
//           HTTP              asks for the page
//
// This exercise is the two middle envelopes: what the bytes are. The
// next one is what TCP does with them.
//
// An IP header is 20 bytes. All numbers in network headers are
// big-endian, the high byte first ("network byte order"):
//
//      0      1      2      3
//     ┌──────┬──────┬─────────────┐
//     │ 0x45 │  0   │ total length│   0x45: version 4, header of 5 words
//     ├──────┴──────┼─────────────┤
//     │     id      │ flags, frag │
//     ├──────┬──────┼─────────────┤
//     │ ttl  │proto │  checksum   │   proto 6 = TCP
//     ├──────┴──────┴─────────────┤   ttl: each router subtracts 1, and
//     │      source address       │   throws the packet away at 0, so a
//     ├───────────────────────────┤   packet going in circles dies
//     │    destination address    │
//     └───────────────────────────┘
//
// A TCP header is 20 bytes too: two ports, two 32-bit sequence numbers
// (242), a byte of flags, a window, a checksum.
//
// THE INTERNET CHECKSUM, used by both, is from 1974 and designed to be
// cheap on any machine: add the data up as 16-bit numbers, and whenever
// the sum overflows 16 bits, add the overflow back in at the bottom
// ("end-around carry"). Send the inverse of the sum. The receiver adds
// up everything including that field, and must get 0xffff: its inverse,
// 0, is "no error". It is much weaker than 231's CRC (swap two words and
// it can't tell), which is why Ethernet has the CRC as well.
//
// TCP's checksum also covers a few fields of the IP header that it
// lives in (the *pseudo-header*: both addresses, the protocol and the
// length), so that a segment delivered to the wrong machine fails it.
//
// SEQUENCE NUMBERS count the bytes of a stream, and they are 32 bits
// that wrap around: after 0xffffffff comes 0. So "is a before b?" can't
// be `a < b`. The trick: subtract, and look at the sign of the
// difference as a signed number. It works as long as the two are less
// than 2^31 apart, which TCP makes sure of.
//
// YOUR TASK: the checksum, the sequence comparison, and the two
// headers' fiddly fields.
//
const std = @import("std");

/// The Internet checksum of some bytes, added to a running `sum` (pass
/// 0 to start; pass the result on to checksum several pieces as one).
/// An odd byte at the end counts as the HIGH half of a last word.
fn checksumAdd(sum: u32, bytes: []const u8) u32 {
    ???; // write this function's body
}

/// Folds the carries back in, and inverts: the 16 bits that go in the
/// header.
fn checksumFinish(sum: u32) u16 {
    ???; // write this function's body
}

/// Is sequence number a before b? (They wrap around.)
fn seqBefore(a: u32, b: u32) bool {
    ???; // write this function's body
}

const ip_proto_tcp: u8 = 6;

const IpPacket = struct {
    src: u32,
    dst: u32,
    proto: u8,
    ttl: u8,
    payload: []const u8,
};

/// An IP packet around `payload`. The caller frees it.
fn ipBuild(alloc: std.mem.Allocator, src: u32, dst: u32, proto: u8, payload: []const u8) ![]u8 {
    ???; // write this function's body
}

/// Checks and opens an IP packet. The payload points into `packet`.
fn ipParse(packet: []const u8) !IpPacket {
    ???; // write this function's body
}

const TcpFlags = packed struct(u8) {
    fin: bool = false,
    syn: bool = false,
    rst: bool = false,
    psh: bool = false,
    ack: bool = false,
    _unused: u3 = 0,
};

const TcpSegment = struct {
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32 = 0,
    flags: TcpFlags = .{},
    window: u16 = 0xffff,
    payload: []const u8 = "",
};

/// The sum of the pseudo-header: the addresses, a zero byte and the
/// protocol, and the length of the TCP segment (header and data).
fn pseudoSum(src: u32, dst: u32, tcp_len: usize) u32 {
    var pseudo: [12]u8 = undefined;
    std.mem.writeInt(u32, pseudo[0..4], src, .big);
    std.mem.writeInt(u32, pseudo[4..8], dst, .big);
    pseudo[8] = 0;
    pseudo[9] = ip_proto_tcp;
    std.mem.writeInt(u16, pseudo[10..12], @intCast(tcp_len), .big);
    return checksumAdd(0, &pseudo);
}

/// The bytes of a TCP segment travelling from `src` to `dst`. The
/// caller frees them.
fn tcpBuild(alloc: std.mem.Allocator, src: u32, dst: u32, seg: TcpSegment) ![]u8 {
    ???; // write this function's body
}

/// Checks and opens a TCP segment that an IP packet from `src` to `dst`
/// carried. The payload points into `bytes`.
fn tcpParse(src: u32, dst: u32, bytes: []const u8) !TcpSegment {
    if (bytes.len < 20) return error.BadTcpHeader;
    const header_len: usize = @as(usize, bytes[12] >> 4) * 4;
    if (header_len < 20 or header_len > bytes.len) return error.BadTcpHeader;
    if (checksumFinish(checksumAdd(pseudoSum(src, dst, bytes.len), bytes)) != 0) return error.BadTcpChecksum;
    return .{
        .src_port = std.mem.readInt(u16, bytes[0..2], .big),
        .dst_port = std.mem.readInt(u16, bytes[2..4], .big),
        .seq = std.mem.readInt(u32, bytes[4..8], .big),
        .ack = std.mem.readInt(u32, bytes[8..12], .big),
        .flags = @bitCast(bytes[13]),
        .window = std.mem.readInt(u16, bytes[14..16], .big),
        .payload = bytes[header_len..],
    };
}

/// 10.0.0.2 as the 32-bit number it is.
fn ipAddr(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) << 24 | @as(u32, b) << 16 | @as(u32, c) << 8 | d;
}

const ta = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

test "the checksum" {
    // the example from RFC 1071, the checksum's own description
    try expectEqual(@as(u32, 0x2ddf0), checksumAdd(0, &.{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 }));
    try expectEqual(@as(u16, 0x220d), checksumFinish(0x2ddf0));
    try expectEqual(@as(u16, 0xffff), checksumFinish(0));
    try expectEqual(@as(u16, 0), checksumFinish(0xffff));
    try expectEqual(@as(u16, 0xfffe), checksumFinish(0x10000)); // the carry comes back in as 1
    try expectEqual(@as(u16, 0xfffe), checksumFinish(0x1ffff)); // and a fold can carry again
    try expectEqual(@as(u16, ~@as(u16, 0xab00)), checksumFinish(checksumAdd(0, &.{0xab}))); // an odd byte is a high byte
    try expectEqual(checksumAdd(0, &.{ 1, 2, 3, 4, 5, 6 }), checksumAdd(checksumAdd(0, &.{ 1, 2 }), &.{ 3, 4, 5, 6 }));
    // a real IP header (the example on the checksum's Wikipedia page)
    const header = [_]u8{ 0x45, 0x00, 0x00, 0x73, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11, 0x00, 0x00, 0xc0, 0xa8, 0x00, 0x01, 0xc0, 0xa8, 0x00, 0xc7 };
    try expectEqual(@as(u16, 0xb861), checksumFinish(checksumAdd(0, &header)));
}

test "before and after, on a circle" {
    try expect(seqBefore(1, 2));
    try expect(!seqBefore(2, 1));
    try expect(!seqBefore(5, 5));
    try expect(seqBefore(0xffffffff, 0)); // 0 comes after the largest number
    try expect(seqBefore(0xfffffff0, 0x10));
    try expect(!seqBefore(0x10, 0xfffffff0));
    try expect(seqBefore(0x7fffffff, 0x80000000));
    try expect(seqBefore(0, 0x7fffffff));
}

const here = ipAddr(10, 0, 0, 1);
const there = ipAddr(10, 0, 0, 2);

test "an IP packet, there and back" {
    const packet = try ipBuild(ta, here, there, ip_proto_tcp, "payload!");
    defer ta.free(packet);
    try expectEqualSlices(u8, &.{ 0x45, 0, 0, 28, 0, 0, 0, 0, 64, 6 }, packet[0..10]);
    try expectEqualSlices(u8, &.{ 10, 0, 0, 1, 10, 0, 0, 2 }, packet[12..20]);
    // 0x4500 + 28 + 0x4006 + 0x0a00 + 1 + 0x0a00 + 2 = 0x9925
    try expectEqual(@as(u16, ~@as(u16, 0x9925)), std.mem.readInt(u16, packet[10..12], .big));
    const parsed = try ipParse(packet);
    try expectEqual(here, parsed.src);
    try expectEqual(there, parsed.dst);
    try expectEqual(@as(u8, 6), parsed.proto);
    try std.testing.expectEqualStrings("payload!", parsed.payload);
    // Ethernet pads short frames (231): what follows the packet is not part of it
    const padded = try std.mem.concat(ta, u8, &.{ packet, &[_]u8{0} ** 18 });
    defer ta.free(padded);
    try std.testing.expectEqualStrings("payload!", (try ipParse(padded)).payload);
    // damage
    for (0..20) |where| {
        packet[where] ^= 0x04;
        try expect(std.meta.isError(ipParse(packet)));
        packet[where] ^= 0x04;
    }
    try expectError(error.BadIpLength, ipParse(packet[0..24]));
    try expectError(error.BadIpHeader, ipParse(packet[0..10]));
}

test "a TCP segment, there and back" {
    const seg: TcpSegment = .{ .src_port = 49152, .dst_port = 80, .seq = 0x01020304, .ack = 0xa0b0c0d0, .flags = .{ .ack = true, .psh = true }, .window = 4096, .payload = "GET /" };
    const bytes = try tcpBuild(ta, here, there, seg);
    defer ta.free(bytes);
    try expectEqualSlices(u8, &.{ 0xc0, 0x00, 0x00, 0x50, 1, 2, 3, 4, 0xa0, 0xb0, 0xc0, 0xd0, 0x50, 0x18, 0x10, 0x00 }, bytes[0..16]);
    const parsed = try tcpParse(here, there, bytes);
    try expectEqual(seg.seq, parsed.seq);
    try expectEqual(seg.ack, parsed.ack);
    try expectEqual(seg.flags, parsed.flags);
    try expectEqual(@as(u16, 80), parsed.dst_port);
    try expectEqual(@as(u16, 4096), parsed.window);
    try std.testing.expectEqualStrings("GET /", parsed.payload);
    // the flags, one by one
    try expectEqual(@as(u8, 0x02), @as(u8, @bitCast(TcpFlags{ .syn = true })));
    try expectEqual(@as(u8, 0x12), @as(u8, @bitCast(TcpFlags{ .syn = true, .ack = true })));
    try expectEqual(@as(u8, 0x11), @as(u8, @bitCast(TcpFlags{ .fin = true, .ack = true })));
    // damage anywhere is noticed
    for (0..bytes.len) |where| {
        bytes[where] ^= 0x20;
        try expect(std.meta.isError(tcpParse(here, there, bytes)));
        bytes[where] ^= 0x20;
    }
    // and so is the right segment at the wrong address
    try expectError(error.BadTcpChecksum, tcpParse(here, ipAddr(10, 0, 0, 3), bytes));
    // ...but not with the two addresses swapped. A sum doesn't care about
    // order: that is this checksum's weakness.
    _ = try tcpParse(there, here, bytes);
    // a segment with no data and an odd-length one both check out
    for ([_][]const u8{ "", "x", "xy", "odd" }) |payload| {
        const b = try tcpBuild(ta, here, there, .{ .src_port = 1, .dst_port = 2, .seq = 3, .payload = payload });
        defer ta.free(b);
        try std.testing.expectEqualStrings(payload, (try tcpParse(here, there, b)).payload);
    }
}

test "envelopes inside envelopes" {
    const segment = try tcpBuild(ta, here, there, .{ .src_port = 1234, .dst_port = 23, .seq = 1, .flags = .{ .syn = true } });
    defer ta.free(segment);
    const packet = try ipBuild(ta, here, there, ip_proto_tcp, segment);
    defer ta.free(packet);
    const ip = try ipParse(packet);
    const tcp = try tcpParse(ip.src, ip.dst, ip.payload);
    try expect(tcp.flags.syn and !tcp.flags.ack);
    try expectEqual(@as(u16, 23), tcp.dst_port);
}
