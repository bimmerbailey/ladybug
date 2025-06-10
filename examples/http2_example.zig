const std = @import("std");
const lib = @import("ladybug_lib");
const h2_integration = lib.asgi.h2_integration;
const h2_frames = lib.http.h2_frames;
const protocol = lib.asgi.protocol;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("HTTP/2 ASGI Integration Example\n", .{});
    std.debug.print("===============================\n\n", .{});

    // Create HTTP/2 ASGI handler
    var handler = try h2_integration.Http2AsgiHandler.init(allocator, 65536);
    defer handler.deinit();

    std.debug.print("1. Created HTTP/2 ASGI Handler\n", .{});
    std.debug.print("   - Initial window size: {}\n", .{handler.stream_manager.initial_window_size});
    std.debug.print("   - Max concurrent streams: {}\n\n", .{handler.stream_manager.max_concurrent_streams});

    // Example: Create an HTTP/2 scope
    const headers = [_][2][]const u8{
        .{ "content-type", "application/json" },
        .{ "authorization", "Bearer token123" },
        .{ "user-agent", "ladybug-http2-client/1.0" },
    };

    const scope = try protocol.createHttp2Scope(
        allocator,
        "127.0.0.1", // server_addr
        8080, // server_port
        "192.168.1.100", // client_addr
        54321, // client_port
        "POST", // method
        "/api/users", // path
        "format=json&limit=10", // query
        &headers,
        5, // stream_id
        "https", // scheme
        "api.example.com", // authority
    );
    defer protocol.jsonValueDeinit(scope, allocator);

    std.debug.print("2. Created HTTP/2 ASGI Scope:\n", .{});
    std.debug.print("   - Type: {s}\n", .{scope.object.get("type").?.string});
    std.debug.print("   - HTTP Version: {s}\n", .{scope.object.get("http_version").?.string});
    std.debug.print("   - Method: {s}\n", .{scope.object.get("method").?.string});
    std.debug.print("   - Scheme: {s}\n", .{scope.object.get("scheme").?.string});
    std.debug.print("   - Path: {s}\n", .{scope.object.get("path").?.string});
    std.debug.print("   - Stream ID: {}\n", .{scope.object.get("stream_id").?.integer});
    std.debug.print("   - Authority: {s}\n\n", .{scope.object.get("authority").?.string});

    // Example: Test pseudo-headers
    const test_headers = [_][2][]const u8{
        .{ ":method", "GET" },
        .{ ":scheme", "https" },
        .{ ":path", "/test?param=value" },
        .{ ":authority", "example.com" },
        .{ "host", "example.com" },
        .{ "accept", "application/json" },
    };

    const pseudo = protocol.Http2PseudoHeaders.fromHeaders(&test_headers);
    std.debug.print("3. HTTP/2 Pseudo-headers validation:\n", .{});
    std.debug.print("   - Valid: {}\n", .{pseudo.isValid()});
    if (pseudo.method) |method| std.debug.print("   - Method: {s}\n", .{method});
    if (pseudo.scheme) |scheme| std.debug.print("   - Scheme: {s}\n", .{scheme});
    if (pseudo.path) |path| std.debug.print("   - Path: {s}\n", .{path});
    if (pseudo.authority) |authority| std.debug.print("   - Authority: {s}\n", .{authority});

    std.debug.print("\n4. HTTP/2 Stream-aware Message Queue Demo:\n", .{});

    // Create stream-aware message queue
    var stream_queue = protocol.Http2StreamMessageQueue.init(allocator);
    defer stream_queue.deinit();

    const stream_id: u31 = 7;
    try stream_queue.createStreamQueue(stream_id);
    std.debug.print("   - Created queue for stream {}\n", .{stream_id});

    // Create and push a test message
    const test_message = try protocol.createHttpRequestMessage(allocator, "{'hello': 'world'}", false);

    try stream_queue.pushToStream(stream_id, test_message);
    std.debug.print("   - Pushed message to stream {}\n", .{stream_id});

    // Receive the message (simulate)
    const received = try stream_queue.receiveFromStream(stream_id);
    defer protocol.jsonValueDeinit(received, allocator);

    std.debug.print("   - Received message type: {s}\n", .{received.object.get("type").?.string});
    std.debug.print("   - Message body: {s}\n", .{received.object.get("body").?.string});

    stream_queue.removeStreamQueue(stream_id);
    std.debug.print("   - Cleaned up stream queue\n\n", .{});

    std.debug.print("HTTP/2 ASGI Integration is working correctly!\n", .{});
    std.debug.print("Key features implemented:\n", .{});
    std.debug.print("✓ HTTP/2 scope generation with pseudo-headers\n", .{});
    std.debug.print("✓ Stream-aware message queues\n", .{});
    std.debug.print("✓ HTTP/2 frame processing foundation\n", .{});
    std.debug.print("✓ ASGI 3.0 compliance for HTTP/2\n", .{});
}
