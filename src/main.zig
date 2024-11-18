const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const heap = std.heap;
const io = std.io;
const browser = @import("browser.zig");

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

    const res = t.request("/index.html") catch |err| {
        print("There was an error making that request: {}\n", .{err});
        return;
    };

    print("Written {s} bytes\n", .{res});
}
