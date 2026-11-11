//
// ─── Exercise 242: a reliable stream over an unreliable wire ──────────
//
// IP promises almost nothing. A packet may arrive, or not, or twice, or
// after a packet that was sent later, or with bits flipped. TCP turns
// that into what every program wants: bytes that come out the far end
// exactly as they went in, in order, once. It does so with two numbers
// and a clock.
//
// SEQUENCE NUMBERS. Every byte of the stream has a number. A segment
// says "these are bytes number seq, seq + 1, ...". So the receiver can
// tell what it is looking at: the next bytes it needs, bytes it already
// has (a duplicate: ignore), or bytes from further on (something in
// between was lost: ignore those too, in this simple TCP).
//
// ACKNOWLEDGEMENTS. Every segment going the other way carries `ack`:
// "I have everything before byte number ack. That is the one I want
// next." It is cumulative, which makes lost ACKs harmless: the next one
// says the same and more.
//
// THE CLOCK. The sender keeps every byte until it is acknowledged, and
// if no acknowledgement has come for a while, sends them again. That's
// all "reliable" means: keep saying it until the other side says it
// heard.
//
// The numbers don't start at 0. Each side picks its own first number
// and tells the other in a SYN segment, which the other must
// acknowledge, so a connection begins with three segments, the
// *three-way handshake*:
//
//     A -> B   SYN       seq = a                       "my bytes start after a"
//     B -> A   SYN ACK   seq = b,     ack = a + 1      "and mine after b; got yours"
//     A -> B   ACK       seq = a + 1, ack = b + 1      "got yours"
//
// The SYN counts as one byte of the stream (hence a + 1), so that it
// can be acknowledged and resent like data. So does the FIN, the
// segment that says "I have no more to send".
//
// What this TCP leaves out: flow control (the window), congestion
// control (slowing down when the network is full, the part that keeps
// the Internet from collapsing), and keeping out-of-order segments. It
// resends everything unacknowledged ("go back N"). It is correct, and
// it is about 200 lines.
//
// The tests connect two of these across a wire that loses, damages,
// duplicates and reorders packets.
//
// YOUR TASK: the handshake's numbers, what an ACK releases, what data
// is accepted, and the retransmission.
//
const std = @import("std");

const TcpState = enum { closed, listen, syn_sent, syn_received, established };

const tcp_mss = 64; // the most data bytes in one segment (real TCP: about 1460)

