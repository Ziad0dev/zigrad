//
// ─── Exercise 245: a web browser ──────────────────────────────────────
//
// The last exercise, and the title of the outline this part follows.
// A text browser is three small things on top of a reliable stream:
//
// 1. A URL says where to connect and what to ask for:
//
//        http://10.0.0.2:8080/docs/index.html
//               └─host──┘ └port┘└────path────┘      port 80 if it isn't given,
//                                                   path "/" if there is none
//
// 2. HTTP, at its simplest, is text. The browser connects and says
//
//        GET /docs/index.html HTTP/1.0
//        Host: 10.0.0.2
//                                          <- an empty line: "that's all"
//
//    Every line ends with \r\n (a carriage return and a newline, like a
//    teletype). The server answers in the same shape, a status line,
//    headers, an empty line, and then the page, and hangs up:
//
//        HTTP/1.0 200 OK
//        Content-Type: text/html
//
//        <html>...
//
// 3. HTML is text with *tags* in angle brackets. A text browser's job
//    is mostly to throw them away, with a little judgment:
//
//        <p> <h1> <div> <li> <br> ...   start a new line (a paragraph
//                                       gets an empty line before it)
//        <b> <i> <span> <a> ...         mean nothing here: the words go on
//        <script> <style>               and everything inside: not text
//        &lt; &amp; &#65; ...           *entities*: characters that
//                                       couldn't be written directly
//        runs of spaces and newlines    count as ONE space: the page's
//                                       own line breaks mean nothing
//        <a href="...">                 a link: the words get a number,
//                                       [1], and the address is listed
//                                       at the bottom, as lynx does
//
//    and then the words are *wrapped*: put on a line until the next one
//    wouldn't fit, then onto a new line.
//
// The final test serves a page from one TCP endpoint and browses it
// from another, across 242's lossy wire: your browser, on your TCP, in
// your IP packets. (Run it on your computer in C, over your Ethernet
// frames, and you have built everything the outline's title promises.
// Every piece is here.)
//
// YOUR TASK: the URL, the request, splitting the response, entities,
// and wrapping.
//
const std = @import("std");

const Url = struct { host: []const u8, port: u16, path: []const u8 };

fn parseUrl(url: []const u8) !Url {
    const scheme = "http://";
    if (!std.mem.startsWith(u8, url, scheme)) return error.NotHttp;
    const rest = url[scheme.len..];
    // the host (and port) end at the first slash, if there is one
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = if (slash < rest.len) ??? else "/";
    const colon = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
    const port: u16 = if (colon < authority.len) std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.BadPort else ???;
    if (colon == 0) return error.NoHost;
    return .{ .host = authority[0..colon], .port = port, .path = path };
}

/// What the browser sends. The caller frees it.
fn httpRequest(alloc: std.mem.Allocator, url: Url) ![]u8 {
    return std.fmt.allocPrint(alloc, ???, .{ url.path, url.host });
}

const HttpResponse = struct { status: u16, body: []const u8 };

/// Splits what the server sent. The body points into `bytes`.
fn httpParse(bytes: []const u8) !HttpResponse {
    // "HTTP/1.0 200 OK": the status is the second word of the first line
    var words = std.mem.tokenizeScalar(u8, bytes[0 .. std.mem.indexOf(u8, bytes, "\r\n") orelse return error.BadResponse], ' ');
    if (!std.mem.startsWith(u8, words.next() orelse return error.BadResponse, "HTTP/")) return error.BadResponse;
    const status = std.fmt.parseInt(u16, words.next() orelse return error.BadResponse, 10) catch return error.BadResponse;
    // the body starts after the first EMPTY line
    const blank = std.mem.indexOf(u8, bytes, ???) orelse return error.BadResponse;
    return .{ .status = status, .body = bytes[blank + 4 ..] };
}

/// The character an entity stands for: `name` is what is between the &
/// and the ; ("amp", "lt", "#65"). null if we don't know it.
fn entity(name: []const u8) ?u8 {
    const named = [_]struct { []const u8, u8 }{ .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "quot", '"' }, .{ "apos", '\'' }, .{ "nbsp", ' ' } };
    for (named) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    // &#65; is the character with that number
    if (name.len > 1 and name[0] == '#') {
        const number = std.fmt.parseInt(u8, ???, 10) catch return null;
        // a control character (&#0;, &#10;) would break the page's lines: a space will do
        return if (number < ' ') ' ' else number;
    }
    return null;
}

