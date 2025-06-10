const std = @import("std");
const testing = std.testing;
const h2_streams = @import("h2_streams.zig");

test "Stream state transitions" {
    const allocator = testing.allocator;

    var stream = try h2_streams.Stream.init(allocator, 1, 65535);
    defer stream.deinit();

    try testing.expect(stream.state == .open);

    try stream.transitionState(.send_end_stream);
    try testing.expect(stream.state == .half_closed_local);

    try stream.transitionState(.recv_end_stream);
    try testing.expect(stream.state == .closed);
}

test "StreamManager basic operations" {
    const allocator = testing.allocator;

    var manager = h2_streams.StreamManager.init(allocator, 65535);
    defer manager.deinit();

    const stream = try manager.createStream(1);
    try testing.expect(stream.id == 1);
    try testing.expect(manager.getOpenStreamCount() == 1);

    const retrieved = manager.getStream(1);
    try testing.expect(retrieved != null);
    try testing.expect(retrieved.?.id == 1);

    try testing.expect(manager.canSend(1, 1000) == true);
    try manager.consumeWindow(1, 1000);
    try testing.expect(stream.window_size == 64535);

    manager.removeStream(1);
    try testing.expect(manager.getStream(1) == null);
}

test "Flow control" {
    const allocator = testing.allocator;

    var manager = h2_streams.StreamManager.init(allocator, 1000);
    defer manager.deinit();

    const stream = try manager.createStream(1);

    try testing.expect(manager.canSend(1, 500) == true);
    try testing.expect(manager.canSend(1, 1500) == false);

    try manager.consumeWindow(1, 500);
    try testing.expect(stream.window_size == 500);
    try testing.expect(manager.connection_window_size == 500);

    try stream.updateWindow(200);
    try testing.expect(stream.window_size == 700);
}

test "Priority dependencies" {
    const allocator = testing.allocator;

    var manager = h2_streams.StreamManager.init(allocator, 65535);
    defer manager.deinit();

    _ = try manager.createStream(1);
    const stream3 = try manager.createStream(3);
    const stream5 = try manager.createStream(5);

    try manager.setPriority(3, 1, 10, false);
    try testing.expect(stream3.priority.depends_on == 1);
    try testing.expect(stream3.priority.weight == 10);

    try manager.setPriority(5, 1, 20, true);
    try testing.expect(stream5.priority.depends_on == 1);
    try testing.expect(stream5.priority.exclusive == true);
    try testing.expect(stream3.priority.depends_on == 5); // Should be updated due to exclusive
}
