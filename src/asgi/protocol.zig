const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

/// Helper function to clean up JSON values in Zig 0.14
pub fn jsonValueDeinit(value: json.Value, allocator: Allocator) void {
    switch (value) {
        // Don't try to free string values as they might be literals or
        // managed by other structures (just like the object keys)
        .string => {},
        .array => |*arr| {
            for (arr.items) |*item| {
                jsonValueDeinit(item.*, allocator);
            }
            arr.deinit();
        },
        .object => |obj| {
            var mutable_obj = obj;
            var it = mutable_obj.iterator();
            while (it.next()) |entry| {
                // The key might be owned by the object's internal storage,
                // not individually allocated, so we shouldn't free it directly
                // allocator.free(entry.key_ptr.*);
                jsonValueDeinit(entry.value_ptr.*, allocator);
            }
            mutable_obj.deinit();
        },
        else => {}, // No cleanup needed for other types
    }
}

/// ASGI specification version
pub const AsgiVersion = struct {
    version: []const u8 = "3.0",
    spec_version: []const u8 = "2.0",
};

// OPTIMIZATION 3: Concurrency - Replace mutex-based queue with lock-free alternatives
// OPTIMIZATION 8: Protocol-Specific - Implement message batching for better throughput
// UVICORN PARITY: Add message priority handling for different ASGI event types
// UVICORN PARITY: Add queue size limits and backpressure handling
/// ASGI Message Queue for communication with the application
pub const MessageQueue = struct {
    const Self = @This();
    allocator: Allocator,
    messages: std.ArrayList(json.Value),
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},

    /// Initialize a new message queue
    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .messages = std.ArrayList(json.Value).init(allocator),
        };
    }

    /// Push a message onto the queue
    pub fn push(self: *Self, message: json.Value) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.messages.append(message);
        self.condition.signal();
    }

    // OPTIMIZATION 3: Concurrency - Implement non-blocking receive with timeout
    /// Receive a message from the queue, blocking if none is available
    pub fn receive(self: *Self) !json.Value {
        std.debug.print("\nDEBUG: Receive message\n", .{});
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.print("DEBUG: Locked mutex\n", .{});

        while (self.messages.items.len == 0) {
            std.debug.print("DEBUG: Queue is empty, waiting for message...\n", .{});
            self.condition.wait(&self.mutex);
            std.debug.print("DEBUG: Woken up, checking for messages\n", .{});
        }

        const message = self.messages.orderedRemove(0);
        std.debug.print("DEBUG: Message received: {}\n", .{message});
        return message;
    }

    /// Free all resources associated with the queue
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // In Zig 0.14.0, json.Value doesn't have a deinit method
        // We can just deallocate the ArrayList itself
        self.messages.deinit();
    }
};

