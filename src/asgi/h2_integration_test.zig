const std = @import("std");
const testing = std.testing;
const h2_integration = @import("h2_integration.zig");
const h2_frames = @import("../http/h2_frames.zig");
const protocol = @import("protocol.zig");

var test_allocator = std.testing.allocator;

test "Http2AsgiHandler initialization" {
    var handler = try h2_integration.Http2AsgiHandler.init(test_allocator, 65536);
    defer handler.deinit();

    // Basic initialization checks
    try testing.expect(handler.stream_manager.initial_window_size == 65536);
    try testing.expect(handler.stream_manager.max_concurrent_streams == 100);
}

test "Http2PseudoHeaders validation" {
    // Test valid pseudo-headers
    const valid_headers = [_][2][]const u8{
        .{ ":method", "GET" },
        .{ ":scheme", "https" },
        .{ ":path", "/test" },
        .{ ":authority", "example.com" },
        .{ "host", "example.com" },
    };

    const pseudo = protocol.Http2PseudoHeaders.fromHeaders(&valid_headers);
    try testing.expect(pseudo.isValid());
    try testing.expectEqualStrings("GET", pseudo.method.?);
    try testing.expectEqualStrings("https", pseudo.scheme.?);
    try testing.expectEqualStrings("/test", pseudo.path.?);
    try testing.expectEqualStrings("example.com", pseudo.authority.?);

    // Test invalid pseudo-headers (missing required fields)
    const invalid_headers = [_][2][]const u8{
        .{ ":method", "GET" },
        .{ "host", "example.com" },
        // Missing :scheme and :path
    };

    const invalid_pseudo = protocol.Http2PseudoHeaders.fromHeaders(&invalid_headers);
    try testing.expect(!invalid_pseudo.isValid());
}

test "createHttp2Scope" {
    const server_addr = "127.0.0.1";
    const server_port: u16 = 8080;
    const client_addr = "192.168.1.10";
    const client_port: u16 = 54321;
    const method = "POST";
    const path = "/api/data";
    const query = "format=json";
    const stream_id: u31 = 3;
    const scheme = "https";
    const authority = "api.example.com";

    const headers = [_][2][]const u8{
        .{ "content-type", "application/json" },
        .{ "authorization", "Bearer token123" },
    };

    const scope = try protocol.createHttp2Scope(
        test_allocator,
        server_addr,
        server_port,
        client_addr,
        client_port,
        method,
        path,
        query,
        &headers,
        stream_id,
        scheme,
        authority,
    );

    // Check basic fields
    try testing.expectEqualStrings("http", scope.object.get("type").?.string);
    try testing.expectEqualStrings("2.0", scope.object.get("http_version").?.string);
    try testing.expectEqualStrings("POST", scope.object.get("method").?.string);
    try testing.expectEqualStrings("https", scope.object.get("scheme").?.string);
    try testing.expectEqualStrings("/api/data", scope.object.get("path").?.string);
    try testing.expectEqualStrings("format=json", scope.object.get("query_string").?.string);
    try testing.expectEqualStrings("api.example.com", scope.object.get("authority").?.string);

    // Check stream ID
    try testing.expectEqual(@as(i64, 3), scope.object.get("stream_id").?.integer);

    // Check ASGI version
    const asgi = scope.object.get("asgi").?;
    try testing.expectEqualStrings("3.0", asgi.object.get("version").?.string);
    try testing.expectEqualStrings("2.0", asgi.object.get("spec_version").?.string);

    // Check headers
    const header_list = scope.object.get("headers").?;
    try testing.expectEqual(@as(usize, 2), header_list.array.items.len);
    try testing.expectEqualStrings("content-type", header_list.array.items[0].array.items[0].string);
    try testing.expectEqualStrings("application/json", header_list.array.items[0].array.items[1].string);

    // Check client and server
    const client = scope.object.get("client").?;
    try testing.expectEqualStrings("192.168.1.10", client.array.items[0].string);
    try testing.expectEqual(@as(f64, 54321), client.array.items[1].float);

    const server = scope.object.get("server").?;
    try testing.expectEqualStrings("127.0.0.1", server.array.items[0].string);
    try testing.expectEqual(@as(f64, 8080), server.array.items[1].float);
}

test "Http2StreamMessageQueue basic operations" {
    var queue = protocol.Http2StreamMessageQueue.init(test_allocator);
    defer queue.deinit();

    const stream_id: u31 = 5;

    // Create a stream queue
    try queue.createStreamQueue(stream_id);

    // Create a test message
    const message = try protocol.createHttpRequestMessage(test_allocator, "test body", false);

    // Push message to stream
    try queue.pushToStream(stream_id, message);

    // Create a thread to receive the message (to avoid blocking)
    const Context = struct {
        queue: *protocol.Http2StreamMessageQueue,
        stream_id: u31,
        received_message: ?std.json.Value = null,

        fn receiveMessage(self: *@This()) void {
            self.received_message = self.queue.receiveFromStream(self.stream_id) catch null;
        }
    };

    var context = Context{
        .queue = &queue,
        .stream_id = stream_id,
    };

    // Simulate receiving the message
    context.receiveMessage();

    // Verify the message was received
    try testing.expect(context.received_message != null);
    const received = context.received_message.?;
    try testing.expectEqualStrings("http.request", received.object.get("type").?.string);
    try testing.expectEqualStrings("test body", received.object.get("body").?.string);
    try testing.expectEqual(false, received.object.get("more_body").?.bool);

    // Clean up
    protocol.jsonValueDeinit(received, test_allocator);

    // Remove the stream queue
    queue.removeStreamQueue(stream_id);
}

test "SETTINGS frame processing" {
    var handler = try h2_integration.Http2AsgiHandler.init(test_allocator, 65536);
    defer handler.deinit();

    // Create a SETTINGS frame
    var settings_frame = h2_frames.SettingsFrame.init(test_allocator);
    defer settings_frame.deinit();

    try settings_frame.addSetting(.INITIAL_WINDOW_SIZE, 32768);
    try settings_frame.addSetting(.MAX_CONCURRENT_STREAMS, 50);

    const payload = try settings_frame.serialize(test_allocator);
    defer test_allocator.free(payload);

    const frame = h2_frames.Frame{
        .header = h2_frames.FrameHeader{
            .length = @intCast(payload.len),
            .frame_type = .SETTINGS,
            .flags = 0,
            .stream_id = 0,
        },
        .payload = payload,
    };

    // Process the frame
    try handler.processFrame(frame);

    // Verify settings were applied
    try testing.expectEqual(@as(i32, 32768), handler.stream_manager.initial_window_size);
    try testing.expectEqual(@as(u32, 50), handler.stream_manager.max_concurrent_streams);
}
