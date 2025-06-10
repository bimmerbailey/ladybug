const std = @import("std");
const mem = std.mem;
const testing = std.testing;

pub const StreamState = enum {
    idle,
    reserved_local,
    reserved_remote,
    open,
    half_closed_local,
    half_closed_remote,
    closed,
};

pub const Stream = struct {
    id: u31,
    state: StreamState,
    window_size: i32,
    headers_complete: bool,
    priority: Priority,
    dependencies: std.ArrayList(u31),
    allocator: mem.Allocator,

    const Priority = struct {
        depends_on: u31,
        weight: u8,
        exclusive: bool,

        pub fn init() Priority {
            return Priority{
                .depends_on = 0,
                .weight = 16,
                .exclusive = false,
            };
        }
    };

    pub fn init(allocator: mem.Allocator, id: u31, initial_window_size: i32) !*Stream {
        const stream = try allocator.create(Stream);
        stream.* = Stream{
            .id = id,
            .state = if (id == 0) StreamState.idle else StreamState.open,
            .window_size = initial_window_size,
            .headers_complete = false,
            .priority = Priority.init(),
            .dependencies = std.ArrayList(u31).init(allocator),
            .allocator = allocator,
        };
        return stream;
    }

    pub fn deinit(self: *Stream) void {
        self.dependencies.deinit();
        self.allocator.destroy(self);
    }

    pub fn canSendData(self: *const Stream) bool {
        return switch (self.state) {
            .open, .half_closed_remote => true,
            else => false,
        };
    }

    pub fn canReceiveData(self: *const Stream) bool {
        return switch (self.state) {
            .open, .half_closed_local => true,
            else => false,
        };
    }

    pub fn updateWindow(self: *Stream, increment: i32) !void {
        const new_size = self.window_size + increment;
        if (new_size > std.math.maxInt(i31)) {
            return error.FlowControlError;
        }
        self.window_size = new_size;
    }

    pub fn transitionState(self: *Stream, event: StateEvent) !void {
        const new_state = switch (self.state) {
            .idle => switch (event) {
                .send_headers, .recv_headers => StreamState.open,
                .send_push_promise => StreamState.reserved_local,
                .recv_push_promise => StreamState.reserved_remote,
                else => return error.InvalidTransition,
            },
            .reserved_local => switch (event) {
                .send_headers => StreamState.half_closed_remote,
                .recv_rst_stream, .send_rst_stream => StreamState.closed,
                else => return error.InvalidTransition,
            },
            .reserved_remote => switch (event) {
                .recv_headers => StreamState.half_closed_local,
                .recv_rst_stream, .send_rst_stream => StreamState.closed,
                else => return error.InvalidTransition,
            },
            .open => switch (event) {
                .send_end_stream => StreamState.half_closed_local,
                .recv_end_stream => StreamState.half_closed_remote,
                .recv_rst_stream, .send_rst_stream => StreamState.closed,
                else => self.state,
            },
            .half_closed_local => switch (event) {
                .recv_end_stream => StreamState.closed,
                .recv_rst_stream, .send_rst_stream => StreamState.closed,
                else => return error.InvalidTransition,
            },
            .half_closed_remote => switch (event) {
                .send_end_stream => StreamState.closed,
                .recv_rst_stream, .send_rst_stream => StreamState.closed,
                else => return error.InvalidTransition,
            },
            .closed => switch (event) {
                .recv_rst_stream, .send_rst_stream => StreamState.closed,
                else => return error.InvalidTransition,
            },
        };

        self.state = new_state;
    }

    pub fn setPriority(self: *Stream, depends_on: u31, weight: u8, exclusive: bool) !void {
        if (depends_on == self.id) return error.InvalidDependency;

        self.priority.depends_on = depends_on;
        self.priority.weight = weight;
        self.priority.exclusive = exclusive;
    }
};

pub const StateEvent = enum {
    send_headers,
    recv_headers,
    send_end_stream,
    recv_end_stream,
    send_push_promise,
    recv_push_promise,
    send_rst_stream,
    recv_rst_stream,
};