const TcpConn = struct {
    alloc: std.mem.Allocator,
    local_ip: u32,
    local_port: u16,
    remote_ip: u32 = 0,
    remote_port: u16 = 0,
    /// Our first sequence number: the SYN's.
    iss: u32,
    state: TcpState = .closed,
    /// The oldest sequence number of ours that hasn't been acknowledged,
    /// counting data only: once the FIN is acknowledged too, snd_una
    /// stays on the FIN's own number, and `fin_acked` says so.
    snd_una: u32 = 0,
    /// The next sequence number we expect from the other side.
    rcv_nxt: u32 = 0,
    /// Bytes given to send() and not yet acknowledged. The first of them
    /// is byte number snd_una. `sent` of them have been transmitted.
    unacked: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    /// What has arrived, in order: for the program to read.
    received: std.ArrayList(u8) = .empty,
    /// IP packets waiting to go onto the wire. Whoever takes one frees it.
    outbox: std.ArrayList([]u8) = .empty,
    /// Ticks since the oldest unacknowledged thing was sent, and how many to wait.
    timer: u32 = 0,
    rto: u32 = 3,
    retransmissions: usize = 0,
    /// close() was called; our FIN has gone out; it was acknowledged;
    /// the other side's FIN has arrived.
    closing: bool = false,
    fin_sent: bool = false,
    fin_acked: bool = false,
    peer_closed: bool = false,

    fn deinit(c: *TcpConn) void {
        for (c.outbox.items) |packet| c.alloc.free(packet);
        c.outbox.deinit(c.alloc);
        c.unacked.deinit(c.alloc);
        c.received.deinit(c.alloc);
    }

    /// Puts a segment in the outbox.
    fn emit(c: *TcpConn, flags: TcpFlags, seq: u32, payload: []const u8) !void {
        const segment = try tcpBuild(c.alloc, c.local_ip, c.remote_ip, .{
            .src_port = c.local_port,
            .dst_port = c.remote_port,
            .seq = seq,
            .ack = if (flags.ack) c.rcv_nxt else 0,
            .flags = flags,
            .payload = payload,
        });
        defer c.alloc.free(segment);
        try c.outbox.append(c.alloc, try ipBuild(c.alloc, c.local_ip, c.remote_ip, ip_proto_tcp, segment));
    }

    fn listen(c: *TcpConn) void {
        c.state = .listen;
    }

    fn connect(c: *TcpConn, ip: u32, port: u16) !void {
        c.remote_ip = ip;
        c.remote_port = port;
        c.snd_una = c.iss;
        c.state = .syn_sent;
        try c.emit(.{ .syn = true }, c.iss, "");
    }

    /// Queues bytes for the other side.
    fn send(c: *TcpConn, bytes: []const u8) !void {
        try c.unacked.appendSlice(c.alloc, bytes);
        try c.pump();
    }

    /// No more data from us (after what is already queued).
    fn close(c: *TcpConn) !void {
        c.closing = true;
        try c.pump();
    }

    /// Both directions are finished.
    fn done(c: *const TcpConn) bool {
        return c.fin_acked and c.peer_closed;
    }

    /// Transmits whatever hasn't been transmitted yet.
    fn pump(c: *TcpConn) !void {
        if (c.state != .established) return;
        while (c.sent < c.unacked.items.len) {
            const n = @min(tcp_mss, c.unacked.items.len - c.sent);
            try c.emit(.{ .ack = true, .psh = true }, c.snd_una +% @as(u32, @intCast(c.sent)), c.unacked.items[c.sent..][0..n]);
            c.sent += n;
        }
        if (c.closing and !c.fin_sent) {
            // the FIN takes the sequence number after the last byte
            try c.emit(.{ .ack = true, .fin = true }, c.snd_una +% @as(u32, @intCast(c.unacked.items.len)), "");
            c.fin_sent = true;
        }
    }

    /// Is there anything of ours out there that hasn't been acknowledged?
    fn waiting(c: *const TcpConn) bool {
        return c.state == .syn_sent or c.state == .syn_received or c.unacked.items.len > 0 or (c.fin_sent and !c.fin_acked);
    }

    /// The clock. Call it regularly.
    fn tick(c: *TcpConn) !void {
        if (!c.waiting()) {
            c.timer = 0;
            return;
        }
        c.timer += 1;
        if (c.timer < c.rto) return;
        // Too long without an acknowledgement: say it all again.
        c.timer = 0;
        c.retransmissions += 1;
        switch (c.state) {
            .syn_sent => try c.emit(.{ .syn = true }, c.iss, ""),
            .syn_received => try c.emit(.{ .syn = true, .ack = true }, c.iss, ""),
            .established => {
                // go back to the oldest unacknowledged byte: as if
                // nothing had been transmitted
                c.sent = ???;
                c.fin_sent = false;
                try c.pump();
            },
            else => {},
        }
    }

    /// An acknowledgement: the other side has everything before `ack`.
    fn acknowledged(c: *TcpConn, ack: u32) void {
        // what is out there: the unacked bytes, and maybe a FIN after them
        const outstanding: u32 = @intCast(c.unacked.items.len + @intFromBool(c.fin_sent));
        // Only an ack that is PAST snd_una is news, and one past
        // everything we ever sent is nonsense.
        if (!seqBefore(c.snd_una, ack) or seqBefore(c.snd_una +% outstanding, ack)) return;
        const count: usize = ???; // how many sequence numbers it covers
        const bytes = @min(count, c.unacked.items.len);
        // those bytes are safe on the other side: forget them
        c.unacked.replaceRangeAssumeCapacity(0, bytes, "");
        c.snd_una +%= @intCast(bytes);
        c.sent -= @min(c.sent, bytes);
        if (count > bytes) c.fin_acked = true; // one more than the bytes: our FIN
        c.timer = 0; // progress: the clock starts again
    }

    /// The data (and FIN) of a segment.
    fn accept(c: *TcpConn, seg: TcpSegment) !void {
        if (seg.payload.len == 0 and !seg.flags.fin) return;
        // Take it only if it starts exactly where our stream stops.
        if (seg.seq == ???) {
            try c.received.appendSlice(c.alloc, seg.payload);
            c.rcv_nxt +%= ???;
            if (seg.flags.fin) {
                c.rcv_nxt +%= 1;
                c.peer_closed = true;
            }
        }
        // Accepted or not, say where we stand. For a duplicate, this
        // tells the sender to stop resending; for a segment from further
        // on, where the gap is.
        try c.emit(.{ .ack = true }, c.snd_una +% @as(u32, @intCast(c.sent)) +% @intFromBool(c.fin_sent), "");
    }

    /// A packet has arrived off the wire.
    fn receive(c: *TcpConn, packet: []const u8) !void {
        // damaged or not for us: as if it had never arrived
        const ip = ipParse(packet) catch return;
        if (ip.dst != c.local_ip or ip.proto != ip_proto_tcp) return;
        const seg = tcpParse(ip.src, ip.dst, ip.payload) catch return;
        if (seg.dst_port != c.local_port) return;
        if (c.state != .listen and (ip.src != c.remote_ip or seg.src_port != c.remote_port)) return;

        switch (c.state) {
            .closed => {},
            .listen => {
                if (!seg.flags.syn or seg.flags.ack) return;
                c.remote_ip = ip.src;
                c.remote_port = seg.src_port;
                // the SYN used up one sequence number
                c.rcv_nxt = ???;
                c.snd_una = c.iss;
                c.state = .syn_received;
                try c.emit(.{ .syn = true, .ack = true }, c.iss, "");
            },
            .syn_sent => {
                // the answer must acknowledge OUR SYN
                if (!seg.flags.syn or !seg.flags.ack or seg.ack != ???) return;
                c.rcv_nxt = seg.seq +% 1;
                c.snd_una = c.iss +% 1;
                c.state = .established;
                c.timer = 0;
                try c.emit(.{ .ack = true }, c.snd_una, "");
                try c.pump();
            },
            .syn_received => {
                if (seg.flags.syn) {
                    // our SYN ACK was lost and the SYN came again
                    try c.emit(.{ .syn = true, .ack = true }, c.iss, "");
                    return;
                }
                if (!seg.flags.ack or seg.ack != c.iss +% 1) return;
                c.snd_una = c.iss +% 1;
                c.state = .established;
                c.timer = 0;
                try c.accept(seg); // the third segment may carry data already
                try c.pump();
            },
            .established => {
                if (seg.flags.syn) {
                    // our last handshake ACK was lost: the other side is still asking
                    try c.emit(.{ .ack = true }, c.snd_una, "");
                    return;
                }
                if (seg.flags.ack) c.acknowledged(seg.ack);
                try c.accept(seg);
                try c.pump();
            },
        }
    }
};

