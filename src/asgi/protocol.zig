const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

/// ASGI specification version
pub const AsgiVersion = struct {
    version: []const u8 = "3.0",
    spec_version: []const u8 = "2.0",
};

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

    /// Receive a message from the queue, blocking if none is available
    pub fn receive(self: *Self) !json.Value {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.messages.items.len == 0) {
            self.condition.wait(&self.mutex);
        }

        const message = self.messages.orderedRemove(0);
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
