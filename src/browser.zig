const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const mem = std.mem;
const net = std.net;
const uri = std.Uri;

const noHostError = error{
    NoHost,
    NullHost,
};

const Url = struct {
    rawURL: []u8,
    scheme: []const u8,
    host: []const u8,

    fn init(u: []u8) !Url {
        const parsedURI = try uri.parse(u);

        if (parsedURI.host) |host| {
            if (host.isEmpty()) {
                return error.NoHost;
            }

            assert(host.percent_encoded.len != 0);
            return Url{ .rawURL = u, .scheme = parsedURI.scheme, .host = host.percent_encoded };
        }

        return error.NullHost;
    }

    fn request(self: Url, allocator: mem.Allocator) !void {
        const port: u16 = if (mem.eql(u8, self.scheme, "http")) {
            80;
        } else if (mem.eql(u8, self.scheme, "https")) {
            443;
        } else @panic("unsupported scheme for making tcp requests");

        var stream = try net.tcpConnectToHost(allocator, self.host, port);
    }
};

pub fn process(u: []u8) void {
    assert(u.len > 0);

    const url = Url.init(u) catch |err| {
        print("There was an error processing the URI:{}\n", .{err});
        return;
    };

    print("Processing {s} request for host:", .{url.scheme});
    print("'{s}'\n", .{url.host});
}
