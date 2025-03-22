const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const crypto = std.crypto;

/// WebSocket message types
pub const MessageType = enum {
    text,
    binary,
    close,
    ping,
    pong,
};

/// WebSocket frame opcodes
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

/// WebSocket message
pub const Message = struct {
    type: MessageType,
    data: []const u8,
    allocator: Allocator,

    /// Free the message data
    pub fn deinit(self: *Message) void {
        self.allocator.free(self.data);
    }
};

/// WebSocket connection
pub const Connection = struct {
    stream: net.Stream,
    allocator: Allocator,
    is_server: bool,
    mask_outgoing: bool,

    /// Create a new WebSocket connection
    pub fn init(stream: net.Stream, allocator: Allocator, is_server: bool) Connection {
        return Connection{
            .stream = stream,
            .allocator = allocator,
            .is_server = is_server,
            .mask_outgoing = !is_server, // Client masks outgoing, server doesn't
        };
    }

    /// Close the connection
    pub fn close(self: *Connection) void {
        self.stream.close();
    }

    /// Send a WebSocket message
    pub fn send(self: *Connection, message_type: MessageType, data: []const u8) !void {
        const opcode: Opcode = switch (message_type) {
            .text => .text,
            .binary => .binary,
            .close => .close,
            .ping => .ping,
            .pong => .pong,
        };

        try self.sendFrame(true, opcode, data);
    }

    /// Send a WebSocket frame
    fn sendFrame(self: *Connection, fin: bool, opcode: Opcode, data: []const u8) !void {
        // First byte: FIN bit + opcode
        const fin_bit: u8 = if (fin) 0x80 else 0;
        const first_byte: u8 = @as(u8, @intFromEnum(opcode)) | fin_bit;

        // Prepare the buffer
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        try buffer.append(first_byte);

        // Second byte: MASK bit + payload length
        var second_byte: u8 = 0;
        if (self.mask_outgoing) {
            second_byte |= 0x80; // Set MASK bit
        }

        // Determine payload length format
        if (data.len < 126) {
            second_byte |= @intCast(data.len);
            try buffer.append(second_byte);
        } else if (data.len <= 65535) {
            second_byte |= 126;
            try buffer.append(second_byte);

            // 2-byte extended payload length
            try buffer.append(@intCast((data.len >> 8) & 0xFF));
            try buffer.append(@intCast(data.len & 0xFF));
        } else {
            second_byte |= 127;
            try buffer.append(second_byte);

            // 8-byte extended payload length
            var i: usize = 8;
            while (i > 0) : (i -= 1) {
                const shift_amount: u6 = @intCast((i - 1) * 8);
                try buffer.append(@intCast((data.len >> shift_amount) & 0xFF));
            }
        }

        // Add masking key if needed
        var mask_key: [4]u8 = undefined;
        if (self.mask_outgoing) {
            crypto.random.bytes(&mask_key);
            try buffer.appendSlice(&mask_key);
        }

        // Add payload data (possibly masked)
        if (self.mask_outgoing) {
            // Apply masking
            var masked_data = try self.allocator.alloc(u8, data.len);
            defer self.allocator.free(masked_data);

            for (data, 0..) |byte, i| {
                masked_data[i] = byte ^ mask_key[i % 4];
            }

            try buffer.appendSlice(masked_data);
        } else {
            try buffer.appendSlice(data);
        }

        // Send the frame
        _ = try self.stream.writeAll(buffer.items);
    }

    /// Receive a WebSocket message
    pub fn receive(self: *Connection) !Message {
        // Read the first two bytes
        var header: [2]u8 = undefined;
        const bytes_read = try self.stream.read(&header);
        if (bytes_read < 2) {
            return error.ConnectionClosed;
        }

        // Parse first byte: FIN bit + opcode
        const fin = (header[0] & 0x80) != 0;
        const opcode = @as(Opcode, @enumFromInt(header[0] & 0x0F));

        if (!fin) {
            // We don't support fragmented messages yet
            return error.FragmentedMessage;
        }

        // Parse second byte: MASK bit + payload length
        const mask = (header[1] & 0x80) != 0;
        var payload_len: usize = header[1] & 0x7F;

        // Extended payload length
        if (payload_len == 126) {
            var ext_len: [2]u8 = undefined;
            const ext_bytes_read = try self.stream.read(&ext_len);
            if (ext_bytes_read < 2) {
                return error.ConnectionClosed;
            }

            payload_len = (@as(usize, ext_len[0]) << 8) | ext_len[1];
        } else if (payload_len == 127) {
            var ext_len: [8]u8 = undefined;
            const ext_bytes_read = try self.stream.read(&ext_len);
            if (ext_bytes_read < 8) {
                return error.ConnectionClosed;
            }

            payload_len = 0;
            for (ext_len, 0..) |byte, i| {
                const shift_amount: u6 = @intCast((7 - i) * 8);
                payload_len |= @as(usize, byte) << shift_amount;
            }
        }

        // Read masking key if present
        var mask_key: [4]u8 = undefined;
        if (mask) {
            const mask_bytes_read = try self.stream.read(&mask_key);
            if (mask_bytes_read < 4) {
                return error.ConnectionClosed;
            }
        }

        // Read payload data
        var payload = try self.allocator.alloc(u8, payload_len);
        errdefer self.allocator.free(payload);

        var total_read: usize = 0;
        while (total_read < payload_len) {
            const payload_bytes_read = try self.stream.read(payload[total_read..]);
            if (payload_bytes_read == 0) {
                return error.ConnectionClosed;
            }

            total_read += payload_bytes_read;
        }

        // Apply masking if needed
        if (mask) {
            for (payload, 0..) |*byte, i| {
                byte.* ^= mask_key[i % 4];
            }
        }

        // Determine message type
        const message_type = switch (opcode) {
            .text => MessageType.text,
            .binary => MessageType.binary,
            .close => MessageType.close,
            .ping => MessageType.ping,
            .pong => MessageType.pong,
            else => return error.InvalidOpcode,
        };

        return Message{
            .type = message_type,
            .data = payload,
            .allocator = self.allocator,
        };
    }
};

/// Perform the WebSocket handshake
pub fn handshake(allocator: Allocator, stream: net.Stream, request_headers: std.StringHashMap([]const u8)) !Connection {
    // Verify it's a valid WebSocket upgrade request
    const upgrade = request_headers.get("Upgrade") orelse return error.NotWebSocketRequest;
    const connection = request_headers.get("Connection") orelse return error.NotWebSocketRequest;
    const websocket_key = request_headers.get("Sec-WebSocket-Key") orelse return error.NotWebSocketRequest;

    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket") or
        std.mem.indexOf(u8, connection, "upgrade") == null)
    {
        return error.NotWebSocketRequest;
    }

    // Calculate the accept key
    const websocket_key_suffix = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    const full_key = try std.mem.concat(allocator, u8, &[_][]const u8{ websocket_key, websocket_key_suffix });
    defer allocator.free(full_key);

    var sha1_hash: [20]u8 = undefined;
    crypto.hash.Sha1.hash(full_key, &sha1_hash, .{});

    var base64_buf: [28]u8 = undefined; // SHA-1 hash in base64 is 28 bytes
    const accept_key = std.base64.standard.Encoder.encode(&base64_buf, &sha1_hash);

    // Send the WebSocket handshake response
    var response = std.ArrayList(u8).init(allocator);
    defer response.deinit();

    try response.writer().print("HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: {s}\r\n" ++
        "\r\n", .{accept_key});

    _ = try stream.writeAll(response.items);

    // Create and return the WebSocket connection
    return Connection.init(stream, allocator, true);
}
