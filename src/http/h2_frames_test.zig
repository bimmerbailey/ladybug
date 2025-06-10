const std = @import("std");
const testing = std.testing;
const h2_frames = @import("h2_frames.zig");

test "FrameHeader parse and serialize" {
    const test_data = [_]u8{ 0x00, 0x00, 0x0C, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const header = try h2_frames.FrameHeader.parse(&test_data);

    try testing.expect(header.length == 12);
    try testing.expect(header.frame_type == h2_frames.FrameType.SETTINGS);
    try testing.expect(header.flags == 0);
    try testing.expect(header.stream_id == 0);

    var buffer: [9]u8 = undefined;
    try header.serialize(&buffer);
    try testing.expectEqualSlices(u8, &test_data, &buffer);
}

test "SettingsFrame parse and serialize" {
    const allocator = testing.allocator;

    const test_payload = [_]u8{ 0x00, 0x03, 0x00, 0x00, 0x00, 0x64, 0x00, 0x04, 0x00, 0x00, 0x40, 0x00 };
    var settings_frame = try h2_frames.SettingsFrame.parse(allocator, &test_payload);
    defer settings_frame.deinit();

    try testing.expect(settings_frame.settings.items.len == 2);
    try testing.expect(settings_frame.settings.items[0].id == h2_frames.SettingsId.MAX_CONCURRENT_STREAMS);
    try testing.expect(settings_frame.settings.items[0].value == 100);
    try testing.expect(settings_frame.settings.items[1].id == h2_frames.SettingsId.INITIAL_WINDOW_SIZE);
    try testing.expect(settings_frame.settings.items[1].value == 16384);

    const serialized = try settings_frame.serialize(allocator);
    defer allocator.free(serialized);
    try testing.expectEqualSlices(u8, &test_payload, serialized);
}

test "DataFrame with padding" {
    const allocator = testing.allocator;

    const payload = [_]u8{ 0x05, 'H', 'e', 'l', 'l', 'o', 0x00, 0x00, 0x00, 0x00, 0x00 };
    const frame = h2_frames.Frame{
        .header = h2_frames.FrameHeader{
            .length = @intCast(payload.len),
            .frame_type = h2_frames.FrameType.DATA,
            .flags = h2_frames.FrameFlags.PADDED,
            .stream_id = 1,
        },
        .payload = &payload,
    };

    var data_frame = try h2_frames.DataFrame.parse(allocator, frame);
    defer data_frame.deinit(allocator);

    try testing.expectEqualSlices(u8, "Hello", data_frame.data);
    try testing.expect(data_frame.pad_length.? == 5);
}
