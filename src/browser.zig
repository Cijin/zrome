const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const mem = std.mem;
const fmt = std.fmt;
const net = std.net;
const uri = std.Uri;
const http = std.http;

const noHostError = error{
    NoHost,
    NullHost,
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

    pub fn request(self: Tab, path: []const u8) !usize {
        var buf: [1024]u8 = undefined;
        const req = fmt.bufPrint(&buf, "{s} {s} HTTP/1.0\r\nHost: {s}\r\n\r\n", .{ @tagName(http.Method.GET), path, self.host }) catch unreachable;

        _ = try self.stream.write(req);

        @memset(buf, 0);
        while (true) {
            var bytesRead = try self.stream.read(&buf);
            if (bytesRead == 0) {
                break;
            }
        }
    }
};
