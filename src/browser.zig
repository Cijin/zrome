const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const fmt = std.fmt;
const net = std.net;
const uri = std.Uri;
const http = std.http;
const StringHashMap = std.StringHashMap;

const noHostError = error{
    NoHost,
    NullHost,
};

const responseError = error{
    MissingProtocol,
    MissingStatusInfo,
    InvalidStatusCode,
    MissingStatusMsg,
    InvalidHeaderValue,
};

pub const Response = struct {
    status: []const u8,
    statusCode: u16,
    protocol: []const u8,
    headers: []const u8,
    body: []const u8,

    pub fn parseResponse(buffer: []u8, allocator: mem.Allocator) !*Response {
        var iter = mem.splitSequence(u8, buffer, "\r\n\r\n");
        var headIter = mem.splitSequence(u8, iter.first(), "\r\n");

        const statusLine = headIter.first();

        var statusIter = mem.splitScalar(u8, statusLine, ' ');
        const protocol = statusIter.first();
        if (protocol.len == 0) {
            return error.MissingProtocol;
        }

        const statusCodeBuf = statusIter.next();
        var status: []const u8 = undefined;
        var statusCode: u16 = undefined;
        if (statusCodeBuf) |s| {
            statusCode = try fmt.parseInt(u16, s, 10);
            if (statusCode <= 100 or statusCode > 600) {
                return error.InvalidStatusCode;
            }

            const statusMsg = statusIter.next();
            if (statusMsg) |msg| {
                var statusBuf: [256]u8 = undefined;
                status = try fmt.bufPrint(&statusBuf, "{d} {s}", .{ statusCode, msg });
            } else {
                return error.MissingStatusMsg;
            }
        } else {
            return error.MissingStatusInfo;
        }

        const res = try allocator.create(Response);
        res.* = Response{ .status = status, .statusCode = statusCode, .protocol = protocol, .headers = headIter.rest(), .body = try allocator.dupe(u8, iter.rest()) };
        return res;
    }

    pub fn free(self: *Response, allocator: mem.Allocator) void {
        allocator.free(self.body);
        allocator.destroy(self);
    }
};

pub const Tab = struct {
    rawURL: []u8,
    scheme: []const u8,
    host: []const u8,
    stream: net.Stream,

    pub fn init(u: []u8, allocator: mem.Allocator) !Tab {
        const parsedURI = try uri.parse(u);

        if (parsedURI.host) |host| {
            if (host.isEmpty()) {
                return error.NoHost;
            }

            assert(host.percent_encoded.len != 0);

            // might have to move it to request later on
            // as not all schemes need to initialize a stream
            // ex: file://
            var port: u16 = undefined;
            if (mem.eql(u8, parsedURI.scheme, "http")) {
                port = 80;
            } else if (mem.eql(u8, parsedURI.scheme, "https")) {
                port = 443;
            } else @panic("unsupported scheme for making tcp requests");

            const s = try net.tcpConnectToHost(allocator, host.percent_encoded, port);

            return Tab{ .rawURL = u, .scheme = parsedURI.scheme, .host = host.percent_encoded, .stream = s };
        }

        return error.NullHost;
    }

    pub fn deinit(self: Tab) void {
        self.stream.close();
        return;
    }

    pub fn request(self: Tab, path: []const u8) ![]u8 {
        var buf: [1024]u8 = undefined;
        const req = fmt.bufPrint(&buf, "{s} {s} HTTP/1.0\r\nHost: {s}\r\n\r\n", .{ @tagName(http.Method.GET), path, self.host }) catch unreachable;

        _ = try self.stream.write(req);

        var resBuf: [8192]u8 = undefined;
        const bytesRead = try self.stream.readAll(&resBuf);

        return resBuf[0..bytesRead];
    }
};

// currently there is no rendering, it's super simple, as it just
// returns the content without the tags
pub fn renderHTML(body: []const u8) []u8 {
    var buf: [8192]u8 = undefined;
    var bufIdx: usize = 0;
    var inTag: bool = false;

    for (body) |c| {
        switch (c) {
            '>' => inTag = false,
            '<' => inTag = true,
            else => {
                if (!inTag) {
                    buf[bufIdx] = c;
                    bufIdx += 1;
                }
            },
        }
    }
    return buf[0..bufIdx];
}