/// A word of the page, and how many line breaks must come before it.
const Word = struct { text: []const u8, breaks: u8 };

fn tagIs(name: []const u8, comptime list: []const []const u8) bool {
    inline for (list) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

/// The value of an attribute in a tag's text: `href` in
/// `a class="nav" href="/x"`. It may be in double quotes, in single
/// quotes, or bare. null if the tag doesn't have it.
fn attribute(inside: []const u8, comptime name: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(inside, at, name ++ "=")) |found| : (at = found + 1) {
        // a whole name: `data-href=` is another attribute
        if (found == 0 or !std.ascii.isWhitespace(inside[found - 1])) continue;
        const start = found + name.len + 1;
        if (start < inside.len and (inside[start] == '"' or inside[start] == '\'')) {
            const end = std.mem.indexOfScalarPos(u8, inside, start + 1, inside[start]) orelse inside.len;
            return inside[start + 1 .. end];
        }
        const end = std.mem.indexOfAnyPos(u8, inside, start, " \t\r\n") orelse inside.len;
        return inside[start..end];
    }
    return null;
}

/// HTML to words. Everything is allocated in `arena`. Links found on the
/// way are added to `links`.
fn htmlWords(arena: std.mem.Allocator, html: []const u8, links: *std.ArrayList([]const u8)) ![]Word {
    var words: std.ArrayList(Word) = .empty;
    var current: std.ArrayList(u8) = .empty; // the word being collected
    var breaks: u8 = 0; // wanted before the next word
    var in_link = false; // inside an <a> that leads somewhere
    var i: usize = 0;
    while (i <= html.len) {
        const c: u8 = if (i < html.len) html[i] else ' '; // a space after the end flushes the last word
        if (c == '<') {
            // A comment ends at its -->, and not at a > inside it.
            if (std.mem.startsWith(u8, html[i..], "<!--")) {
                const end = std.mem.indexOfPos(u8, html, i + 4, "-->") orelse html.len;
                i = @min(end + 3, html.len);
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len;
            const inside = html[i + 1 .. close];
            i = @min(close + 1, html.len);
            // "p", "/p", "a href=...", "br/": the name, and whether it closes
            const closing = inside.len > 0 and inside[0] == '/';
            const named = if (closing) inside[1..] else inside;
            const tag = named[0 .. std.mem.indexOfAny(u8, named, " \t\r\n/") orelse named.len];
            // What is inside <script> and <style> is not HTML and not for
            // reading: a < in there starts no tag. Only the matching
            // closing tag ends it.
            inline for (.{ "script", "style" }) |raw| {
                if (!closing and tagIs(tag, &.{raw})) {
                    const end = std.ascii.indexOfIgnoreCasePos(html, i, "</" ++ raw) orelse html.len;
                    const after = std.mem.indexOfScalarPos(u8, html, end, '>') orelse html.len;
                    i = @min(after + 1, html.len);
                }
            }
            const paragraph = tagIs(tag, &.{ "p", "h1", "h2", "h3", "h4", "ul", "ol", "table", "title", "pre", "hr" });
            const line = tagIs(tag, &.{ "br", "li", "div", "tr", "body", "html", "head" });
            if (paragraph or line) {
                // a block: the word so far is finished, and the next starts a new line
                if (current.items.len > 0) {
                    try words.append(arena, .{ .text = try current.toOwnedSlice(arena), .breaks = breaks });
                    breaks = 0;
                }
                breaks = @max(breaks, @as(u8, if (paragraph) 2 else 1));
                if (!closing and tagIs(tag, &.{"li"})) {
                    try words.append(arena, .{ .text = "*", .breaks = breaks });
                    breaks = 0;
                }
            } else if (tagIs(tag, &.{"a"})) {
                if (!closing) {
                    // remember where it leads, if it leads anywhere
                    if (attribute(inside, "href")) |href| {
                        try links.append(arena, href);
                        in_link = true;
                    }
                } else if (in_link) {
                    // the link's number sticks to its last word
                    try current.print(arena, "[{d}]", .{links.items.len});
                    in_link = false;
                }
            }
            continue;
        }
        i += 1;
        if (std.ascii.isWhitespace(c)) {
            // any run of whitespace only ends a word
            if (current.items.len > 0) {
                try words.append(arena, .{ .text = try current.toOwnedSlice(arena), .breaks = breaks });
                breaks = 0;
            }
            continue;
        }
        if (c == '&') {
            // an entity, if there is a ; soon and we know the name
            const semi = std.mem.indexOfScalarPos(u8, html, i, ';') orelse html.len;
            if (semi < html.len and semi - i <= 8) {
                if (entity(html[i..semi])) |char| {
                    try current.append(arena, char);
                    i = ???;
                    continue;
                }
            }
        }
        try current.append(arena, c);
    }
    return words.items;
}

/// Puts words on lines of at most `width` characters. (A word longer
/// than that gets a line of its own.) The caller frees the text.
fn wrapWords(alloc: std.mem.Allocator, words: []const Word, width: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var line_len: usize = 0;
    for (words) |word| {
        if (out.items.len == 0) {
            // the first word: no breaks before it
        } else if (word.breaks > 0) {
            try out.appendNTimes(alloc, '\n', word.breaks);
            line_len = 0;
        } else if (???) {
            // it doesn't fit after a space: it starts the next line
            try out.append(alloc, '\n');
            line_len = 0;
        } else {
            try out.append(alloc, ' ');
            line_len += 1;
        }
        try out.appendSlice(alloc, word.text);
        line_len += word.text.len;
    }
    return out.toOwnedSlice(alloc);
}

/// A page as a text browser shows it. The caller frees it.
fn renderHtml(alloc: std.mem.Allocator, html: []const u8, width: usize) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var links: std.ArrayList([]const u8) = .empty;
    const words = try htmlWords(arena.allocator(), html, &links);
    const text = try wrapWords(arena.allocator(), words, width);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(text);
    try out.writer.writeAll("\n");
    for (links.items, 1..) |href, n| {
        try out.writer.print("{s}[{d}] {s}\n", .{ if (n == 1) "\n" else "", n, href });
    }
    return out.toOwnedSlice();
}

