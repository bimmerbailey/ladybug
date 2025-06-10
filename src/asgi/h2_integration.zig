const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const h2_frames = @import("../http/h2_frames.zig");
const h2_streams = @import("../http/h2_streams.zig");
const hpack = @import("../http/hpack.zig");
const protocol = @import("protocol.zig");

/// HTTP/2 to ASGI integration handler
pub const Http2AsgiHandler = struct {
    const Self = @This();

    allocator: Allocator,
    stream_manager: h2_streams.StreamManager,
    message_queue: protocol.Http2StreamMessageQueue,
    decoder: hpack.HpackDecoder,
    encoder: hpack.HpackEncoder,

    pub fn init(allocator: Allocator, initial_window_size: i32) !Self {
        return Self{
            .allocator = allocator,
            .stream_manager = h2_streams.StreamManager.init(allocator, initial_window_size),
            .message_queue = protocol.Http2StreamMessageQueue.init(allocator),
            .decoder = hpack.HpackDecoder.init(allocator, 4096),
            .encoder = hpack.HpackEncoder.init(allocator, 4096),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stream_manager.deinit();
        self.message_queue.deinit();
        self.decoder.deinit();
        self.encoder.deinit();
    }

    /// Process an HTTP/2 frame and convert to ASGI messages
    pub fn processFrame(self: *Self, frame: h2_frames.Frame) !void {
        switch (frame.header.frame_type) {
            .HEADERS => try self.processHeadersFrame(frame),
            .DATA => try self.processDataFrame(frame),
            .RST_STREAM => try self.processRstStreamFrame(frame),
            .SETTINGS => try self.processSettingsFrame(frame),
            .WINDOW_UPDATE => try self.processWindowUpdateFrame(frame),
            .PING => try self.processPingFrame(frame),
            .GOAWAY => try self.processGoAwayFrame(frame),
            else => {
                std.debug.print("Unhandled frame type: {}\n", .{frame.header.frame_type});
            },
        }
    }

    /// Process HEADERS frame and create ASGI scope
    fn processHeadersFrame(self: *Self, frame: h2_frames.Frame) !void {
        const stream_id = frame.header.stream_id;

        // Create or get stream
        var stream = self.stream_manager.getStream(stream_id);
        if (stream == null) {
            stream = try self.stream_manager.createStream(stream_id);
            try self.message_queue.createStreamQueue(stream_id);
        }

        // Decode headers using HPACK
        const headers = try self.decoder.decode(frame.payload);
        defer {
            for (headers.items) |header| {
                self.allocator.free(header.name);
                self.allocator.free(header.value);
            }
            headers.deinit();
        }

        // Extract pseudo-headers
        var pseudo_headers = protocol.Http2PseudoHeaders.init();
        var regular_headers = std.ArrayList([2][]const u8).init(self.allocator);
        defer {
            for (regular_headers.items) |header| {
                self.allocator.free(header[0]);
                self.allocator.free(header[1]);
            }
            regular_headers.deinit();
        }

        for (headers.items) |header| {
            if (std.mem.startsWith(u8, header.name, ":")) {
                if (std.mem.eql(u8, header.name, ":method")) {
                    pseudo_headers.method = try self.allocator.dupe(u8, header.value);
                } else if (std.mem.eql(u8, header.name, ":scheme")) {
                    pseudo_headers.scheme = try self.allocator.dupe(u8, header.value);
                } else if (std.mem.eql(u8, header.name, ":authority")) {
                    pseudo_headers.authority = try self.allocator.dupe(u8, header.value);
                } else if (std.mem.eql(u8, header.name, ":path")) {
                    pseudo_headers.path = try self.allocator.dupe(u8, header.value);
                }
            } else {
                try regular_headers.append([2][]const u8{
                    try self.allocator.dupe(u8, header.name),
                    try self.allocator.dupe(u8, header.value),
                });
            }
        }

        // Validate pseudo-headers
        if (!pseudo_headers.isValid()) {
            std.debug.print("Invalid HTTP/2 pseudo-headers\n", .{});
            return;
        }

        // Extract path and query string
        const path_and_query = pseudo_headers.path.?;
        var path: []const u8 = path_and_query;
        var query: ?[]const u8 = null;

        if (std.mem.indexOf(u8, path_and_query, "?")) |query_start| {
            path = path_and_query[0..query_start];
            query = path_and_query[query_start + 1 ..];
        }

        // Create HTTP/2 ASGI scope
        const scope = try protocol.createHttp2Scope(
            self.allocator,
            "127.0.0.1", // TODO: Get actual server address
            8080, // TODO: Get actual server port
            "127.0.0.1", // TODO: Get actual client address
            12345, // TODO: Get actual client port
            pseudo_headers.method.?,
            path,
            query,
            regular_headers.items,
            stream_id,
            pseudo_headers.scheme.?,
            pseudo_headers.authority,
        );

        // Store scope for this stream (for later use)
        // TODO: Add scope storage to stream or handler

        std.debug.print("Created HTTP/2 ASGI scope for stream {}: {}\n", .{ stream_id, scope });

        // If this is the end of headers, mark stream as ready for body processing
        if ((frame.header.flags & h2_frames.FrameFlags.END_HEADERS) != 0) {
            if (stream) |s| {
                s.headers_complete = true;
            }
        }

        // If this is also end of stream, create the HTTP request message
        if ((frame.header.flags & h2_frames.FrameFlags.END_STREAM) != 0) {
            const request_message = try protocol.createHttpRequestMessage(
                self.allocator,
                null, // No body
                false, // No more body
            );

            try self.message_queue.pushToStream(stream_id, request_message);

            // Transition stream state
            if (stream) |s| {
                try s.transitionState(.recv_end_stream);
            }
        }

        // Clean up pseudo-headers
        if (pseudo_headers.method) |m| self.allocator.free(m);
        if (pseudo_headers.scheme) |s| self.allocator.free(s);
        if (pseudo_headers.authority) |a| self.allocator.free(a);
        if (pseudo_headers.path) |p| self.allocator.free(p);
    }

    /// Process DATA frame
    fn processDataFrame(self: *Self, frame: h2_frames.Frame) !void {
        const stream_id = frame.header.stream_id;

        const stream = self.stream_manager.getStream(stream_id) orelse {
            std.debug.print("Received DATA frame for unknown stream {}\n", .{stream_id});
            return;
        };

        if (!stream.canReceiveData()) {
            std.debug.print("Stream {} cannot receive data in state {}\n", .{ stream_id, stream.state });
            return;
        }

        // Create HTTP request message with body
        const more_body = (frame.header.flags & h2_frames.FrameFlags.END_STREAM) == 0;
        const request_message = try protocol.createHttpRequestMessage(
            self.allocator,
            frame.payload,
            more_body,
        );

        try self.message_queue.pushToStream(stream_id, request_message);

        // If this is the end of stream, transition state
        if (!more_body) {
            try stream.transitionState(.recv_end_stream);
        }
    }

    /// Process RST_STREAM frame
    fn processRstStreamFrame(self: *Self, frame: h2_frames.Frame) !void {
        const stream_id = frame.header.stream_id;

        if (self.stream_manager.getStream(stream_id)) |stream| {
            try stream.transitionState(.recv_rst_stream);
            self.message_queue.removeStreamQueue(stream_id);
            self.stream_manager.removeStream(stream_id);
        }
    }

    /// Process SETTINGS frame
    fn processSettingsFrame(self: *Self, frame: h2_frames.Frame) !void {
        if ((frame.header.flags & h2_frames.FrameFlags.ACK) != 0) {
            // This is a SETTINGS ACK
            std.debug.print("Received SETTINGS ACK\n", .{});
            return;
        }

        const settings_frame = try h2_frames.SettingsFrame.parse(self.allocator, frame.payload);
        defer settings_frame.settings.deinit();

        // Apply settings
        for (settings_frame.settings.items) |setting| {
            switch (setting.id) {
                .INITIAL_WINDOW_SIZE => {
                    self.stream_manager.initial_window_size = @intCast(setting.value);
                },
                .MAX_CONCURRENT_STREAMS => {
                    self.stream_manager.max_concurrent_streams = setting.value;
                },
                else => {
                    std.debug.print("Unhandled setting: {} = {}\n", .{ setting.id, setting.value });
                },
            }
        }

        // Send SETTINGS ACK
        // TODO: Implement response sending mechanism
    }

    /// Process WINDOW_UPDATE frame
    fn processWindowUpdateFrame(self: *Self, frame: h2_frames.Frame) !void {
        if (frame.payload.len != 4) {
            return error.InvalidWindowUpdate;
        }

        const increment = (@as(u32, frame.payload[0]) << 24) |
            (@as(u32, frame.payload[1]) << 16) |
            (@as(u32, frame.payload[2]) << 8) |
            @as(u32, frame.payload[3]);

        if (frame.header.stream_id == 0) {
            // Connection-level window update
            self.stream_manager.connection_window_size += @as(i32, @intCast(increment));
        } else {
            // Stream-level window update
            if (self.stream_manager.getStream(frame.header.stream_id)) |stream| {
                try stream.updateWindow(@intCast(increment));
            }
        }
    }

    /// Process PING frame
    fn processPingFrame(self: *Self, frame: h2_frames.Frame) !void {
        _ = self;
        if ((frame.header.flags & h2_frames.FrameFlags.ACK) != 0) {
            std.debug.print("Received PING ACK\n", .{});
        } else {
            std.debug.print("Received PING, should send ACK\n", .{});
            // TODO: Send PING ACK response
        }
    }

    /// Process GOAWAY frame
    fn processGoAwayFrame(self: *Self, frame: h2_frames.Frame) !void {
        _ = self;
        _ = frame;
        std.debug.print("Received GOAWAY frame, connection should be closed\n", .{});
        // TODO: Implement connection shutdown
    }

    /// Send HTTP response to a specific stream
    pub fn sendResponse(self: *Self, stream_id: u31, status: u16, headers: []const [2][]const u8, body: ?[]const u8) !void {
        // Create response headers
        var response_headers = std.ArrayList(hpack.HeaderField).init(self.allocator);
        defer response_headers.deinit();

        // Add status pseudo-header
        const status_str = try std.fmt.allocPrint(self.allocator, "{d}", .{status});
        defer self.allocator.free(status_str);

        try response_headers.append(hpack.HeaderField{
            .name = try self.allocator.dupe(u8, ":status"),
            .value = try self.allocator.dupe(u8, status_str),
        });

        // Add regular headers
        for (headers) |header| {
            try response_headers.append(hpack.HeaderField{
                .name = try self.allocator.dupe(u8, header[0]),
                .value = try self.allocator.dupe(u8, header[1]),
            });
        }

        // Encode headers
        const encoded_headers = try self.encoder.encode(response_headers.items);
        defer self.allocator.free(encoded_headers);

        // Create HEADERS frame
        var flags: u8 = h2_frames.FrameFlags.END_HEADERS;
        if (body == null) {
            flags |= h2_frames.FrameFlags.END_STREAM;
        }

        const headers_frame = h2_frames.Frame{
            .header = h2_frames.FrameHeader{
                .length = @intCast(encoded_headers.len),
                .frame_type = .HEADERS,
                .flags = flags,
                .stream_id = stream_id,
            },
            .payload = encoded_headers,
        };
        _ = headers_frame; // TODO: Send headers frame to client

        std.debug.print("Would send HEADERS frame for stream {}\n", .{stream_id});

        // Send body if present
        if (body) |b| {
            const data_frame = h2_frames.Frame{
                .header = h2_frames.FrameHeader{
                    .length = @intCast(b.len),
                    .frame_type = .DATA,
                    .flags = h2_frames.FrameFlags.END_STREAM,
                    .stream_id = stream_id,
                },
                .payload = b,
            };
            _ = data_frame; // TODO: Send data frame to client

            std.debug.print("Would send DATA frame for stream {}\n", .{stream_id});
        }

        // Update stream state
        if (self.stream_manager.getStream(stream_id)) |stream| {
            try stream.transitionState(.send_end_stream);
        }

        // Clean up response headers
        for (response_headers.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
    }
};
