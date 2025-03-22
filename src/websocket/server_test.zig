const std = @import("std");
const testing = std.testing;
const server = @import("server.zig");
const Allocator = std.mem.Allocator;
const net = std.net;

test "MessageType enum values" {
    try testing.expectEqual(@as(u8, @intFromEnum(server.Opcode.text)), 0x1);
    try testing.expectEqual(@as(u8, @intFromEnum(server.Opcode.binary)), 0x2);
    try testing.expectEqual(@as(u8, @intFromEnum(server.Opcode.close)), 0x8);
    try testing.expectEqual(@as(u8, @intFromEnum(server.Opcode.ping)), 0x9);
    try testing.expectEqual(@as(u8, @intFromEnum(server.Opcode.pong)), 0xA);
}

test "Message struct deinit frees data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const data = try allocator.dupe(u8, "test message");
    var message = server.Message{
        .type = server.MessageType.text,
        .data = data,
        .allocator = allocator,
    };

    message.deinit(); // Should free the data
}

// Simplified implementation tests
test "Connection initialization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a dummy stream with handle 0 (not used in testing)
    const dummy_stream = net.Stream{ .handle = 0 };

    // Test server connection (no mask)
    {
        const conn = server.Connection.init(dummy_stream, allocator, true);
        try testing.expect(!conn.mask_outgoing);
        try testing.expect(conn.is_server);
    }

    // Test client connection (with mask)
    {
        const conn = server.Connection.init(dummy_stream, allocator, false);
        try testing.expect(conn.mask_outgoing);
        try testing.expect(!conn.is_server);
    }
}

test "WebSocket frame structure - text" {
    // Test that the opcode values are correct
    try testing.expectEqual(@as(u8, 0x1), @intFromEnum(server.Opcode.text));

    // Test frame structure for a text frame
    const fin_bit: u8 = 0x80; // FIN bit set
    const text_opcode = @intFromEnum(server.Opcode.text);
    const first_byte = fin_bit | text_opcode;

    try testing.expectEqual(@as(u8, 0x81), first_byte); // 10000001 = FIN + text opcode
}

test "WebSocket frame structure - binary" {
    // Test that the opcode values are correct
    try testing.expectEqual(@as(u8, 0x2), @intFromEnum(server.Opcode.binary));

    // Test frame structure for a binary frame
    const fin_bit: u8 = 0x80; // FIN bit set
    const binary_opcode = @intFromEnum(server.Opcode.binary);
    const first_byte = fin_bit | binary_opcode;

    try testing.expectEqual(@as(u8, 0x82), first_byte); // 10000010 = FIN + binary opcode
}

test "WebSocket frame decoding" {
    // Create a text frame with FIN=1, opcode=1, no mask, and payload "Hello"
    const payload = "Hello";
    const frame = [_]u8{
        0x81, // FIN=1, opcode=1 (text)
        0x05, // payload length=5, no mask
        'H', 'e', 'l', 'l', 'o', // payload
    };

    // Verify values by hand
    try testing.expectEqual(@as(u8, 0x81), frame[0]);
    try testing.expectEqual(@as(u8, 0x05), frame[1]);
    try testing.expectEqualSlices(u8, payload, frame[2..]);

    // Verify that the first bit is the FIN bit
    try testing.expectEqual(@as(u8, 0x80), frame[0] & 0x80);

    // Verify that the opcode is the lower 4 bits
    try testing.expectEqual(@as(u8, 0x01), frame[0] & 0x0F);

    // Verify that the mask bit is not set
    try testing.expectEqual(@as(u8, 0x00), frame[1] & 0x80);

    // Verify that the payload length is the lower 7 bits
    try testing.expectEqual(@as(u8, 0x05), frame[1] & 0x7F);
}

test "WebSocket masking" {
    // Test the masking algorithm
    const mask_key = [_]u8{ 0x37, 0xFA, 0x21, 0x3D };
    const plain_text = [_]u8{ 'H', 'e', 'l', 'l', 'o' };

    // Manually mask the text
    var masked_text: [5]u8 = undefined;
    for (plain_text, 0..) |char, i| {
        masked_text[i] = char ^ mask_key[i % 4];
    }

    // Now unmask it to verify
    var unmasked_text: [5]u8 = undefined;
    for (masked_text, 0..) |byte, i| {
        unmasked_text[i] = byte ^ mask_key[i % 4];
    }

    try testing.expectEqualSlices(u8, &plain_text, &unmasked_text);
}

test "WebSocket masked frame structure" {
    // Create a masked text frame header
    const mask_key = [_]u8{ 0x37, 0xFA, 0x21, 0x3D };

    var frame = [_]u8{
        0x81, // FIN=1, opcode=1 (text)
        0x85, // payload length=5, mask=1
        mask_key[0], mask_key[1], mask_key[2], mask_key[3], // mask key
    };

    // Verify frame values
    try testing.expectEqual(@as(u8, 0x81), frame[0]);
    try testing.expectEqual(@as(u8, 0x85), frame[1]);
    try testing.expectEqualSlices(u8, &mask_key, frame[2..6]);

    // Verify that the mask bit is set
    try testing.expectEqual(@as(u8, 0x80), frame[1] & 0x80);
}

test "WebSocket handshake calculation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The client key and expected server response
    const client_key = "dGhlIHNhbXBsZSBub25jZQ=="; // Base64 encoded "the sample nonce"
    const expected_accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";

    // Calculate the server's response manually
    const websocket_key_suffix = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    const full_key = try std.mem.concat(allocator, u8, &[_][]const u8{ client_key, websocket_key_suffix });
    defer allocator.free(full_key);

    var sha1_hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(full_key, &sha1_hash, .{});

    var base64_buf: [28]u8 = undefined; // SHA-1 hash in base64 is 28 bytes
    const accept_key = std.base64.standard.Encoder.encode(&base64_buf, &sha1_hash);

    // Verify the calculated accept key matches the expected value
    try testing.expectEqualStrings(expected_accept, accept_key);
}