const ta = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const ip_a = ipAddr(10, 0, 0, 1);
const ip_b = ipAddr(10, 0, 0, 2);

/// A wire between two connections that mistreats packets.
const Wire = struct {
    rand: std.Random,
    lose: u8 = 0, // each a chance in 100
    damage: u8 = 0,
    duplicate: u8 = 0,
    reverse: u8 = 0,
    carried: usize = 0,

    fn carry(w: *Wire, from: *TcpConn, to: *TcpConn) !void {
        var batch = from.outbox;
        from.outbox = .empty;
        defer batch.deinit(from.alloc);
        defer for (batch.items) |packet| from.alloc.free(packet);
        if (w.rand.uintLessThan(u8, 100) < w.reverse) std.mem.reverse([]u8, batch.items);
        for (batch.items) |packet| {
            w.carried += 1;
            if (w.rand.uintLessThan(u8, 100) < w.lose) continue;
            if (w.rand.uintLessThan(u8, 100) < w.damage) packet[w.rand.uintLessThan(usize, packet.len)] ^= @as(u8, 1) << w.rand.int(u3);
            try to.receive(packet);
            if (w.rand.uintLessThan(u8, 100) < w.duplicate) try to.receive(packet);
        }
    }

    /// One round: everything in both outboxes crosses, and time passes.
    fn round(w: *Wire, a: *TcpConn, b: *TcpConn) !void {
        try w.carry(a, b);
        try w.carry(b, a);
        try a.tick();
        try b.tick();
    }
};