const ta = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

test "URLs" {
    const full = try parseUrl("http://10.0.0.2:8080/docs/index.html");
    try expectEqualStrings("10.0.0.2", full.host);
    try expectEqual(@as(u16, 8080), full.port);
    try expectEqualStrings("/docs/index.html", full.path);
    const bare = try parseUrl("http://example.com");
    try expectEqualStrings("example.com", bare.host);
    try expectEqual(@as(u16, 80), bare.port);
    try expectEqualStrings("/", bare.path);
    try expectEqualStrings("/", (try parseUrl("http://example.com/")).path);
    try expectEqualStrings("/a:b/c", (try parseUrl("http://h/a:b/c")).path); // a colon in the path is no port
    try expectEqual(@as(u16, 80), (try parseUrl("http://h/a:b/c")).port);
    try expectEqualStrings("/", (try parseUrl("http://h:81")).path);
    try expectError(error.NotHttp, parseUrl("gopher://example.com/"));
    try expectError(error.BadPort, parseUrl("http://example.com:http/"));
    try expectError(error.NoHost, parseUrl("http://:80/"));
}

test "the request and the response" {
    const request = try httpRequest(ta, try parseUrl("http://10.0.0.2/docs/a.html"));
    defer ta.free(request);
    try expectEqualStrings("GET /docs/a.html HTTP/1.0\r\nHost: 10.0.0.2\r\n\r\n", request);

    const ok = try httpParse("HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nX-Odd: a\r\n\r\n<p>hi</p>\r\n\r\nmore");
    try expectEqual(@as(u16, 200), ok.status);
    try expectEqualStrings("<p>hi</p>\r\n\r\nmore", ok.body);
    const missing = try httpParse("HTTP/1.1 404 Not Found\r\n\r\n");
    try expectEqual(@as(u16, 404), missing.status);
    try expectEqualStrings("", missing.body);
    try expectError(error.BadResponse, httpParse("HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n"));
    try expectError(error.BadResponse, httpParse("SSH-2.0-OpenSSH\r\n\r\n"));
    try expectError(error.BadResponse, httpParse("HTTP/1.0 fine\r\n\r\n"));
    try expectError(error.BadResponse, httpParse(""));
}

