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

pub fn drawWindow(text: []const u8) !void {
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
    var position: rl.Vector2 = undefined;

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        position = rl.Vector2.init(xStart, yStart);
        rl.clearBackground(rl.Color.white);

        var wordStartIdx: usize = 0;
        var wordEndIdx: usize = 0;
        var buffer: [100]u8 = undefined;
        var finalWordPrinted: bool = false;
        for (text, 0..) |char, i| {
            if (finalWordPrinted) {
                break;
            }

            switch (char) {
                ' ' => {
                    wordStartIdx = wordEndIdx;
                    wordEndIdx = i + 1;
                },
                '\n' => {
                    // print everything upto this point
                    wordStartIdx = wordEndIdx;
                    wordEndIdx = i;
                    // Todo: add line break
                    const word = text[wordStartIdx..wordEndIdx];
                    @memcpy(buffer[0..word.len], word);
                    buffer[word.len] = 0;

                    const updatedX = @as(f32, rl.measureTextEx(font, @ptrCast(&buffer[0]), fontsize, spacing).x);
                    if ((updatedX + position.x) > xMax) {
                        // wrap word
                        position.y += @as(f32, yStart + fontsize + linespacing);
                        position.x = xStart;
                    }
                    drawWord(@ptrCast(&buffer[0]), font, position);
                    position.x = xStart;
                    position.y += yStart + linespacing + fontsize;
                },
                else => {
                    if (i + 1 == text.len) {
                        wordStartIdx = wordEndIdx;
                        wordEndIdx = i + 1;

                        const word = text[wordStartIdx..wordEndIdx];
                        @memcpy(buffer[0..word.len], word);
                        buffer[word.len] = 0;
                        drawWord(@ptrCast(&buffer[0]), font, position);

                        finalWordPrinted = true;
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
            drawWord(@ptrCast(&buffer[0]), font, position);
            position.x += updatedX;
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