fn pair(iss_a: u32, iss_b: u32) [2]TcpConn {
    return .{
        .{ .alloc = ta, .local_ip = ip_a, .local_port = 49152, .iss = iss_a },
        .{ .alloc = ta, .local_ip = ip_b, .local_port = 80, .iss = iss_b },
    };
}

fn onlyPacket(c: *TcpConn) !TcpSegment {
    try expectEqual(@as(usize, 1), c.outbox.items.len);
    const ip = try ipParse(c.outbox.items[0]);
    return tcpParse(ip.src, ip.dst, ip.payload);
}

test "the three-way handshake, segment by segment" {
    var conns = pair(1000, 5000);
    const a = &conns[0];
    const b = &conns[1];
    defer a.deinit();
    defer b.deinit();
    var prng = std.Random.DefaultPrng.init(1);
    var wire: Wire = .{ .rand = prng.random() };
    b.listen();
    try a.connect(ip_b, 80);
    const syn = try onlyPacket(a);
    try expect(syn.flags.syn and !syn.flags.ack);
    try expectEqual(@as(u32, 1000), syn.seq);
    try expectEqual(TcpState.syn_sent, a.state);

    try wire.carry(a, b);
    const syn_ack = try onlyPacket(b);
    try expect(syn_ack.flags.syn and syn_ack.flags.ack);
    try expectEqual(@as(u32, 5000), syn_ack.seq);
    try expectEqual(@as(u32, 1001), syn_ack.ack);
    try expectEqual(TcpState.syn_received, b.state);
    try expectEqual(@as(u16, 49152), b.remote_port);

    try wire.carry(b, a);
    const ack = try onlyPacket(a);
    try expect(ack.flags.ack and !ack.flags.syn);
    try expectEqual(@as(u32, 1001), ack.seq);
    try expectEqual(@as(u32, 5001), ack.ack);
    try expectEqual(TcpState.established, a.state);

    try wire.carry(a, b);
    try expectEqual(TcpState.established, b.state);
    try expectEqual(@as(usize, 0), b.outbox.items.len); // nothing to say to a bare ACK
}

test "a SYN ACK that acknowledges the wrong number is not ours" {
    var conns = pair(1000, 5000);
    const a = &conns[0];
    defer a.deinit();
    try a.connect(ip_b, 80);
    ta.free(a.outbox.pop().?);
    for ([_]u32{ 1000, 1002, 0 }) |wrong| {
        const segment = try tcpBuild(ta, ip_b, ip_a, .{ .src_port = 80, .dst_port = 49152, .seq = 5000, .ack = wrong, .flags = .{ .syn = true, .ack = true } });
        defer ta.free(segment);
        const packet = try ipBuild(ta, ip_b, ip_a, ip_proto_tcp, segment);
        defer ta.free(packet);
        try a.receive(packet);
        try expectEqual(TcpState.syn_sent, a.state);
    }
}

fn testData(comptime len: usize, seed: u64) [len]u8 {
    var bytes: [len]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(&bytes);
    return bytes;
}

