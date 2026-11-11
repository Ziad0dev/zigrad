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
    const path = if (slash < rest.len) ⟪rest[slash..]|||???⟫ else "/";
    const colon = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
    const port: u16 = if (colon < authority.len) std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.BadPort else ⟪80|||???⟫;
    if (colon == 0) return error.NoHost;
    return .{ .host = authority[0..colon], .port = port, .path = path };
}

/// What the browser sends. The caller frees it.
fn httpRequest(alloc: std.mem.Allocator, url: Url) ![]u8 {
    return std.fmt.allocPrint(alloc, ⟪"GET {s} HTTP/1.0\r\nHost: {s}\r\n\r\n"|||???⟫, .{ url.path, url.host });
}

const HttpResponse = struct { status: u16, body: []const u8 };

/// Splits what the server sent. The body points into `bytes`.
fn httpParse(bytes: []const u8) !HttpResponse {
    // "HTTP/1.0 200 OK": the status is the second word of the first line
    var words = std.mem.tokenizeScalar(u8, bytes[0 .. std.mem.indexOf(u8, bytes, "\r\n") orelse return error.BadResponse], ' ');
    if (!std.mem.startsWith(u8, words.next() orelse return error.BadResponse, "HTTP/")) return error.BadResponse;
    const status = std.fmt.parseInt(u16, words.next() orelse return error.BadResponse, 10) catch return error.BadResponse;
    // the body starts after the first EMPTY line
    const blank = std.mem.indexOf(u8, bytes, ⟪"\r\n\r\n"|||???⟫) orelse return error.BadResponse;
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
        const number = std.fmt.parseInt(u8, ⟪name[1..]|||???⟫, 10) catch return null;
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
                    i = ⟪semi + 1|||???⟫;
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
        } else if (⟪line_len + 1 + word.text.len > width|||???⟫) {
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

//@include tcpip
//@include tcp
//@include tcp_wire
