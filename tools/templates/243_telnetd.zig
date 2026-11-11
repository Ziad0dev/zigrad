//
// ─── Exercise 243: logging in from far away ───────────────────────────
//
// The shell (240) talks to whoever is at the end of the serial cable.
// A reliable stream of bytes in each direction is ALSO exactly what TCP
// (242) provides. So the two can be joined, and the cable replaced by
// the network: that is telnet, the program people used to log in to
// distant machines from 1969 until encryption became the obvious thing
// to want (ssh, 1995).
//
// The server side, telnetd, is glue. It owns a TCP connection that
// listens on port 23, and it keeps two things in step:
//
//     bytes that arrive on the connection   ->  the machine's keyboard
//     characters the machine prints         ->  bytes sent on the connection
//
// and when the program on the machine ends, it hangs up.
//
// All of the work is bookkeeping: both sides are streams that only ever
// grow, so "what is new" is always "everything after the part I have
// already passed on", and telnetd needs to remember only how far it got
// in each direction.
//
// (In the outline, the TCP stack is C code inside the computer, talking
// to an Ethernet chip. Here the stack stays in Zig, outside the emulated
// machine, as if it were built into the network card, and the machine
// sees a plain serial port. The shell on the inside is unchanged, which
// is the point of layers.)
//
// The test logs in over 242's unreliable wire and uses the shell.
//
// YOUR TASK: poll(), the four steps of the glue.
//
const std = @import("std");

//@export telnetd
const Telnetd = struct {
    alloc: std.mem.Allocator,
    conn: *TcpConn,
    board: *Board,
    cpu: *Cpu,
    /// How much of conn.received has been typed into the machine, and
    /// how much of the machine's output has been sent.
    typed: usize = 0,
    shown: usize = 0,
    /// The keys the machine hasn't read yet. (The emulator's UART reads
    /// from a slice, board.uart_in, and shortens it as it goes.)
    keys: std.ArrayList(u8) = .empty,
    /// The program on the machine has ended.
    over: bool = false,

    fn deinit(t: *Telnetd) void {
        t.keys.deinit(t.alloc);
    }

    /// One turn of the crank. Call it again and again.
    fn poll(t: *Telnetd, steps: usize) !void {
        // 1. What arrived since last time becomes keystrokes.
        const arrived = t.conn.received.items[⟪t.typed|||???⟫..];
        // (drop the keys the machine has read; add the new ones)
        const unread = t.board.uart_in.len;
        t.keys.replaceRangeAssumeCapacity(0, t.keys.items.len - unread, "");
        try t.keys.appendSlice(t.alloc, arrived);
        t.board.uart_in = t.keys.items;
        t.typed = ⟪t.conn.received.items.len|||???⟫;

        // 2. The machine runs for a while.
        if (!t.over and t.cpu.run(t.board, steps) != null) t.over = true;

        // 3. What it printed since last time goes to the other side.
        const printed = t.board.uart_out.items[⟪t.shown|||???⟫..];
        if (printed.len > 0) try t.conn.send(printed);
        t.shown = t.board.uart_out.items.len;

        // 4. When the program has ended, so has the session.
        if (t.over and !t.conn.closing) try ⟪t.conn.close()|||???⟫;
    }
};
//@end

const ta = std.testing.allocator;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

const Session = struct {
    transcript: []u8,
    retransmissions: usize,
};

/// Boots the shell behind a telnetd, connects to it over `wire`, types
/// the lines of `typed` (a new one every few rounds, like a person
/// would), and returns what came back. The machine runs `steps`
/// instructions per poll.
fn loginPaced(wire: *Wire, typed: []const u8, steps: usize) !Session {
    const image = try buildProgram(ta, &.{ shell_c, libc_c }, &.{}, 0);
    defer ta.free(image);
    var board = try Board.init(ta, 0x10000);
    defer board.deinit();
    board.load(0, image);
    var cpu: Cpu = .{};
    var server: TcpConn = .{ .alloc = ta, .local_ip = ipAddr(10, 0, 0, 2), .local_port = 23, .iss = 7000 };
    defer server.deinit();
    var client: TcpConn = .{ .alloc = ta, .local_ip = ipAddr(10, 0, 0, 1), .local_port = 50000, .iss = 300 };
    defer client.deinit();
    var telnetd: Telnetd = .{ .alloc = ta, .conn = &server, .board = &board, .cpu = &cpu };
    defer telnetd.deinit();

    server.listen();
    try client.connect(server.local_ip, 23);
    var lines = std.mem.splitScalar(u8, typed, '\n');
    var rounds: usize = 0;
    while (!(client.peer_closed and server.fin_acked)) : (rounds += 1) {
        if (rounds == 30_000) return error.TooSlow;
        if (rounds % 6 == 0) {
            if (lines.next()) |line| {
                try client.send(line);
                if (lines.peek() != null) try client.send("\n");
            }
        }
        try wire.round(&client, &server);
        try telnetd.poll(steps);
    }
    return .{ .transcript = try ta.dupe(u8, client.received.items), .retransmissions = client.retransmissions + server.retransmissions };
}

fn login(wire: *Wire, typed: []const u8) !Session {
    return loginPaced(wire, typed, 20_000);
}

const typed_script =
    \\put motd greetings from very far away
    \\ls
    \\cat motd
    \\echo bye
    \\exit
    \\
;

const want_transcript =
    \\$ $ motd 29
    \\$ greetings from very far away
    \\$ bye
    \\
++ "$ ";

test "a session over a good wire" {
    var prng = std.Random.DefaultPrng.init(243);
    var wire: Wire = .{ .rand = prng.random() };
    const session = try login(&wire, typed_script);
    defer ta.free(session.transcript);
    try expectEqualStrings(want_transcript, session.transcript);
}

test "the same session over a terrible one" {
    var prng = std.Random.DefaultPrng.init(2430);
    var wire: Wire = .{ .rand = prng.random(), .lose = 25, .damage = 10, .duplicate = 20, .reverse = 30 };
    const session = try login(&wire, typed_script);
    defer ta.free(session.transcript);
    try expectEqualStrings(want_transcript, session.transcript);
    try expect(session.retransmissions > 0);
}

test "a long line, typed faster than the machine reads" {
    var prng = std.Random.DefaultPrng.init(2431);
    var wire: Wire = .{ .rand = prng.random() };
    // 100 instructions per poll: far too few to read a 66-key line in
    // one go, so keys wait, unread, from one poll to the next
    const session = try loginPaced(&wire, "echo " ++ "abcdefghi " ** 6 ++ "\nexit\n", 100);
    defer ta.free(session.transcript);
    try expectEqualStrings("$ " ++ "abcdefghi " ** 5 ++ "abcdefghi\n$ ", session.transcript);
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include tcpip
//@include tcp
//@include tcp_wire
//@include shell
//@include c_lex
//@include c_expr
//@include c_parse
//@include c_gen
//@include c_lower
//@include linker
//@include libc
//@include arm_enc
//@include arm_alu
//@include arm_asm_line
//@include arm_asm
//@include arm_emu
