const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;

// UVICORN PARITY: Add TLS/SSL configuration options (cert_file, key_file, ca_certs)
// UVICORN PARITY: Add HTTP/2 configuration options and protocol selection
// UVICORN PARITY: Add WebSocket configuration (ping_interval, ping_timeout, max_size)
/// HTTP Server configuration
pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8000,
    backlog: u32 = 128,
};

/// HTTP server that can be started and stopped
pub const Server = struct {
    allocator: Allocator,
    config: Config,
    listener: ?net.Server = null,
    running: bool = false,

    /// Create a new HTTP server with the given configuration
    pub fn init(allocator: Allocator, config: Config) Server {
        return Server{
            .allocator = allocator,
            .config = config,
        };
    }

    // OPTIMIZATION 5: Network I/O - Add TCP_NODELAY, SO_REUSEPORT, and socket buffer tuning
    // OPTIMIZATION 9: System-Level - Optimize socket buffer sizes (SO_RCVBUF, SO_SNDBUF)
    // UVICORN PARITY: Add TLS/SSL socket setup and certificate loading
    // UVICORN PARITY: Add HTTP/2 ALPN negotiation support
    /// Start the server and begin accepting connections
    pub fn start(self: *Server) !void {
        if (self.running) return;

        const address = try std.net.Address.parseIp(self.config.host, self.config.port);
        self.listener = try address.listen(.{
            .reuse_address = true,
            // Set non-blocking mode
            .force_nonblocking = true,
        });
        self.running = true;

        std.debug.print("HTTP server listening on http://{s}:{d}\n", .{ self.config.host, self.config.port });
    }

    /// Stop the server and close all connections
    pub fn stop(self: *Server) void {
        if (!self.running) return;

        if (self.listener) |*listener| {
            listener.deinit();
            self.listener = null;
        }

        self.running = false;
        std.debug.print("HTTP server stopped\n", .{});
    }

    // OPTIMIZATION 5: Network I/O - Replace with epoll/kqueue-based event loop
    // UVICORN PARITY: Add connection limiting and rate limiting support
    // UVICORN PARITY: Add TLS handshake handling for HTTPS connections
    /// Accept a connection from the listener with timeout
    pub fn accept(self: *Server) !net.Server.Connection {
        if (!self.running or self.listener == null) {
            return error.ServerNotRunning;
        }

        // Try to accept a connection
        return self.listener.?.accept() catch |err| {
            switch (err) {
                error.WouldBlock => return error.WouldBlock,
                else => return err,
            }
        };
    }
};

// OPTIMIZATION 2: HTTP Parsing - Implement streaming parser for large requests
// OPTIMIZATION 2: HTTP Parsing - Use zero-copy parsing techniques
// OPTIMIZATION 1: Memory Management - Use buffer pools instead of allocating 4KB per request
// UVICORN PARITY: Add HTTP/2 frame parsing and stream multiplexing
// UVICORN PARITY: Add WebSocket handshake detection and upgrade handling
// UVICORN PARITY: Add request size limits and timeout handling
/// Parse an HTTP request from a connection
pub fn parseRequest(allocator: Allocator, stream: *net.Stream) !Request {
    // Buffer for reading the request
    const buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(buffer);

    // Read from the stream
    const bytes_read = try stream.read(buffer);
    if (bytes_read == 0) return error.EmptyRequest;

    std.debug.print("\nDEBUG: Parsing request\n", .{});
    std.debug.print("DEBUG: Request buffer: {s}\n", .{buffer[0..bytes_read]});

    // Create a request object from the buffer
    return Request.parse(allocator, buffer[0..bytes_read]);
}

