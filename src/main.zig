const std = @import("std");
const print = std.debug.print;
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

    stdout.print("Fetching: {s}", .{buffer}) catch |err| {
        print("Unable to write to std out, err:{}\n", .{err});
        return;
    };

    browser.process(buffer[0..bufferReadLen]);
}