/// Connects a to b over the wire, sends data both ways, closes, and
/// checks that all of it arrived.
fn exchange(wire: *Wire, iss_a: u32, iss_b: u32, max_rounds: usize) ![2]TcpConn {
    var conns = pair(iss_a, iss_b);
    const a = &conns[0];
    const b = &conns[1];
    errdefer a.deinit();
    errdefer b.deinit();
    const request = testData(700, 11);
    const reply = testData(3000, 22);
    b.listen();
    try a.connect(ip_b, 80);
    try a.send(&request); // queued: it goes out when the handshake is done
    var replied = false;
    var rounds: usize = 0;
    while (!(a.done() and b.done())) : (rounds += 1) {
        if (rounds == max_rounds) return error.TooSlow;
        try wire.round(a, b);
        // b answers once it has the whole request, and then both hang up
        if (!replied and b.received.items.len == request.len) {
            replied = true;
            try b.send(&reply);
            try b.close();
            try a.close();
        }
    }
    try expectEqualSlices(u8, &request, b.received.items);
    try expectEqualSlices(u8, &reply, a.received.items);
    return conns;
}

test "a perfect wire" {
    var prng = std.Random.DefaultPrng.init(2);
    var wire: Wire = .{ .rand = prng.random() };
    var conns = try exchange(&wire, 1000, 5000, 20);
    defer conns[0].deinit();
    defer conns[1].deinit();
    try expectEqual(@as(usize, 0), conns[0].retransmissions + conns[1].retransmissions);
    // every acknowledged byte was forgotten
    try expectEqual(@as(usize, 0), conns[0].unacked.items.len + conns[1].unacked.items.len);
    try expectEqual(@as(u32, 1000 + 1 + 700), conns[0].snd_una);
    try expectEqual(@as(u32, 5000 + 1 + 3000 + 1), conns[0].rcv_nxt); // b's SYN, data and FIN
}

test "a wire that loses a third of everything" {
    var prng = std.Random.DefaultPrng.init(3);
    var wire: Wire = .{ .rand = prng.random(), .lose = 33 };
    var conns = try exchange(&wire, 1000, 5000, 2000);
    defer conns[0].deinit();
    defer conns[1].deinit();
    try expect(conns[0].retransmissions > 0 and conns[1].retransmissions > 0);
}

test "damage, duplicates and packets out of order" {
    var prng = std.Random.DefaultPrng.init(4);
    var wire: Wire = .{ .rand = prng.random(), .damage = 20, .duplicate = 30, .reverse = 50 };
    var conns = try exchange(&wire, 1000, 5000, 2000);
    defer conns[0].deinit();
    defer conns[1].deinit();
}

test "everything at once, with sequence numbers that wrap around" {
    for (0..5) |seed| {
        var prng = std.Random.DefaultPrng.init(50 + seed);
        var wire: Wire = .{ .rand = prng.random(), .lose = 20, .damage = 10, .duplicate = 20, .reverse = 30 };
        // a's numbers pass 0xffffffff in the middle of its data, b's during the handshake
        var conns = try exchange(&wire, 0xffffffff - 300, 0xffffffff, 3000);
        defer conns[0].deinit();
        defer conns[1].deinit();
    }
}

