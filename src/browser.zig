const std = @import("std");
const print = std.debug.print;
const uri = std.Uri;

pub fn process(u: []u8) void {
    const url = uri.parse(u) catch |err| {
        print("URL seems incorrect, err:{}\n", .{err});
        return;
    };

    print("Processed URL:\nScheme:{s}\tHost:{}\n", .{ url.scheme, url.host.? });
}
