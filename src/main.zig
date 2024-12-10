const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const heap = std.heap;
const io = std.io;
const browser = @import("browser.zig");

const maxRedirects: u8 = 5;

pub fn main() void {
    const stdin = io.getStdIn().reader();
    const stdout = io.getStdOut().writer();
    var buffer: [1024]u8 = undefined;
    var bufferReadLen: usize = 0;

    print("Welcome to Zrome v0.0.1\n\nEnter URL to get started:\n", .{});
    while (true) {
        stdout.print("> ", .{}) catch |err| {
            print("Unable to write to std out, err:{}\n", .{err});
            break;
        };

        const result = stdin.readUntilDelimiter(&buffer, '\n') catch |err| {
            if (err == error.StreamTooLong) {
                print("The URL you entered is too long, try something shorter :)\n", .{});
                break;
            }

            print("There was an error trying to read your input, err:{}\n", .{err});
            return;
        };

        bufferReadLen = result.len;
        if (bufferReadLen == 0) {
            continue;
        }
        break;
    }

    stdout.print("Connecting to: {s}", .{buffer}) catch |err| {
        print("Unable to write to std out, err:{}\n", .{err});
        return;
    };

    assert(bufferReadLen > 0);

    var gpa = heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer if (gpa.deinit() == .leak) {
        print("Memory leak", .{});
    };

    var t = browser.Tab.init(buffer[0..bufferReadLen], allocator) catch |err| {
        print("There was a problem with the URL: {}\n", .{err});
        return;
    };
    defer t.deinit(allocator);

    var rawRes = t.process(allocator) catch |err| {
        print("There was an error making that request: {}\n", .{err});
        return;
    };

    if (std.mem.eql(u8, t.scheme, "file")) {
        print("{s}\n", .{rawRes});
        allocator.free(rawRes);
        return;
    }

    if (std.mem.eql(u8, t.scheme, "data")) {
        print("{s}\n", .{rawRes});
        allocator.free(rawRes);
        return;
    }

    var res = browser.Response.parseResponse(rawRes, allocator) catch |err| {
        print("There was an error parsing that response: {}\n", .{err});
        return;
    };
    defer res.free(allocator);

    if (res.statusCode >= 300 and res.statusCode < 400) {
        var redirectCount: u8 = 0;
        var isRedirectStatus = true;
        while (isRedirectStatus and redirectCount < maxRedirects) {
            redirectCount += 1;
            const location = res.getHeader("Location") catch {
                print("Redirect request is missing location header\n", .{});
                return;
            };

            if (location[0] == '/') {
                rawRes = t.redirect(location) catch |err| {
                    print("Redirect req failed: {}\n", .{err});
                    return;
                };
            } else {
                const redirectURI = std.Uri.parse(location) catch |err| {
                    print("Redirect URI is invalid. Err:{}\n", .{err});
                    return;
                };

                if (redirectURI.host) |redirectHost| {
                    if (std.mem.eql(u8, redirectHost.percent_encoded, t.host)) {
                        rawRes = t.redirect(redirectURI.path.percent_encoded) catch |err| {
                            print("Redirect req failed: {}\n", .{err});
                            return;
                        };
                    }
                }
                // Todo: otherwise get new t ??
            }

            res.free(allocator);
            res = browser.Response.parseResponse(rawRes, allocator) catch |err| {
                print("Unable to parse redirect response: {}\n", .{err});
                return;
            };
            print("Status {d}\n", .{res.statusCode});
            isRedirectStatus = res.statusCode >= 300 and res.statusCode < 400;
        }

        if (redirectCount >= maxRedirects) {
            print("Max redirect loop of {d} reached", .{maxRedirects});
        }
    }

    if (t.viewSource) {
        print("{s}\n", .{res.body});
        return;
    }

    const html = browser.renderHTML(res.body);
    print("{s}\n", .{html});

    return;
}
