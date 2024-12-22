const std = @import("std");
const rl = @import("raylib");
const browser = @import("browser.zig");
const unicode = std.unicode;
const utf8View = unicode.Utf8View;
const assert = std.debug.assert;
const mem = std.mem;

const bodyBufferSize: u32 = 10 << 20;

pub fn drawWindow(text: []u8) !void {
    const screenWidth = 800;
    const screenHeight = 600;

    const uv = try utf8View.init(text);
    var utfIterator = uv.iterator();

    rl.initWindow(screenWidth, screenHeight, browser.userAgent);
    defer rl.closeWindow();

    const font = rl.loadFont("resources/font/mono.ttf");
    defer font.unload();
    const fontSize: f32 = 12;

    assert(font.baseSize > 0);

    rl.setTargetFPS(60);
    const position = rl.Vector2.init(screenWidth / 2, screenHeight / 2);

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.white);

        while (utfIterator.nextCodepoint()) |codepoint| {
            rl.drawTextCodepoint(font, @as(i32, @intCast(codepoint)), position, fontSize, rl.Color.black);
        }
    }
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

    buf[bufIdx] = 0;
    bufIdx += 1;

    return buf[0..bufIdx];
}