pub const StreamManager = struct {
    streams: std.HashMap(u31, *Stream, std.hash_map.AutoContext(u31), std.hash_map.default_max_load_percentage),
    next_stream_id: u31,
    max_concurrent_streams: u32,
    initial_window_size: i32,
    connection_window_size: i32,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator, initial_window_size: i32) StreamManager {
        return StreamManager{
            .streams = std.HashMap(u31, *Stream, std.hash_map.AutoContext(u31), std.hash_map.default_max_load_percentage).init(allocator),
            .next_stream_id = 2, // Server-initiated streams are even
            .max_concurrent_streams = 100,
            .initial_window_size = initial_window_size,
            .connection_window_size = initial_window_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StreamManager) void {
        var iterator = self.streams.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.streams.deinit();
    }

    pub fn createStream(self: *StreamManager, stream_id: u31) !*Stream {
        if (self.streams.get(stream_id) != null) {
            return error.StreamAlreadyExists;
        }

        if (self.getOpenStreamCount() >= self.max_concurrent_streams) {
            return error.TooManyStreams;
        }

        const stream = try Stream.init(self.allocator, stream_id, self.initial_window_size);
        try self.streams.put(stream_id, stream);
        return stream;
    }

    pub fn getStream(self: *StreamManager, stream_id: u31) ?*Stream {
        return self.streams.get(stream_id);
    }

    pub fn removeStream(self: *StreamManager, stream_id: u31) void {
        if (self.streams.fetchRemove(stream_id)) |kv| {
            kv.value.deinit();
        }
    }

    pub fn getNextStreamId(self: *StreamManager) u31 {
        const id = self.next_stream_id;
        self.next_stream_id += 2;
        return id;
    }

    pub fn getOpenStreamCount(self: *const StreamManager) u32 {
        var count: u32 = 0;
        var iterator = self.streams.iterator();
        while (iterator.next()) |entry| {
            const stream = entry.value_ptr.*;
            if (stream.state == .open or stream.state == .half_closed_local or stream.state == .half_closed_remote) {
                count += 1;
            }
        }
        return count;
    }

    pub fn updateConnectionWindow(self: *StreamManager, increment: i32) !void {
        const new_size = self.connection_window_size + increment;
        if (new_size > std.math.maxInt(i31)) {
            return error.FlowControlError;
        }
        self.connection_window_size = new_size;
    }

    pub fn updateAllStreamWindows(self: *StreamManager, increment: i32) !void {
        var iterator = self.streams.iterator();
        while (iterator.next()) |entry| {
            const stream = entry.value_ptr.*;
            try stream.updateWindow(increment);
        }
    }

    pub fn canSend(self: *const StreamManager, stream_id: u31, data_size: u32) bool {
        const stream = self.streams.get(stream_id) orelse return false;

        if (!stream.canSendData()) return false;
        if (stream.window_size < data_size) return false;
        if (self.connection_window_size < data_size) return false;

        return true;
    }

    pub fn consumeWindow(self: *StreamManager, stream_id: u31, data_size: u32) !void {
        const stream = self.streams.get(stream_id) orelse return error.StreamNotFound;

        if (stream.window_size < data_size or self.connection_window_size < data_size) {
            return error.FlowControlError;
        }

        stream.window_size -= @intCast(data_size);
        self.connection_window_size -= @intCast(data_size);
    }

    pub fn setPriority(self: *StreamManager, stream_id: u31, depends_on: u31, weight: u8, exclusive: bool) !void {
        const stream = self.streams.get(stream_id) orelse return error.StreamNotFound;
        try stream.setPriority(depends_on, weight, exclusive);

        if (exclusive) {
            // Move all streams that depend on the target to depend on this stream
            var iterator = self.streams.iterator();
            while (iterator.next()) |entry| {
                const other_stream = entry.value_ptr.*;
                if (other_stream.id != stream_id and other_stream.priority.depends_on == depends_on) {
                    other_stream.priority.depends_on = stream_id;
                }
            }
        }
    }

    pub fn closeExpiredStreams(self: *StreamManager) void {
        var streams_to_remove = std.ArrayList(u31).init(self.allocator);
        defer streams_to_remove.deinit();

        var iterator = self.streams.iterator();
        while (iterator.next()) |entry| {
            const stream = entry.value_ptr.*;
            if (stream.state == .closed) {
                streams_to_remove.append(stream.id) catch continue;
            }
        }

        for (streams_to_remove.items) |stream_id| {
            self.removeStream(stream_id);
        }
    }
};

pub const ConnectionSettings = struct {
    header_table_size: u32 = 4096,
    enable_push: bool = true,
    max_concurrent_streams: u32 = 100,
    initial_window_size: u32 = 65535,
    max_frame_size: u32 = 16384,
    max_header_list_size: ?u32 = null,

    pub fn updateSetting(self: *ConnectionSettings, id: u16, value: u32) !void {
        switch (id) {
            1 => self.header_table_size = value,
            2 => self.enable_push = value != 0,
            3 => self.max_concurrent_streams = value,
            4 => {
                if (value > std.math.maxInt(i31)) return error.FlowControlError;
                self.initial_window_size = value;
            },
            5 => {
                if (value < 16384 or value > 16777215) return error.FrameSizeError;
                self.max_frame_size = value;
            },
            6 => self.max_header_list_size = value,
            else => {}, // Unknown settings are ignored
        }
    }
};

test "Stream state transitions" {
    const allocator = testing.allocator;

    var stream = try Stream.init(allocator, 1, 65535);
    defer stream.deinit();

    try testing.expect(stream.state == .open);

    try stream.transitionState(.send_end_stream);
    try testing.expect(stream.state == .half_closed_local);

    try stream.transitionState(.recv_end_stream);
    try testing.expect(stream.state == .closed);
}

test "StreamManager basic operations" {
    const allocator = testing.allocator;

    var manager = StreamManager.init(allocator, 65535);
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

    var manager = StreamManager.init(allocator, 1000);
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

    var manager = StreamManager.init(allocator, 65535);
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