// UVICORN PARITY: Add support for HTTP/2 pseudo-headers (:method, :path, :scheme, :authority)
// UVICORN PARITY: Add WebSocket-specific fields (Sec-WebSocket-Key, Sec-WebSocket-Protocol)
// UVICORN PARITY: Add connection upgrade detection and protocol switching
/// HTTP request representation
pub const Request = struct {
    method: []const u8,
    path: []const u8,
    query: ?[]const u8 = null,
    version: []const u8,
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8 = null,

    // OPTIMIZATION 2: HTTP Parsing - Implement zero-copy parsing to avoid string duplication
    // OPTIMIZATION 1: Memory Management - Use string interning for common header names
    // OPTIMIZATION 6: Data Structure - Use more efficient header storage (arrays vs hashmaps)
    /// Parse a raw HTTP request into a Request object
    pub fn parse(allocator: Allocator, buffer: []const u8) !Request {
        var result = Request{
            .method = "",
            .path = "",
            .version = "",
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = null,
        };

        // Find the end of headers (double CRLF)
        const header_end = std.mem.indexOf(u8, buffer, "\r\n\r\n") orelse return error.InvalidRequest;

        // Headers section (including request line)
        const headers_section = buffer[0..header_end];

        // Body starts after the double CRLF
        if (header_end + 4 < buffer.len) {
            const body_data = buffer[header_end + 4 ..];
            // Only set body if there's actual content
            if (body_data.len > 0) {
                result.body = try allocator.dupe(u8, body_data);
            }
        }

        // Split headers into lines
        var lines = std.mem.splitSequence(u8, headers_section, "\r\n");

        // First line is the request line
        const request_line = lines.next() orelse return error.InvalidRequest;

        // Parse request line (METHOD URI HTTP/VERSION)
        var request_parts = std.mem.tokenizeSequence(u8, request_line, " ");

        const method = request_parts.next() orelse return error.InvalidRequest;
        result.method = try allocator.dupe(u8, method);

        const uri = request_parts.next() orelse return error.InvalidRequest;

        // Split URI into path and query if a question mark exists
        if (std.mem.indexOf(u8, uri, "?")) |query_start| {
            result.path = try allocator.dupe(u8, uri[0..query_start]);
            result.query = try allocator.dupe(u8, uri[query_start + 1 ..]);
        } else {
            result.path = try allocator.dupe(u8, uri);
        }

        const version = request_parts.next() orelse return error.InvalidRequest;
        result.version = try allocator.dupe(u8, version);

        // Parse headers
        while (lines.next()) |line| {
            if (line.len == 0) continue; // Skip empty lines

            const colon_pos = std.mem.indexOf(u8, line, ":") orelse return error.InvalidHeader;
            const header_name = std.mem.trim(u8, line[0..colon_pos], &std.ascii.whitespace);
            const header_value = std.mem.trim(u8, line[colon_pos + 1 ..], &std.ascii.whitespace);

            const name_dup = try allocator.dupe(u8, header_name);
            const value_dup = try allocator.dupe(u8, header_value);

            try result.headers.put(name_dup, value_dup);
        }

        std.debug.print("DEBUG: Parsed request\n", .{});
        std.debug.print("DEBUG: Method: {s}\n", .{result.method});
        std.debug.print("DEBUG: Path: {s}\n", .{result.path});
        // std.debug.print("DEBUG: Version: {s}\n", .{result.version});
        // std.debug.print("DEBUG: Headers: {any}\n", .{result.headers});
        // std.debug.print("DEBUG: Body: {s}\n", .{result.body});
        return result;
    }

    /// Free all memory allocated for the request
    pub fn deinit(self: *Request) void {
        std.debug.print("DEBUG: Deinitializing request\n", .{});
        const allocator = self.headers.allocator;

        // Free the method, path, etc.
        allocator.free(self.method);
        std.debug.print("DEBUG: Freed method\n", .{});
        allocator.free(self.path);
        std.debug.print("DEBUG: Freed path\n", .{});
        if (self.query) |q| allocator.free(q);
        std.debug.print("DEBUG: Freed query\n", .{});
        allocator.free(self.version);

        std.debug.print("DEBUG: Deinitializing headers\n", .{});
        // Free the header keys and values
        var iterator = self.headers.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }

        // Free the headers hash map
        self.headers.deinit();

        // Free the body if present
        if (self.body) |body| {
            allocator.free(body);
        }
        std.debug.print("DEBUG: Deinitialized request\n", .{});
    }
};