/// HTTP/2 Stream-aware Message Queue for per-stream communication
pub const Http2StreamMessageQueue = struct {
    const Self = @This();

    const StreamQueue = struct {
        messages: std.ArrayList(json.Value),
        condition: std.Thread.Condition = .{},
    };

    allocator: Allocator,
    stream_queues: std.HashMap(u31, StreamQueue, std.hash_map.AutoContext(u31), std.hash_map.default_max_load_percentage),
    global_mutex: std.Thread.Mutex = .{},

    /// Initialize a new HTTP/2 stream-aware message queue
    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .stream_queues = std.HashMap(u31, StreamQueue, std.hash_map.AutoContext(u31), std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    /// Create a queue for a specific stream
    pub fn createStreamQueue(self: *Self, stream_id: u31) !void {
        self.global_mutex.lock();
        defer self.global_mutex.unlock();

        if (self.stream_queues.contains(stream_id)) {
            return; // Queue already exists
        }

        const stream_queue = StreamQueue{
            .messages = std.ArrayList(json.Value).init(self.allocator),
        };

        try self.stream_queues.put(stream_id, stream_queue);
    }

    /// Push a message to a specific stream queue
    pub fn pushToStream(self: *Self, stream_id: u31, message: json.Value) !void {
        self.global_mutex.lock();
        defer self.global_mutex.unlock();

        var stream_queue = self.stream_queues.getPtr(stream_id) orelse {
            return error.StreamNotFound;
        };

        try stream_queue.messages.append(message);
        stream_queue.condition.signal();
    }

    /// Receive a message from a specific stream queue
    pub fn receiveFromStream(self: *Self, stream_id: u31) !json.Value {
        self.global_mutex.lock();
        defer self.global_mutex.unlock();

        var stream_queue = self.stream_queues.getPtr(stream_id) orelse {
            return error.StreamNotFound;
        };

        while (stream_queue.messages.items.len == 0) {
            stream_queue.condition.wait(&self.global_mutex);
        }

        return stream_queue.messages.orderedRemove(0);
    }

    /// Remove a stream queue when the stream is closed
    pub fn removeStreamQueue(self: *Self, stream_id: u31) void {
        self.global_mutex.lock();
        defer self.global_mutex.unlock();

        if (self.stream_queues.fetchRemove(stream_id)) |kv| {
            kv.value.messages.deinit();
        }
    }

    /// Free all resources associated with the queue
    pub fn deinit(self: *Self) void {
        self.global_mutex.lock();
        defer self.global_mutex.unlock();

        var iterator = self.stream_queues.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.messages.deinit();
        }
        self.stream_queues.deinit();
    }
};

// OPTIMIZATION 1: Memory Management - Use object pools for scope creation
// OPTIMIZATION 6: Data Structure - Use native Zig structs instead of JSON for internal messaging
// UVICORN PARITY: Add HTTP/2 specific scope fields (stream_id, push_promise support)
// UVICORN PARITY: Add TLS/SSL connection information to scope
/// Create an HTTP scope for an ASGI application
pub fn createHttpScope(allocator: Allocator, server_addr: []const u8, server_port: u16, client_addr: []const u8, client_port: u16, method: []const u8, path: []const u8, query: ?[]const u8, headers: []const [2][]const u8) !json.Value {
    var scope = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try scope.object.put("type", json.Value{ .string = "http" });

    var asgi_version = json.Value{
        .object = json.ObjectMap.init(allocator),
    };
    try asgi_version.object.put("version", json.Value{ .string = "3.0" });
    try asgi_version.object.put("spec_version", json.Value{ .string = "2.0" });
    try scope.object.put("asgi", asgi_version);

    try scope.object.put("http_version", json.Value{ .string = "1.1" });
    try scope.object.put("method", json.Value{ .string = method });
    try scope.object.put("scheme", json.Value{ .string = "http" });
    try scope.object.put("path", json.Value{ .string = path });

    if (query) |q| {
        try scope.object.put("query_string", json.Value{ .string = q });
    } else {
        try scope.object.put("query_string", json.Value{ .string = "" });
    }

    var header_list = json.Value{
        .array = json.Array.init(allocator),
    };

    for (headers) |header| {
        var header_pair = json.Value{
            .array = json.Array.init(allocator),
        };
        try header_pair.array.append(json.Value{ .string = header[0] });
        try header_pair.array.append(json.Value{ .string = header[1] });
        try header_list.array.append(header_pair);
    }

    try scope.object.put("headers", header_list);

    var client = json.Value{
        .array = json.Array.init(allocator),
    };
    try client.array.append(json.Value{ .string = client_addr });
    try client.array.append(json.Value{ .float = @floatFromInt(client_port) });
    try scope.object.put("client", client);

    var server = json.Value{
        .array = json.Array.init(allocator),
    };
    try server.array.append(json.Value{ .string = server_addr });
    try server.array.append(json.Value{ .float = @floatFromInt(server_port) });
    try scope.object.put("server", server);

    return scope;
}