test "entities" {
    try expectEqual(@as(?u8, '&'), entity("amp"));
    try expectEqual(@as(?u8, '<'), entity("lt"));
    try expectEqual(@as(?u8, 'A'), entity("#65"));
    try expectEqual(@as(?u8, '~'), entity("#126"));
    try expectEqual(@as(?u8, null), entity("#999"));
    try expectEqual(@as(?u8, null), entity("#"));
    try expectEqual(@as(?u8, null), entity("copy"));
    try expectEqual(@as(?u8, ' '), entity("#10"));
    try expectEqual(@as(?u8, ' '), entity("#0"));
    try expectEqual(@as(?u8, ' '), entity("#32"));
    try expectEqual(@as(?u8, '!'), entity("#33"));
}

fn expectRendered(want: []const u8, html: []const u8, width: usize) !void {
    const got = try renderHtml(ta, html, width);
    defer ta.free(got);
    try expectEqualStrings(want, got);
}

test "tags go, words stay" {
    try expectRendered("Hello, world!\n", "<html><body>Hello, <b>world</b>!</body></html>", 40);
    try expectRendered("one two three\n", "  one\n\n   two\t<i>three</i>  \n", 40);
    try expectRendered("glued together, not apart\n", "gl<b>ue</b>d together, <span class=\"x\">not</span> apart", 40);
    try expectRendered("a < b && c > d \"e\" AT&T &unknown; 5 &\n", "a &lt; b &amp;&amp; c &gt; d &quot;e&quot; AT&amp;T &unknown; 5 &", 60);
    try expectRendered("before after\n", "before <script>if (a < b) { alert('<p>no</p>'); }</script><style>p { color: red }</style> after", 40);
    try expectRendered("x y\n", "x<!-- a comment --> y", 40);
    try expectRendered("x y\n", "x<!-- a > b, <p>and -> tags</p> --> y", 40);
    try expectRendered("x\n", "x <!-- never closed <p>", 40);
    // a < in a script starts no tag, whatever follows it
    try expectRendered("before after\n", "before <script>if (a < b) x();</script>after", 40);
    try expectRendered("before after\n", "before <SCRIPT type=\"text/javascript\">for (i = 0; i < n; i++) s += \"</p>\";</Script\n> after", 40);
    try expectRendered("a b c\n", "a <style>p > a { color: red }</style> b <script>1 < 2</script> c", 40);
    try expectRendered("before\n", "before <script>never closed <p>", 40);
    try expectRendered("one line\n", "one&#10;line", 40);
}

test "blocks" {
    try expectRendered("Title\n\nFirst paragraph.\n\nSecond one.\n", "<h1>Title</h1><p>First paragraph.</p><p>Second\none.</p>", 40);
    try expectRendered("line one\nline two\n", "line one<br>line two", 40);
    try expectRendered("Shopping:\n\n* milk\n* two eggs\n\nThanks\n", "Shopping:<ul><li>milk</li><li>two eggs</li></ul>Thanks", 40);
    try expectRendered("a\n\nb\n", "<P>a</P>\n\n<BR>\n<P>b</P>", 40); // capitals too, and breaks don't pile up
}

test "wrapping" {
    const text = "The quick brown fox jumps over the lazy dog.";
    try expectRendered("The quick brown fox jumps over the lazy dog.\n", text, 44);
    try expectRendered("The quick brown fox jumps over the lazy\ndog.\n", text, 43);
    try expectRendered("The quick\nbrown fox\njumps over\nthe lazy\ndog.\n", text, 10);
    try expectRendered("The\nquick\nbrown\nfox\njumps\nover\nthe\nlazy\ndog.\n", text, 5);
    try expectRendered("a\nsupercalifragilistic\nb c\n", "a supercalifragilistic b c", 6);
    try expectRendered("12345 7\n", "12345 7", 7); // exactly fits
}

test "links" {
    try expectRendered(
        \\See the manual[1] or go home[2].
        \\
        \\[1] /docs/manual.html
        \\[2] http://10.0.0.2/
        \\
    , "See <a href=\"/docs/manual.html\">the manual</a> or <a class=\"nav\" href=\"http://10.0.0.2/\">go home</a>.", 60);
    // an <a> without href is a place, not a link: it gets no number
    try expectRendered(
        \\one[1] two three[2] four[3] five
        \\
        \\[1] /x
        \\[2] /it"s
        \\[3] /bare
        \\
    , "<a href=\"/x\">one</a> <a name=\"top\">two</a> <A HREF='/it\"s'>three</A> <a href=/bare class=k>four</a> <a data-href=\"/no\">five</a>", 60);
}

