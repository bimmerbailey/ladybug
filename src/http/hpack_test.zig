const std = @import("std");
const testing = std.testing;
const hpack = @import("hpack.zig");

test "Static table lookup" {
    const allocator = testing.allocator;

    var decoder = hpack.HpackDecoder.init(allocator, 4096);
    defer decoder.deinit();

    const header = try decoder.getHeaderField(2);
    defer allocator.free(header.name);
    defer allocator.free(header.value);

    try testing.expectEqualStrings(":method", header.name);
    try testing.expectEqualStrings("GET", header.value);
}

test "Dynamic table operations" {
    const allocator = testing.allocator;

    var table = hpack.DynamicTable.init(allocator, 1000);
    defer table.deinit();

    try table.add("custom-header", "value1");
    try table.add("another-header", "value2");

    const first = table.get(0).?;
    try testing.expectEqualStrings("another-header", first.name);
    try testing.expectEqualStrings("value2", first.value);

    const second = table.get(1).?;
    try testing.expectEqualStrings("custom-header", second.name);
    try testing.expectEqualStrings("value1", second.value);
}

test "Integer encoding/decoding" {
    const allocator = testing.allocator;

    var encoder = hpack.HpackEncoder.init(allocator, 4096);
    defer encoder.deinit();

    var decoder = hpack.HpackDecoder.init(allocator, 4096);
    defer decoder.deinit();

    var encoded = std.ArrayList(u8).init(allocator);
    defer encoded.deinit();

    try encoder.encodeInteger(&encoded, 1337, 5, 0);

    var pos: usize = 0;
    const decoded = try decoder.decodeInteger(encoded.items, &pos, 5);

    try testing.expect(decoded == 1337);
}

test "Basic header encoding/decoding" {
    const allocator = testing.allocator;

    var encoder = hpack.HpackEncoder.init(allocator, 4096);
    defer encoder.deinit();

    var decoder = hpack.HpackDecoder.init(allocator, 4096);
    defer decoder.deinit();

    const headers = [_]hpack.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/test" },
    };

    const encoded = try encoder.encode(&headers);
    defer allocator.free(encoded);

    var decoded_headers = try decoder.decode(encoded);
    defer {
        for (decoded_headers.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        decoded_headers.deinit();
    }

    try testing.expect(decoded_headers.items.len == 2);
    try testing.expectEqualStrings(":method", decoded_headers.items[0].name);
    try testing.expectEqualStrings("GET", decoded_headers.items[0].value);
}