/// Create an HTTP/2 scope for an ASGI application with stream support
pub fn createHttp2Scope(allocator: Allocator, server_addr: []const u8, server_port: u16, client_addr: []const u8, client_port: u16, method: []const u8, path: []const u8, query: ?[]const u8, headers: []const [2][]const u8, stream_id: u31, scheme: []const u8, authority: ?[]const u8) !json.Value {
    var scope = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try scope.object.put("type", json.Value{ .string = "http" });

    var asgi_version = json.Value{
        .object = json.ObjectMap.init(allocator),
    };
    try asgi_version.object.put("version", json.Value{ .string = "3.0" });
    try asgi_version.object.put("spec_version", json.Value{ .string = "2.0" });
    try scope.object.put("asgi", asgi_version);

    // HTTP/2 specific fields
    try scope.object.put("http_version", json.Value{ .string = "2.0" });
    try scope.object.put("method", json.Value{ .string = method });
    try scope.object.put("scheme", json.Value{ .string = scheme });
    try scope.object.put("path", json.Value{ .string = path });

    // Add authority pseudo-header if present
    if (authority) |auth| {
        try scope.object.put("authority", json.Value{ .string = auth });
    }

    // Add stream ID for HTTP/2
    try scope.object.put("stream_id", json.Value{ .integer = @as(i64, stream_id) });

    if (query) |q| {
        try scope.object.put("query_string", json.Value{ .string = q });
    } else {
        try scope.object.put("query_string", json.Value{ .string = "" });
    }

    var header_list = json.Value{
        .array = json.Array.init(allocator),
    };

    for (headers) |header| {
        var header_pair = json.Value{
            .array = json.Array.init(allocator),
        };
        try header_pair.array.append(json.Value{ .string = header[0] });
        try header_pair.array.append(json.Value{ .string = header[1] });
        try header_list.array.append(header_pair);
    }

    try scope.object.put("headers", header_list);

    var client = json.Value{
        .array = json.Array.init(allocator),
    };
    try client.array.append(json.Value{ .string = client_addr });
    try client.array.append(json.Value{ .float = @floatFromInt(client_port) });
    try scope.object.put("client", client);

    var server = json.Value{
        .array = json.Array.init(allocator),
    };
    try server.array.append(json.Value{ .string = server_addr });
    try server.array.append(json.Value{ .float = @floatFromInt(server_port) });
    try scope.object.put("server", server);

    return scope;
}

/// HTTP/2 pseudo-header utility
pub const Http2PseudoHeaders = struct {
    method: ?[]const u8 = null,
    scheme: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    path: ?[]const u8 = null,

    pub fn init() Http2PseudoHeaders {
        return Http2PseudoHeaders{};
    }

    pub fn fromHeaders(headers: []const [2][]const u8) Http2PseudoHeaders {
        var pseudo = Http2PseudoHeaders.init();

        for (headers) |header| {
            const name = header[0];
            const value = header[1];

            if (std.mem.eql(u8, name, ":method")) {
                pseudo.method = value;
            } else if (std.mem.eql(u8, name, ":scheme")) {
                pseudo.scheme = value;
            } else if (std.mem.eql(u8, name, ":authority")) {
                pseudo.authority = value;
            } else if (std.mem.eql(u8, name, ":path")) {
                pseudo.path = value;
            }
        }

        return pseudo;
    }

    pub fn isValid(self: *const Http2PseudoHeaders) bool {
        return self.method != null and self.scheme != null and self.path != null;
    }
};

