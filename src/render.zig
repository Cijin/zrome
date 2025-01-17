const std = @import("std");
const rl = @import("raylib");
const browser = @import("browser.zig");
const unicode = std.unicode;
const utf8View = unicode.Utf8View;
const assert = std.debug.assert;
const mem = std.mem;

const bodyBufferSize: u32 = 10 << 20;
const screenWidth = 1200;
const screenHeight = 800;
const linespacing = 1;
const spacing = 1;
const fontsize = 13;
const xStart = 10;
const xOffset = 40;
const xMax = screenWidth - xOffset;
const yStart = 10;
const yOffset = 10;
const yMax = screenHeight - yOffset;
const scrollbarWidth = xOffset / 4;

const wordPosition = struct {
    word: []const u8,
    x: f32,
    y: f32,
};

fn populateWordPositions(allocator: mem.Allocator, text: []const u8, font: rl.Font, wps: []wordPosition) !usize {
    var position = rl.Vector2.init(xStart, yStart);
    var wordStartIdx: usize = 0;
    var wpsIdx: usize = 0;
    var wordEndIdx: usize = 0;
    var buffer: [8192]u8 = undefined;

    // Todo: this can be done better
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
                    // line wrap
                    position.y += @as(f32, yStart + fontsize + linespacing);
                    position.x = xStart;
                }
                const wordCopy = try allocator.dupe(u8, buffer[0 .. word.len + 1]);
                wps[wpsIdx] = wordPosition{
                    .word = wordCopy,
                    .x = position.x,
                    .y = position.y,
                };
                wpsIdx += 1;
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
                    wps[wpsIdx] = wordPosition{
                        .word = wordCopy,
                        .x = position.x,
                        .y = position.y,
                    };
                    wpsIdx += 1;

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
        wps[wpsIdx] = wordPosition{
            .word = wordCopy,
            .x = position.x,
            .y = position.y,
        };
        wpsIdx += 1;
        position.x += updatedX;
    }

    return wpsIdx;
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
    const totalWords = try populateWordPositions(allocator, text, font, &wps);
    defer {
        for (wps[0..totalWords]) |wp| {
            allocator.free(wp.word);
        }
    }

    var scroll: f32 = 0;
    var scrollbarHeight: f32 = 0;
    var mouseWheelMove: f32 = 0;
    const pageScrollDistance = 50;
    const maxPageY = wps[totalWords - 1].y;
    const viewScrollBar = maxPageY > yMax;

    if (viewScrollBar) {
        scrollbarHeight = yMax * (yMax / maxPageY);
    }

    const scrollbarScrollDistance: i32 = @intFromFloat((yMax - scrollbarHeight) * (pageScrollDistance / (maxPageY - yMax)));
    const scrollbarHeightInt: i32 = @intFromFloat(scrollbarHeight);
    var scrollbarScroll: i32 = yStart;

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        if (viewScrollBar) {
            mouseWheelMove = rl.getMouseWheelMove();
            if (mouseWheelMove != 0) {
                // + mouse wheel move means mouse whell moved up
                // i.e. page should scroll bottom to top (up)
                if (mouseWheelMove > 0 and scroll >= 50) {
                    scroll -= pageScrollDistance;
                    scrollbarScroll -= scrollbarScrollDistance;

                    // bit hacky, if the math is right I shouldn't need this
                    if (scrollbarScroll < yStart) {
                        scrollbarScroll = yStart;
                    }
                } else if (mouseWheelMove < 0 and (maxPageY - scroll > yMax)) {
                    scroll += pageScrollDistance;
                    scrollbarScroll += scrollbarScrollDistance;

                    // bit hacky, if the math is right I shouldn't need this
                    if (scrollbarScroll + scrollbarHeightInt > yMax) {
                        scrollbarScroll = yMax - scrollbarHeightInt;
                    }
                }
            }
        }

        var position = rl.Vector2.init(xStart, yStart);
        rl.clearBackground(rl.Color.white);

        for (wps[0..totalWords]) |wp| {
            position.x = wp.x;
            position.y = wp.y - scroll;
            drawWord(@ptrCast(wp.word), font, position);
        }

        rl.drawRectangle(xMax + xOffset / 2, scrollbarScroll, scrollbarWidth, @intFromFloat(scrollbarHeight), rl.Color.sky_blue);
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