const home_page =
    \\<html><head><title>zigrad</title>
    \\<style>body { font-family: serif }</style></head>
    \\<body>
    \\<h1>It works!</h1>
    \\<p>This page came out of a web server, through a TCP connection
    \\and across a wire that loses packets, &amp; arrived whole.</p>
    \\<ul><li>from the <a href="/transistor.html">transistor</a>
    \\<li>to the <a href="/browser.html">web browser</a></ul>
    \\</body></html>
    \\
;

/// Fetches `url` from a server that knows one page, over the wire.
fn browse(wire: *Wire, url: []const u8, width: usize) ![]u8 {
    const target = try parseUrl(url);
    var client: TcpConn = .{ .alloc = ta, .local_ip = ipAddr(10, 0, 0, 1), .local_port = 51000, .iss = 42 };
    defer client.deinit();
    var server: TcpConn = .{ .alloc = ta, .local_ip = ipAddr(10, 0, 0, 2), .local_port = 80, .iss = 9000 };
    defer server.deinit();
    server.listen();
    try client.connect(server.local_ip, target.port);
    const request = try httpRequest(ta, target);
    defer ta.free(request);
    try client.send(request);
    var answered = false;
    var rounds: usize = 0;
    while (!client.peer_closed) : (rounds += 1) {
        if (rounds == 3000) return error.TooSlow;
        try wire.round(&client, &server);
        // the server: once a whole request is in, answer it and hang up
        if (!answered and std.mem.endsWith(u8, server.received.items, "\r\n\r\n")) {
            answered = true;
            if (std.mem.startsWith(u8, server.received.items, "GET / HTTP/1.0\r\nHost: 10.0.0.2\r\n")) {
                try server.send("HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n\r\n" ++ home_page);
            } else {
                try server.send("HTTP/1.0 404 Not Found\r\nContent-Type: text/html\r\n\r\n<h1>404</h1><p>No such page.</p>");
            }
            try server.close();
        }
    }
    const response = try httpParse(client.received.items);
    if (response.status != 200) {
        std.debug.assert(response.status == 404);
        const page = try renderHtml(ta, response.body, width);
        defer ta.free(page);
        return std.fmt.allocPrint(ta, "({d}) {s}", .{ response.status, page });
    }
    return renderHtml(ta, response.body, width);
}

test "from the transistor to the web browser" {
    var prng = std.Random.DefaultPrng.init(245);
    var wire: Wire = .{ .rand = prng.random(), .lose = 25, .damage = 10, .duplicate = 15, .reverse = 25 };
    const page = try browse(&wire, "http://10.0.0.2/", 40);
    defer ta.free(page);
    try expectEqualStrings(
        \\zigrad
        \\
        \\It works!
        \\
        \\This page came out of a web server,
        \\through a TCP connection and across a
        \\wire that loses packets, & arrived
        \\whole.
        \\
        \\* from the transistor[1]
        \\* to the web browser[2]
        \\
        \\[1] /transistor.html
        \\[2] /browser.html
        \\
    , page);
    const lost = try browse(&wire, "http://10.0.0.2/nothing.html", 40);
    defer ta.free(lost);
    try expectEqualStrings("(404) 404\n\nNo such page.\n", lost);
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
    /// The oldest sequence number of ours that hasn't been acknowledged.
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
                c.sent = 0;
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
        const count: usize = ack -% c.snd_una; // how many sequence numbers it covers
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
        if (seg.seq == c.rcv_nxt) {
            try c.received.appendSlice(c.alloc, seg.payload);
            c.rcv_nxt +%= @intCast(seg.payload.len);
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
                c.rcv_nxt = seg.seq +% 1;
                c.snd_una = c.iss;
                c.state = .syn_received;
                try c.emit(.{ .syn = true, .ack = true }, c.iss, "");
            },
            .syn_sent => {
                // the answer must acknowledge OUR SYN
                if (!seg.flags.syn or !seg.flags.ack or seg.ack != c.iss +% 1) return;
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