// UVICORN PARITY: Add WebSocket subprotocol negotiation support
// UVICORN PARITY: Add WebSocket extension support (compression, etc.)
// UVICORN PARITY: Add WebSocket connection state management
/// Create a WebSocket scope for an ASGI application
pub fn createWebSocketScope(allocator: Allocator, server_addr: []const u8, server_port: u16, client_addr: []const u8, client_port: u16, path: []const u8, query: ?[]const u8, headers: []const [2][]const u8) !json.Value {
    var scope = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try scope.object.put("type", json.Value{ .string = "websocket" });

    var asgi_version = json.Value{
        .object = json.ObjectMap.init(allocator),
    };
    try asgi_version.object.put("version", json.Value{ .string = "3.0" });
    try asgi_version.object.put("spec_version", json.Value{ .string = "2.0" });
    try scope.object.put("asgi", asgi_version);

    try scope.object.put("path", json.Value{ .string = path });

    if (query) |q| {
        try scope.object.put("query_string", json.Value{ .string = q });
    } else {
        try scope.object.put("query_string", json.Value{ .string = "" });
    }

    var header_list = json.Value{
        .array = json.Array.init(allocator),
    };

    for (headers) |header| {
        var header_pair = json.Value{
            .array = json.Array.init(allocator),
        };
        try header_pair.array.append(json.Value{ .string = header[0] });
        try header_pair.array.append(json.Value{ .string = header[1] });
        try header_list.array.append(header_pair);
    }

    try scope.object.put("headers", header_list);

    var client = json.Value{
        .array = json.Array.init(allocator),
    };
    try client.array.append(json.Value{ .string = client_addr });
    try client.array.append(json.Value{ .float = @floatFromInt(client_port) });
    try scope.object.put("client", client);

    var server = json.Value{
        .array = json.Array.init(allocator),
    };
    try server.array.append(json.Value{ .string = server_addr });
    try server.array.append(json.Value{ .float = @floatFromInt(server_port) });
    try scope.object.put("server", server);

    return scope;
}

/// Create a Lifespan scope for an ASGI application
pub fn createLifespanScope(allocator: Allocator) !json.Value {
    var scope = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try scope.object.put("type", json.Value{ .string = "lifespan" });

    var asgi_version = json.Value{
        .object = json.ObjectMap.init(allocator),
    };
    try asgi_version.object.put("version", json.Value{ .string = "3.0" });
    try asgi_version.object.put("spec_version", json.Value{ .string = "2.0" });
    try scope.object.put("asgi", asgi_version);

    return scope;
}

// OPTIMIZATION 8: Protocol-Specific - Cache common message types to avoid repeated creation
/// Create an HTTP request message
pub fn createHttpRequestMessage(allocator: Allocator, body: ?[]const u8, more_body: bool) !json.Value {
    var message = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try message.object.put("type", json.Value{ .string = "http.request" });

    if (body) |b| {
        try message.object.put("body", json.Value{ .string = b });
    } else {
        try message.object.put("body", json.Value{ .string = "" });
    }

    try message.object.put("more_body", json.Value{ .bool = more_body });

    return message;
}

/// Create an HTTP response start message
pub fn createHttpResponseStartMessage(allocator: Allocator, status: u16, headers: []const [2][]const u8) !json.Value {
    var message = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try message.object.put("type", json.Value{ .string = "http.response.start" });
    try message.object.put("status", json.Value{ .integer = status });

    var header_list = json.Value{
        .array = json.Array.init(allocator),
    };

    for (headers) |header| {
        var header_pair = json.Value{
            .array = json.Array.init(allocator),
        };
        try header_pair.array.append(json.Value{ .string = header[0] });
        try header_pair.array.append(json.Value{ .string = header[1] });
        try header_list.array.append(header_pair);
    }

    try message.object.put("headers", header_list);

    return message;
}

/// Create an HTTP response body message
pub fn createHttpResponseBodyMessage(allocator: Allocator, body: []const u8, more_body: bool) !json.Value {
    var message = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try message.object.put("type", json.Value{ .string = "http.response.body" });
    try message.object.put("body", json.Value{ .string = body });
    try message.object.put("more_body", json.Value{ .bool = more_body });

    return message;
}

// UVICORN PARITY: Add WebSocket ping/pong message handling
// UVICORN PARITY: Add WebSocket close code and reason support
/// Create a WebSocket connect message
pub fn createWebSocketConnectMessage(allocator: Allocator) !json.Value {
    var message = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try message.object.put("type", json.Value{ .string = "websocket.connect" });

    return message;
}

