const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const net = std.net;
const uri = std.Uri;
const http = std.http;
const crypto = std.crypto;

const httpVer = "HTTP/1.1";
const userAgent = "Zrome-0.0.1";

const defaultHeaders = [_][2][]const u8{
    .{ "User-Agent", userAgent },
    .{ "Connection", "close" },
};

const responseError = error{
    MissingProtocol,
    MissingStatusInfo,
    InvalidStatusCode,
    MissingStatusMsg,
    InvalidHeaderValue,
};

const fileError = error{
    PathNotAbsolute,
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

fn isNetworkScheme(scheme: []const u8) bool {
    return (mem.eql(u8, scheme, "https")) or (mem.eql(u8, scheme, "http"));
}

const noHostError = error{
    NoHost,
    NullHost,
};

const schemeError = error{
    UnsupporterScheme,
};

pub const Tab = struct {
    rawURL: []u8,
    scheme: []const u8,
    host: []const u8,
    path: []const u8,
    port: u16,
    secure: bool,
    viewSource: bool,
    stream: ?net.Stream,
    bundle: ?crypto.Certificate.Bundle,

    pub fn init(u: []u8, allocator: mem.Allocator) !Tab {
        // Todo: handle url like: localhost:8080
        const parsedURI = try uri.parse(u);

        if (isNetworkScheme(parsedURI.scheme)) {
            if (parsedURI.host) |host| {
                if (host.isEmpty()) {
                    return error.NoHost;
                }

                var port: u16 = undefined;
                var secure: bool = false;
                var viewSource: bool = false;
                var bundle: crypto.Certificate.Bundle = undefined;
                if (mem.eql(u8, parsedURI.scheme, "http")) {
                    port = 80;
                } else if (mem.eql(u8, parsedURI.scheme, "https")) {
                    port = 443;
                    secure = true;
                } else if (mem.eql(u8, parsedURI.scheme, "view-source")) {
                    viewSource = true;
                    // Todo: get scheme, host port etc
                } else unreachable;

                const s = try net.tcpConnectToHost(allocator, host.percent_encoded, port);
                if (secure) {
                    bundle = crypto.Certificate.Bundle{};
                    try bundle.rescan(allocator);
                }

                return Tab{ .rawURL = u, .scheme = parsedURI.scheme, .port = port, .host = host.percent_encoded, .path = parsedURI.path.percent_encoded, .stream = s, .secure = secure, .bundle = bundle, .viewSource = viewSource };
            }

            return error.NullHost;
        }

        if (mem.eql(u8, parsedURI.scheme, "file")) {
            return Tab{ .rawURL = u, .scheme = parsedURI.scheme, .port = 0, .host = "", .path = parsedURI.path.percent_encoded, .stream = null, .secure = false, .bundle = null, .viewSource = false };
        }

        if (mem.eql(u8, parsedURI.scheme, "data")) {
            return Tab{ .rawURL = u, .scheme = parsedURI.scheme, .port = 0, .host = "", .path = parsedURI.path.percent_encoded, .stream = null, .secure = false, .bundle = null, .viewSource = false };
        }

        return error.UnsupportedScheme;
    }

    pub fn deinit(self: *Tab, allocator: mem.Allocator) void {
        if (self.stream) |stream| {
            stream.close();
        }

        if (self.secure) {
            self.bundle.?.deinit(allocator);
        }
        return;
    }

    pub fn process(self: *Tab, allocator: mem.Allocator) ![]u8 {
        if (mem.eql(u8, self.scheme, "file")) {
            if (!fs.path.isAbsolute(self.path)) {
                return fileError.PathNotAbsolute;
            }

            var dir = fs.openDirAbsolute(self.path, .{ .access_sub_paths = false, .iterate = true, .no_follow = true }) catch |err| {
                if (err != error.NotDir) {
                    return err;
                }

                var file = try fs.openFileAbsolute(self.path, .{ .mode = fs.File.OpenMode.read_only, .lock = fs.File.Lock.none });
                defer file.close();

                var buf: [8192]u8 = undefined;
                const bytesRead = try file.readAll(&buf);

                return try allocator.dupe(u8, buf[0..bytesRead]);
            };
            defer dir.close();
            var dirIter = dir.iterate();

            var buf: [1024]u8 = undefined;
            var contentLength: usize = 0;
            while (try dirIter.next()) |entry| {
                if (entry.kind == fs.File.Kind.file) {
                    const written = try fmt.bufPrint(buf[contentLength..], "{s}\n", .{entry.name});
                    contentLength += written.len;
                    continue;
                }
                const writtenDir = try fmt.bufPrint(buf[contentLength..], "{s}/\n", .{entry.name});
                contentLength += writtenDir.len;
            }

            return try allocator.dupe(u8, buf[0..contentLength]);
        }

        if (mem.eql(u8, self.scheme, "data")) {
            var dataIter = mem.splitScalar(u8, self.path, ',');
            if (mem.eql(u8, dataIter.first(), "text/html")) {
                return allocator.dupe(u8, renderHTML(dataIter.rest()));
            }

            dataIter.reset();
            return allocator.dupe(u8, dataIter.rest());
        }

        return self.request();
    }

    fn request(self: *Tab) ![]u8 {
        assert(self.stream != null);
        assert(self.bundle != null);

        var reqBuf: [4096]u8 = undefined;
        var reqStream = io.fixedBufferStream(&reqBuf);
        var reqWriter = reqStream.writer();

        reqWriter.print("{s} {s} {s}\r\nHost: {s}\r\n", .{ @tagName(http.Method.GET), self.path, httpVer, self.host }) catch unreachable;
        for (defaultHeaders) |header| {
            // Todo: expand buffer if out of space
            // catch the error and expand buf
            // Not sure how to do this, but can look it up when needed
            try reqWriter.print("{s}: {s}\r\n", .{ header[0], header[1] });
        }
        try reqWriter.writeAll("\r\n");

        const req = reqStream.getWritten();
        var resBuf: [8192]u8 = undefined;
        var bytesRead: usize = 0;
        if (self.stream) |stream| {
            if (self.secure) {
                var tlsConn = try crypto.tls.Client.init(stream, self.bundle.?, self.host);
                _ = try tlsConn.write(stream, req);
                bytesRead = try tlsConn.readAll(stream, &resBuf);
            } else {
                _ = try stream.write(req);
                bytesRead = try stream.readAll(&resBuf);
            }
        } else unreachable;

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
