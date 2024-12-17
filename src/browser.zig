const std = @import("std");
const render = @import("render.zig");
const assert = std.debug.assert;
const mem = std.mem;
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const net = std.net;
const uri = std.Uri;
const http = std.http;
const crypto = std.crypto;

pub const userAgent = "zrome-0.0.2";
const httpVer = "HTTP/1.1";
const bodyBufferSize: u32 = 10 << 20;

const defaultHeaders = [_][2][]const u8{
    .{ "User-Agent", userAgent },
    .{ "Connection", "keep-alive" },
};

const responseError = error{
    MissingProtocol,
    MissingStatusInfo,
    InvalidStatusCode,
    MissingStatusMsg,
    InvalidHeaderValue,
    HeaderNonExistent,
};

const fileError = error{
    PathNotAbsolute,
};

pub const Response = struct {
    status: []const u8,
    statusCode: u16,
    protocol: []const u8,
    headers: [][2][]const u8,
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

        var headers: [32][2][]const u8 = undefined;
        var contentLength: u32 = 0;
        var idx: usize = 0;
        while (headIter.next()) |line| {
            var headerLineIter = mem.splitSequence(u8, line, ": ");
            headers[idx][0] = headerLineIter.first();
            headers[idx][1] = headerLineIter.rest();

            if (mem.eql(u8, headers[idx][0], "Content-Length")) {
                contentLength = try fmt.parseInt(u32, headers[idx][1], 10);
            }

            idx += 1;
        }

        const body = iter.rest();
        const res = try allocator.create(Response);
        res.* = Response{ .status = status, .statusCode = statusCode, .protocol = protocol, .headers = headers[0..idx], .body = try allocator.dupe(u8, body[0..contentLength]) };
        return res;
    }

    pub fn getHeader(self: *Response, key: []const u8) responseError![]const u8 {
        for (self.headers) |header| {
            if (mem.eql(u8, header[0], key)) {
                return header[1];
            }
        }

        return responseError.HeaderNonExistent;
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
        var viewSource: bool = false;
        // Todo: handle url like: localhost:8080
        var parsedURI = try uri.parse(u);
        if (mem.eql(u8, parsedURI.scheme, "view-source")) {
            viewSource = true;
            var uriIter = mem.splitScalar(u8, u, ':');
            _ = uriIter.first();

            parsedURI = try uri.parse(uriIter.rest());
        }

        if (isNetworkScheme(parsedURI.scheme)) {
            if (parsedURI.host) |host| {
                if (host.isEmpty()) {
                    return error.NoHost;
                }

                var port: u16 = undefined;
                var secure: bool = false;
                var bundle: crypto.Certificate.Bundle = undefined;

                if (mem.eql(u8, parsedURI.scheme, "http")) {
                    port = 80;
                } else if (mem.eql(u8, parsedURI.scheme, "https")) {
                    port = 443;
                    secure = true;
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
                return allocator.dupe(u8, render.parseHTML(dataIter.rest()));
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

        // Todo: if path ends with a '/' request for '/index.html'?
        reqWriter.print("{s} {s} {s}\r\nHost: {s}\r\n", .{ @tagName(http.Method.GET), self.path, httpVer, self.host }) catch unreachable;
        for (defaultHeaders) |header| {
            // Todo: expand buffer if out of space
            // catch the error and expand buf
            // Not sure how to do this, but can look it up when needed
            try reqWriter.print("{s}: {s}\r\n", .{ header[0], header[1] });
        }
        try reqWriter.writeAll("\r\n");

        const req = reqStream.getWritten();
        var resBuf: [bodyBufferSize]u8 = undefined;
        if (self.stream) |stream| {
            if (self.secure) {
                var tlsConn = try crypto.tls.Client.init(stream, self.bundle.?, self.host);
                _ = try tlsConn.write(stream, req);
                _ = try tlsConn.read(stream, &resBuf);
            } else {
                _ = try stream.write(req);
                _ = try stream.read(&resBuf);
            }
        } else unreachable;

        return resBuf[0..];
    }

    // Todo: cache 200 GET requests
    // Todo: handle compression
    pub fn redirect(self: *Tab, path: []const u8) ![]u8 {
        self.path = path;
        return self.request();
    }
};