test "packets for someone else are ignored" {
    var conns = pair(1000, 5000);
    const a = &conns[0];
    const b = &conns[1];
    defer a.deinit();
    defer b.deinit();
    var prng = std.Random.DefaultPrng.init(6);
    var wire: Wire = .{ .rand = prng.random() };
    b.listen();
    try a.connect(ip_b, 80);
    for (0..3) |_| try wire.round(a, b);
    // a stranger sends data to b's port, with plausible numbers
    const segment = try tcpBuild(ta, ipAddr(10, 0, 0, 66), ip_b, .{ .src_port = 49152, .dst_port = 80, .seq = 1001, .ack = 5001, .flags = .{ .ack = true }, .payload = "evil" });
    defer ta.free(segment);
    const packet = try ipBuild(ta, ipAddr(10, 0, 0, 66), ip_b, ip_proto_tcp, segment);
    defer ta.free(packet);
    try b.receive(packet);
    try expectEqual(@as(usize, 0), b.received.items.len);
    // an acknowledgement of bytes that were never sent changes nothing
    try a.send("hello");
    const bogus = try tcpBuild(ta, ip_b, ip_a, .{ .src_port = 80, .dst_port = 49152, .seq = 5001, .ack = 1001 + 500, .flags = .{ .ack = true } });
    defer ta.free(bogus);
    const bogus_packet = try ipBuild(ta, ip_b, ip_a, ip_proto_tcp, bogus);
    defer ta.free(bogus_packet);
    try a.receive(bogus_packet);
    try expectEqual(@as(usize, 5), a.unacked.items.len);
    for (0..3) |_| try wire.round(a, b);
    try std.testing.expectEqualStrings("hello", b.received.items);
    try expectEqual(@as(usize, 0), a.unacked.items.len);
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

/// The Internet checksum of some bytes, added to a running `sum` (pass
/// 0 to start; pass the result on to checksum several pieces as one).
/// An odd byte at the end counts as the HIGH half of a last word.
fn checksumAdd(sum: u32, bytes: []const u8) u32 {
    var total = sum;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        total += @as(u32, bytes[i]) << 8 | bytes[i + 1];
    }
    if (i < bytes.len) total += @as(u32, bytes[i]) << 8;
    return total;
}

/// Folds the carries back in, and inverts: the 16 bits that go in the
/// header.
fn checksumFinish(sum: u32) u16 {
    var total = sum;
    // whatever is above bit 15 is added back at the bottom, until nothing is
    while (total >> 16 != 0) total = (total & 0xffff) + (total >> 16);
    return ~@as(u16, @intCast(total));
}

/// Is sequence number a before b? (They wrap around.)
fn seqBefore(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
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
    const packet = try alloc.alloc(u8, 20 + payload.len);
    const h = packet[0..20];
    @memset(h, 0);
    h[0] = 0x45;
    std.mem.writeInt(u16, h[2..4], @intCast(packet.len), .big);
    h[8] = 64; // ttl
    h[9] = proto;
    std.mem.writeInt(u32, h[12..16], src, .big);
    std.mem.writeInt(u32, h[16..20], dst, .big);
    // the checksum of the header, worked out while its own field is 0
    std.mem.writeInt(u16, h[10..12], checksumFinish(checksumAdd(0, h)), .big);
    @memcpy(packet[20..], payload);
    return packet;
}

/// Checks and opens an IP packet. The payload points into `packet`.
fn ipParse(packet: []const u8) !IpPacket {
    if (packet.len < 20 or packet[0] != 0x45) return error.BadIpHeader;
    const total = std.mem.readInt(u16, packet[2..4], .big);
    if (total < 20 or total > packet.len) return error.BadIpLength;
    // a correct header, summed WITH its checksum, finishes as 0
    if (checksumFinish(checksumAdd(0, packet[0..20])) != 0) return error.BadIpChecksum;
    return .{
        .src = std.mem.readInt(u32, packet[12..16], .big),
        .dst = std.mem.readInt(u32, packet[16..20], .big),
        .proto = packet[9],
        .ttl = packet[8],
        .payload = packet[20..total],
    };
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
    const bytes = try alloc.alloc(u8, 20 + seg.payload.len);
    const h = bytes[0..20];
    @memset(h, 0);
    std.mem.writeInt(u16, h[0..2], seg.src_port, .big);
    std.mem.writeInt(u16, h[2..4], seg.dst_port, .big);
    std.mem.writeInt(u32, h[4..8], seg.seq, .big);
    std.mem.writeInt(u32, h[8..12], seg.ack, .big);
    h[12] = 5 << 4; // the header is 5 words long
    h[13] = @bitCast(seg.flags);
    std.mem.writeInt(u16, h[14..16], seg.window, .big);
    @memcpy(bytes[20..], seg.payload);
    // over the pseudo-header and then the whole segment, its own field still 0
    const sum = checksumAdd(pseudoSum(src, dst, bytes.len), bytes);
    std.mem.writeInt(u16, h[16..18], checksumFinish(sum), .big);
    return bytes;
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