/// Create a WebSocket accept message
pub fn createWebSocketAcceptMessage(allocator: Allocator, subprotocol: ?[]const u8, headers: ?[]const [2][]const u8) !json.Value {
    var message = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try message.object.put("type", json.Value{ .string = "websocket.accept" });

    if (subprotocol) |s| {
        try message.object.put("subprotocol", json.Value{ .string = s });
    }

    if (headers) |h| {
        var header_list = json.Value{
            .array = json.Array.init(allocator),
        };

        for (h) |header| {
            var header_pair = json.Value{
                .array = json.Array.init(allocator),
            };
            try header_pair.array.append(json.Value{ .string = header[0] });
            try header_pair.array.append(json.Value{ .string = header[1] });
            try header_list.array.append(header_pair);
        }

        try message.object.put("headers", header_list);
    }

    return message;
}

/// Create a WebSocket send message (text)
pub fn createWebSocketSendTextMessage(allocator: Allocator, text: []const u8) !json.Value {
    var message = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try message.object.put("type", json.Value{ .string = "websocket.send" });
    try message.object.put("text", json.Value{ .string = text });

    return message;
}

/// Create a WebSocket send message (binary)
pub fn createWebSocketSendBinaryMessage(allocator: Allocator, bytes: []const u8) !json.Value {
    var message = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try message.object.put("type", json.Value{ .string = "websocket.send" });
    try message.object.put("bytes", json.Value{ .string = bytes });

    return message;
}

/// Create a WebSocket receive message
pub fn createWebSocketReceiveMessage(allocator: Allocator, text: ?[]const u8, bytes: ?[]const u8) !json.Value {
    var message = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try message.object.put("type", json.Value{ .string = "websocket.receive" });

    if (text) |t| {
        try message.object.put("text", json.Value{ .string = t });
    }

    if (bytes) |b| {
        try message.object.put("bytes", json.Value{ .string = b });
    }

    return message;
}

/// Create a WebSocket disconnect message
pub fn createWebSocketDisconnectMessage(allocator: Allocator, code: u16) !json.Value {
    var message = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try message.object.put("type", json.Value{ .string = "websocket.disconnect" });
    try message.object.put("code", json.Value{ .integer = code });

    return message;
}

/// Create a Lifespan startup message
pub fn createLifespanStartupMessage(allocator: Allocator) !json.Value {
    var message = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try message.object.put("type", json.Value{ .string = "lifespan.startup" });

    return message;
}

/// Create a Lifespan shutdown message
pub fn createLifespanShutdownMessage(allocator: Allocator) !json.Value {
    var message = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try message.object.put("type", json.Value{ .string = "lifespan.shutdown" });

    return message;
}

/// Create a Lifespan startup complete message
pub fn createLifespanStartupCompleteMessage(allocator: Allocator) !json.Value {
    var message = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try message.object.put("type", json.Value{ .string = "lifespan.startup.complete" });

    return message;
}

/// Create a Lifespan startup failed message
pub fn createLifespanStartupFailedMessage(allocator: Allocator, message_text: []const u8) !json.Value {
    var message = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try message.object.put("type", json.Value{ .string = "lifespan.startup.failed" });
    try message.object.put("message", json.Value{ .string = message_text });

    return message;
}

/// Create a Lifespan shutdown complete message
pub fn createLifespanShutdownCompleteMessage(allocator: Allocator) !json.Value {
    var message = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try message.object.put("type", json.Value{ .string = "lifespan.shutdown.complete" });

    return message;
}

/// Create a Lifespan shutdown failed message
pub fn createLifespanShutdownFailedMessage(allocator: Allocator, message_text: []const u8) !json.Value {
    var message = json.Value{
        .object = json.ObjectMap.init(allocator),
    };

    try message.object.put("type", json.Value{ .string = "lifespan.shutdown.failed" });
    try message.object.put("message", json.Value{ .string = message_text });

    return message;
}