/// HTTP response that can be sent back to the client
pub const Response = struct {
    status: u16,
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,
    allocator: Allocator,

    // OPTIMIZATION 1: Memory Management - Use object pools for Response objects
    /// Create a new response with default values
    pub fn init(allocator: Allocator) Response {
        std.debug.print("DEBUG: Initializing response\n", .{});
        return Response{
            .status = 200,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = null,
            .allocator = allocator,
        };
    }

    // OPTIMIZATION 1: Memory Management - Avoid string duplication for headers
    /// Set a header on the response
    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
        const name_dup = try self.allocator.dupe(u8, name);
        const value_dup = try self.allocator.dupe(u8, value);
        try self.headers.put(name_dup, value_dup);
    }

    /// Set the body of the response
    pub fn setBody(self: *Response, body: []const u8) !void {
        if (self.body) |old_body| {
            self.allocator.free(old_body);
        }

        self.body = try self.allocator.dupe(u8, body);
    }

    // OPTIMIZATION 1: Memory Management - Use buffer pools for response building
    // OPTIMIZATION 5: Network I/O - Implement vectored I/O for better performance
    // UVICORN PARITY: Add HTTP/2 frame formatting and stream management
    // UVICORN PARITY: Add automatic security headers (CORS, CSP, HSTS) injection
    // UVICORN PARITY: Add response compression (gzip, brotli) support
    /// Send the response to the given stream
    pub fn send(self: *const Response, stream: *net.Stream) !void {
        // Create a buffer for the response
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        // Add the status line
        try buffer.writer().print("HTTP/1.1 {d} {s}\r\n", .{
            self.status, statusText(self.status),
        });

        // Add content length if body exists
        if (self.body) |body| {
            try buffer.writer().print("Content-Length: {d}\r\n", .{body.len});
        }

        // Add headers
        var iterator = self.headers.iterator();
        while (iterator.next()) |entry| {
            try buffer.writer().print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        // End headers
        try buffer.writer().writeAll("\r\n");

        // Add body if present
        if (self.body) |body| {
            try buffer.writer().writeAll(body);
        }

        // Write to stream
        _ = try stream.write(buffer.items);
    }

    /// Free all memory allocated for the response
    pub fn deinit(self: *Response) void {
        std.debug.print("DEBUG: Deinitializing response\n", .{});
        var iterator = self.headers.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }

        self.headers.deinit();

        if (self.body) |body| {
            self.allocator.free(body);
        }

        std.debug.print("DEBUG: Deinitialized response\n", .{});
    }
};

// TODO: move this to asgi/protocol.zig when figure out how to handle dependencies
// ASGI Scope representation
pub const AsgiScope = struct {
    // Use a string hash map to represent the scope dictionary
    scope: std.StringHashMap([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) AsgiScope {
        return AsgiScope{
            .scope = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    // OPTIMIZATION 1: Memory Management - Use object pools for ASGI scopes
    // OPTIMIZATION 6: Data Structure - Use more efficient scope representation
    /// Generate ASGI scope from an HTTP request
    pub fn fromRequest(allocator: Allocator, request: *const Request) !AsgiScope {
        var scope = AsgiScope.init(allocator);
        errdefer scope.deinit();

        // Required ASGI keys
        try scope.put("type", "http");
        try scope.put("asgi", "3.0");
        try scope.put("http_version", request.version[5..]); // Remove "HTTP/" prefix
        try scope.put("method", request.method);
        try scope.put("scheme", "http"); // Default, could be expanded to detect HTTPS

        // Path and query handling
        try scope.put("path", request.path);

        // Query string
        if (request.query) |query| {
            try scope.put("query_string", query);
        } else {
            try scope.put("query_string", "");
        }

        // Add headers
        var header_iterator = request.headers.iterator();
        while (header_iterator.next()) |entry| {
            const header_name = entry.key_ptr.*;
            const header_value = entry.value_ptr.*;

            // Convert header to lowercase with '_' prefix for ASGI convention
            var converted_name = try std.ArrayList(u8).initCapacity(allocator, header_name.len + 1);
            defer converted_name.deinit();

            converted_name.appendAssumeCapacity('_');
            for (header_name) |char| {
                converted_name.appendAssumeCapacity(std.ascii.toLower(char));
            }

            try scope.put(converted_name.items, header_value);
        }

        return scope;
    }

    /// Helper method to add a key-value pair to the scope
    fn put(self: *AsgiScope, key: []const u8, value: []const u8) !void {
        const key_dup = try self.allocator.dupe(u8, key);
        const value_dup = try self.allocator.dupe(u8, value);

        try self.scope.put(key_dup, value_dup);
    }

    /// Free all memory associated with the scope
    pub fn deinit(self: *AsgiScope) void {
        var iterator = self.scope.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.scope.deinit();
    }

    // OPTIMIZATION 6: Data Structure - Implement streaming JSON serialization
    pub fn toJsonValue(self: *const AsgiScope) !std.json.Value {
        // Create a JSON object
        var json_object = std.json.ObjectMap.init(self.allocator);
        errdefer json_object.deinit();

        // Iterate through the scope and add to JSON map
        var iterator = self.scope.iterator();
        while (iterator.next()) |entry| {
            try json_object.put(entry.key_ptr.*, .{ .string = entry.value_ptr.* });
        }

        // Convert the object map to a JSON value
        return std.json.Value{ .object = json_object };
    }
};

/// Handler function for HTTP requests
pub const HandlerFn = fn (allocator: Allocator, request: Request, response: *Response) anyerror!void;

/// Get the text representation of an HTTP status code
pub fn statusText(status: u16) []const u8 {
    return switch (status) {
        100 => "Continue",
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}
