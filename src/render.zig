const std = @import("std");
const rl = @import("raylib");
const browser = @import("browser.zig");
const unicode = std.unicode;
const utf8View = unicode.Utf8View;
const assert = std.debug.assert;
const mem = std.mem;

const bodyBufferSize: u32 = 10 << 20;
const screenWidth = 1200;
const xStart = 10;
const xMax = screenWidth - 10;
const yStart = 10;
const screenHeight = 800;
const linespacing = 1;
const spacing = 1;
const fontsize = 13;

const wordPosition = struct {
    word: []const u8,
    x: f32,
    y: f32,
};

fn populateWordPositions(allocator: mem.Allocator, text: []const u8, font: rl.Font, wps: []wordPosition) !void {
    var position = rl.Vector2.init(xStart, yStart);
    var wordStartIdx: usize = 0;
    var wordEndIdx: usize = 0;
    var buffer: [128]u8 = undefined;
    for (text, 0..) |char, i| {
        switch (char) {
            ' ' => {
                wordStartIdx = wordEndIdx;
                wordEndIdx = i + 1;
            },
            // Todo: handle other forms of spaces
            // example: \t
            '\n' => {
                // print everything upto this point
                wordStartIdx = wordEndIdx;
                wordEndIdx = i;
                const word = text[wordStartIdx..wordEndIdx];
                @memcpy(buffer[0..word.len], word);
                buffer[word.len] = 0;

                const updatedX = @as(f32, rl.measureTextEx(font, @ptrCast(&buffer[0]), fontsize, spacing).x);
                if ((updatedX + position.x) > xMax) {
                    // wrap word
                    position.y += @as(f32, yStart + fontsize + linespacing);
                    position.x = xStart;
                }
                const wordCopy = try allocator.dupe(u8, buffer[0 .. word.len + 1]);
                wps[i] = wordPosition{
                    .word = wordCopy,
                    .x = position.x,
                    .y = position.y,
                };
                position.x = xStart;
                position.y += yStart + linespacing + fontsize;

                continue;
            },
            else => {
                if (i + 1 == text.len) {
                    wordStartIdx = wordEndIdx;
                    wordEndIdx = i + 1;

                    const word = text[wordStartIdx..wordEndIdx];
                    @memcpy(buffer[0..word.len], word);
                    buffer[word.len] = 0;
                    const wordCopy = try allocator.dupe(u8, buffer[0 .. word.len + 1]);
                    wps[i] = wordPosition{
                        .word = wordCopy,
                        .x = position.x,
                        .y = position.y,
                    };

                    break;
                }

                continue;
            },
        }

        const word = text[wordStartIdx..wordEndIdx];
        @memcpy(buffer[0..word.len], word);
        buffer[word.len] = 0;

        const updatedX = @as(f32, rl.measureTextEx(font, @ptrCast(&buffer[0]), fontsize, spacing).x);
        if ((updatedX + position.x) > xMax) {
            // wrap word
            position.y += @as(f32, yStart + fontsize + linespacing);
            position.x = xStart;
        }
        const wordCopy = try allocator.dupe(u8, buffer[0 .. word.len + 1]);
        wps[i] = wordPosition{
            .word = wordCopy,
            .x = position.x,
            .y = position.y,
        };
        position.x += updatedX;
    }
}

pub fn drawWindow(allocator: mem.Allocator, text: []const u8) !void {
    rl.initWindow(screenWidth, screenHeight, browser.userAgent);
    defer rl.closeWindow();

    // Todo: remove duplicate codepoint to keep the font atlas small
    const codepoints = try rl.loadCodepoints(@ptrCast(text.ptr));
    defer rl.unloadCodepoints(codepoints);

    const font = rl.loadFontEx("resources/font/mono.ttf", fontsize, codepoints);
    defer font.unload();

    rl.setTextureFilter(font.texture, rl.TextureFilter.texture_filter_bilinear);
    rl.setTextLineSpacing(linespacing);

    assert(font.baseSize > 0);

    rl.setTargetFPS(60);

    var wps: [8192]wordPosition = undefined;
    defer {
        for (wps) |wp| {
            allocator.free(wp.word);
        }
    }
    // Todo: fix this
    try populateWordPositions(allocator, text, font, &wps);

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        var position = rl.Vector2.init(xStart, yStart);
        rl.clearBackground(rl.Color.white);

        for (wps) |wp| {
            // Todo: fix this
            std.debug.print("{s}:{d}:{d}\n", .{ wp.word, wp.x, wp.y });
            position.x = wp.x;
            position.y = wp.y;
            drawWord(@ptrCast(wp.word), font, position);
        }
    }
}

fn drawWord(word: [*:0]const u8, font: rl.Font, position: rl.Vector2) void {
    rl.drawTextEx(font, word, position, fontsize, linespacing, rl.Color.gray);
}

// currently there is no rendering, it's super simple, as it just
// returns the content without the tags
pub fn parseHTML(body: []const u8) []u8 {
    assert(bodyBufferSize >= body.len);

    var buf: [bodyBufferSize]u8 = undefined;
    var bufIdx: usize = 0;
    var i: usize = 0;
    var inTag: bool = false;

    while (i < body.len) : (i += 1) {
        switch (body[i]) {
            '>' => inTag = false,
            '<' => inTag = true,
            '&' => {
                if (inTag) continue;

                var entity: ?u8 = null;
                if (body[i + 1] == 'l' and body[i + 2] == 't' and body[i + 3] == ';') {
                    entity = '<';
                } else if (body[i + 1] == 'g' and body[i + 2] == 't' and body[i + 3] == ';') {
                    entity = '>';
                }

                if (entity) |e| {
                    buf[bufIdx] = e;
                    bufIdx += 1;

                    i += 3;
                    continue;
                }

                buf[bufIdx] = body[i];
                bufIdx += 1;
            },
            else => {
                if (!inTag) {
                    buf[bufIdx] = body[i];
                    bufIdx += 1;
                }
            },
        }
    }

    // raylib expects null terminated string
    buf[bufIdx] = 0;
    bufIdx += 1;

    return buf[0..bufIdx];
}
