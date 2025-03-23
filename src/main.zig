//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const lib = @import("ladybug_lib");
const http = lib.http;
const asgi = lib.asgi;
const python = lib.python;
const cli = lib.cli;
const utils = lib.utils;
const builtin = @import("builtin");

pub fn main() !void {
    // Set up allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    var options = cli.Options.init();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try options.parseArgs(allocator, args);
    defer options.deinit(allocator);

    // Setup logging
    const log_level = utils.Logger.LogLevel.fromString(options.log_level);
    const logger = utils.Logger.init(log_level, options.use_colors);

    // Parse module:app string
    const app_info = try options.parseApp(allocator);
    defer {
        allocator.free(app_info.module);
        allocator.free(app_info.attr);
    }

    logger.info("Starting ladybug ASGI server...", .{});

    // Handle multi-worker mode
    if (options.workers > 1) {
        try runMaster(allocator, &options, &logger, app_info.module, app_info.attr);
    } else {
        try runWorker(allocator, &options, &logger, app_info.module, app_info.attr);
    }
}

const SignalHandler = struct {
    flag: *bool,

    fn handle(sig: c_int, handler_ptr: ?*anyopaque) callconv(.C) void {
        std.debug.print("DEBUG: Singal handler\n", .{});
        _ = sig;
        if (handler_ptr) |ptr| {
            const self = @as(*@This(), @ptrCast(ptr));
            self.flag.* = true; // Set the flag to true when the signal is received
        }
    }
};

/// Run as master process, managing worker processes
fn runMaster(allocator: std.mem.Allocator, options: *cli.Options, logger: *const utils.Logger, module_name: []const u8, app_name: []const u8) !void {
    logger.info("Running in master mode with {d} workers", .{options.workers});

    // Create worker pool
    var pool = utils.WorkerPool.init(allocator, options.workers, options.app, options.host, options.port);
    defer pool.deinit();

    // Start worker processes
    try pool.start();

    // Set up signal handling
    var sigterm_flag = false;
    var sigint_flag = false;

    var _term_handler = SignalHandler{ .flag = &sigterm_flag };
    var _int_handler = SignalHandler{ .flag = &sigint_flag };

    // Tell the compiler these variables are intentionally here, even if not directly referenced
    _ = &_term_handler;
    _ = &_int_handler;

    if (builtin.os.tag != .macos and builtin.os.tag != .darwin) {
        std.debug.print("DEBUG: Setting up signal handlers\n", .{});
        // On Linux and other Unix systems, use sigaction
        _ = std.os.sigaction(std.os.SIG.TERM, &.{
            .handler = .{ .handler = SignalHandler.handle },
            .mask = std.os.empty_sigset,
            .flags = 0,
        }, null);

        _ = std.os.sigaction(std.os.SIG.INT, &.{
            .handler = .{ .handler = SignalHandler.handle },
            .mask = std.os.empty_sigset,
            .flags = 0,
        }, null);
    } else {
        // On macOS, just print a message
        std.debug.print("DEBUG: Shutting down hopefulyy\n", .{});
        logger.info("Signal handling limited on macOS. Use Ctrl+C to exit.", .{});
    }

    // Main loop
    try runWorker(allocator, options, logger, module_name, app_name);
    while (!sigterm_flag and !sigint_flag) {
        try pool.check();
        std.time.sleep(500 * std.time.ns_per_ms); // 500ms
    }

    // Stop worker processes
    logger.info("Shutting down...", .{});
    pool.stop();
}

/// Run as worker process, handling connections
fn runWorker(allocator: std.mem.Allocator, options: *cli.Options, logger: *const utils.Logger, module_name: []const u8, app_name: []const u8) !void {
    logger.info("Running worker process", .{});

    // Initialize Python interpreter
    try python.initialize();
    defer python.finalize();

    // Load ASGI application
    logger.info("Loading ASGI application from {s}:{s}", .{ module_name, app_name });
    const app = try python.loadApplication(module_name, app_name);
    defer PyDecref(app);

    // Create HTTP server
    const server_config = http.Config{
        .host = options.host,
        .port = options.port,
    };

    var server = http.Server.init(allocator, server_config);
    defer server.stop();

    // Start the server
    try server.start();
    logger.info("Listening on http://{s}:{d}", .{ server_config.host, server_config.port });

    // Run the lifespan protocol if enabled
    if (!std.mem.eql(u8, options.lifespan, "off")) {
        std.debug.print("\nDEBUG: Running lifespan protocol\n", .{});
        try handleLifespan(allocator, app, logger);
        std.debug.print("\nDEBUG: Lifespan protocol complete\n", .{});
    }

    // Set up signal handling
    var sigterm_flag = false;
    var sigint_flag = false;

    var _term_handler = SignalHandler{ .flag = &sigterm_flag };
    var _int_handler = SignalHandler{ .flag = &sigint_flag };

    _ = &_term_handler;
    _ = &_int_handler;

    if (builtin.os.tag != .macos and builtin.os.tag != .darwin) {
        std.debug.print("DEBUG: Setting up signal handlers\n", .{});
        // On Linux and other Unix systems, use sigaction
        _ = std.os.sigaction(std.os.SIG.TERM, &.{
            .handler = .{ .handler = SignalHandler.handle },
            .mask = std.os.empty_sigset,
            .flags = 0,
        }, null);

        _ = std.os.sigaction(std.os.SIG.INT, &.{
            .handler = .{ .handler = SignalHandler.handle },
            .mask = std.os.empty_sigset,
            .flags = 0,
        }, null);
    } else {
        // On macOS, just print a message
        std.debug.print("DEBUG: Shutting down hopefulyy\n", .{});
        logger.info("Signal handling limited on macOS. Use Ctrl+C to exit.", .{});
    }

    std.debug.print("\nDEBUG: Starting connection loop\n", .{});
    // Handle connections
    while (!sigterm_flag and !sigint_flag) {
        // Accept a new connection
        const conn = server.accept() catch |err| {
            logger.err("Error accepting connection: {!}", .{err});
            continue;
        };

        // Copy the connection for the thread
        const conn_copy = try allocator.create(std.net.Server.Connection);
        conn_copy.* = conn;

        // Process the request in a separate thread
        const thread = try std.Thread.spawn(.{}, handleConnection, .{
            allocator, conn_copy, app, logger,
        });
        thread.detach();
    }
}

/// Handle the lifespan protocol for startup/shutdown events
fn handleLifespan(allocator: std.mem.Allocator, app: *python.PyObject, logger: *const utils.Logger) !void {
    logger.debug("Running lifespan protocol", .{});

    std.debug.print("DEBUG: Creating message queues\n", .{});
    // Create message queues
    var to_app = asgi.MessageQueue.init(allocator);
    defer to_app.deinit();

    std.debug.print("DEBUG: Creating from_app message queue\n", .{});
    var from_app = asgi.MessageQueue.init(allocator);
    defer from_app.deinit();

    std.debug.print("DEBUG: Creating scope\n", .{});
    // Create scope
    const scope = try asgi.createLifespanScope(allocator);
    defer asgi.jsonValueDeinit(scope, allocator);

    std.debug.print("DEBUG: Creating Python scope dict\n", .{});
    // Create Python scope dict
    const py_scope = try python.createPyDict(allocator, scope);
    defer PyDecref(py_scope);

    std.debug.print("DEBUG: Creating receive callable\n", .{});
    // Create callables
    const receive = try python.createReceiveCallable(&to_app);
    defer PyDecref(receive);

    std.debug.print("DEBUG: Creating send callable\n", .{});
    const send = try python.createSendCallable(&from_app);
    defer PyDecref(send);

    std.debug.print("DEBUG: Creating startup message\n", .{});
    // Send startup message
    const startup_msg = try asgi.createLifespanStartupMessage(allocator);
    defer asgi.jsonValueDeinit(startup_msg, allocator);
    try to_app.push(startup_msg);

    std.debug.print("DEBUG: Creating app thread\n", .{});
    // Call the application (don't wait for it to complete)
    const app_thread = try std.Thread.spawn(.{}, callAppLifespan, .{
        app, py_scope, receive, send, logger,
    });

    std.debug.print("DEBUG: Waiting for startup event\n", .{});
    // Wait for startup.complete or startup.failed
    while (true) {
        std.debug.print("DEBUG: Waiting for event in loop\n", .{});
        var event = try from_app.receive();
        std.debug.print("DEBUG: Received event\n", .{});
        defer asgi.jsonValueDeinit(event, allocator);

        // Check event type
        std.debug.print("DEBUG: Checking event type\n", .{});
        const type_value = event.object.get("type") orelse continue;
        if (type_value != .string) continue;

        std.debug.print("DEBUG: Event type: {s}\n", .{type_value.string});
        if (std.mem.eql(u8, type_value.string, "lifespan.startup.complete")) {
            logger.info("Lifespan startup complete", .{});
            break;
        } else if (std.mem.eql(u8, type_value.string, "lifespan.startup.failed")) {
            logger.err("Lifespan startup failed", .{});
            const message = event.object.get("message") orelse continue;
            if (message == .string) {
                logger.err("Reason: {s}", .{message.string});
            }
            break;
        }
    }

    std.debug.print("\nDEBUG: Lifespan protocol at end\n", .{});
    // Don't wait for the thread to complete - it will run for the lifetime of the application
    app_thread.detach();
}

/// Call the ASGI application for lifespan protocol
fn callAppLifespan(app: *python.PyObject, scope: *python.PyObject, receive: *python.PyObject, send: *python.PyObject, logger: *const utils.Logger) void {
    std.debug.print("\nDEBUG: Calling ASGI application from callAppLifespan app\n\n", .{});
    // if (scope == null or receive == null or send == null) {
    //     std.debug.print("DEBUG: Something is null in callAppLifespan\n", .{});
    //     std.debug.print("DEBUG: App is null\n", .{});
    // }
    python.callAsgiApplication(app, scope, receive, send) catch |err| {
        std.debug.print("DEBUG: Error calling ASGI application for lifespan: {!}\n", .{err});
        logger.err("Error calling ASGI application for lifespan: {!}", .{err});
    };
}

/// Handle an HTTP connection
fn handleConnection(allocator: std.mem.Allocator, connection: *std.net.Server.Connection, app: *python.PyObject, logger: *const utils.Logger) !void {
    // Make sure we clean up the connection and memory
    defer {
        connection.stream.close();
        allocator.destroy(connection);
    }

    // Parse the HTTP request
    var request = http.parseRequest(allocator, &connection.stream) catch |err| {
        std.debug.print("Error parsing HTTP request: {!}", .{err});
        return;
    };
    defer request.deinit();

    std.debug.print("Received request: {s} {s}", .{ request.method, request.path });

    // Check if it's a WebSocket upgrade request
    if (isWebSocketUpgrade(&request)) {
        try handleWebSocketConnection(allocator, connection, &request, app, logger);
        return;
    }

    // Create message queues for communication
    var to_app = asgi.MessageQueue.init(allocator);
    defer to_app.deinit();

    var from_app = asgi.MessageQueue.init(allocator);
    defer from_app.deinit();

    // Extract client and server addresses
    // Simple approach to avoid union type issues
    const client_addr = try allocator.dupe(u8, "127.0.0.1");
    defer allocator.free(client_addr);
    const server_addr = try allocator.dupe(u8, "127.0.0.1");
    defer allocator.free(server_addr);

    // Convert headers to ASGI format
    var headers_list = std.ArrayList([2][]const u8).init(allocator);
    defer headers_list.deinit();

    var headers_iter = request.headers.iterator();
    while (headers_iter.next()) |header| {
        try headers_list.append([2][]const u8{
            try allocator.dupe(u8, std.ascii.lowerString(allocator.alloc(u8, header.key_ptr.len) catch continue, header.key_ptr.*)),
            try allocator.dupe(u8, header.value_ptr.*),
        });
    }

    // Create ASGI scope
    const scope = try asgi.createHttpScope(
        allocator,
        server_addr,
        connection.address.getPort(),
        client_addr,
        connection.address.getPort(),
        request.method,
        request.path,
        request.query,
        headers_list.items,
    );
    defer asgi.jsonValueDeinit(scope, allocator);

    // Create Python objects for the ASGI interface
    const py_scope = try python.createPyDict(allocator, scope);
    defer PyDecref(py_scope);

    const receive = try python.createReceiveCallable(&to_app);
    defer PyDecref(receive);

    const send = try python.createSendCallable(&from_app);
    defer PyDecref(send);

    // Push initial http.request message
    const request_msg = try asgi.createHttpRequestMessage(allocator, null, false);
    defer asgi.jsonValueDeinit(request_msg, allocator);
    try to_app.push(request_msg);

    std.debug.print("\nDEBUG: Calling ASGI application from handleConnection\n", .{});
    // Call ASGI application
    try python.callAsgiApplication(app, py_scope, receive, send);

    // Process response events from the application
    var response_started = false;
    var status: u16 = 200;
    var response_headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var headers_iterator = response_headers.iterator();
        while (headers_iterator.next()) |header| {
            allocator.free(header.key_ptr.*);
            allocator.free(header.value_ptr.*);
        }
        response_headers.deinit();
    }

    while (true) {
        const event = try from_app.receive();
        defer asgi.jsonValueDeinit(event, allocator);

        const type_value = event.object.get("type") orelse continue;
        if (type_value != .string) continue;

        if (std.mem.eql(u8, type_value.string, "http.response.start")) {
            response_started = true;

            // Get status code
            const status_value = event.object.get("status") orelse continue;
            if (status_value == .integer) {
                status = @intCast(status_value.integer);
            }

            // Get headers
            const headers_value = event.object.get("headers") orelse continue;
            if (headers_value != .array) continue;

            for (headers_value.array.items) |header| {
                if (header != .array or header.array.items.len != 2) continue;

                const name = header.array.items[0];
                const value = header.array.items[1];

                if (name != .string or value != .string) continue;

                const name_str = try allocator.dupe(u8, name.string);
                const value_str = try allocator.dupe(u8, value.string);

                try response_headers.put(name_str, value_str);
            }
        } else if (std.mem.eql(u8, type_value.string, "http.response.body")) {
            if (!response_started) {
                logger.err("Received http.response.body before http.response.start", .{});
                continue;
            }

            // Get body content
            const body_value = event.object.get("body") orelse continue;
            if (body_value != .string) continue;

            // Send response
            var response = http.Response.init(allocator);
            defer response.deinit();

            response.status = status;

            // Copy headers
            var headers_it = response_headers.iterator();
            while (headers_it.next()) |header| {
                try response.setHeader(header.key_ptr.*, header.value_ptr.*);
            }

            // Set body
            try response.setBody(body_value.string);

            // Send to client
            try response.send(&connection.stream);

            // Check if more body chunks are coming
            const more_body = event.object.get("more_body") orelse std.json.Value{ .bool = false };
            if (more_body != .bool or !more_body.bool) {
                break;
            }
        }
    }
}

/// Handle a WebSocket connection
fn handleWebSocketConnection(allocator: std.mem.Allocator, connection: *std.net.Server.Connection, request: *const http.Request, app: *python.PyObject, logger: *const utils.Logger) !void {
    logger.debug("Handling WebSocket connection", .{});

    // Perform WebSocket handshake
    var ws_conn = try lib.websocket.handshake(allocator, connection.stream, request.headers);
    defer ws_conn.close();

    // Create message queues
    var to_app = asgi.MessageQueue.init(allocator);
    defer to_app.deinit();

    var from_app = asgi.MessageQueue.init(allocator);
    defer from_app.deinit();

    // Extract client and server addresses
    // Simple approach to avoid union type issues
    const client_addr = try allocator.dupe(u8, "127.0.0.1");
    defer allocator.free(client_addr);
    const server_addr = try allocator.dupe(u8, "127.0.0.1");
    defer allocator.free(server_addr);

    // Convert headers to ASGI format
    var headers_list = std.ArrayList([2][]const u8).init(allocator);
    defer headers_list.deinit();

    var ws_headers_it = request.headers.iterator();
    while (ws_headers_it.next()) |header| {
        try headers_list.append([2][]const u8{
            try allocator.dupe(u8, std.ascii.lowerString(allocator.alloc(u8, header.key_ptr.len) catch continue, header.key_ptr.*)),
            try allocator.dupe(u8, header.value_ptr.*),
        });
    }

    // Create ASGI scope
    const scope = try asgi.createWebSocketScope(
        allocator,
        server_addr,
        connection.address.getPort(),
        client_addr,
        connection.address.getPort(),
        request.path,
        request.query,
        headers_list.items,
    );
    defer asgi.jsonValueDeinit(scope, allocator);

    // Create Python objects
    const py_scope = try python.createPyDict(allocator, scope);
    defer PyDecref(py_scope);

    const receive = try python.createReceiveCallable(&to_app);
    defer PyDecref(receive);

    const send = try python.createSendCallable(&from_app);
    defer PyDecref(send);

    // Send connect message
    const connect_msg = try asgi.createWebSocketConnectMessage(allocator);
    defer asgi.jsonValueDeinit(connect_msg, allocator);
    try to_app.push(connect_msg);

    // Call ASGI application in a separate thread
    const app_thread = try std.Thread.spawn(.{}, callAppWebSocket, .{
        app, py_scope, receive, send, logger,
    });

    // Handle events
    var app_done = false;
    var client_done = false;

    while (!app_done and !client_done) {
        // Poll for app events
        const app_event = from_app.receive() catch {
            app_done = true;
            continue;
        };
        defer asgi.jsonValueDeinit(app_event, allocator);

        const type_value = app_event.object.get("type") orelse continue;
        if (type_value != .string) continue;

        if (std.mem.eql(u8, type_value.string, "websocket.accept")) {
            // App accepted the WebSocket - no action needed
            logger.debug("WebSocket connection accepted by app", .{});
        } else if (std.mem.eql(u8, type_value.string, "websocket.send")) {
            // App sent a message to the client
            const text = app_event.object.get("text");
            const bytes = app_event.object.get("bytes");

            if (text != null and text.? == .string) {
                try ws_conn.send(.text, text.?.string);
            } else if (bytes != null and bytes.? == .string) {
                try ws_conn.send(.binary, bytes.?.string);
            }
        } else if (std.mem.eql(u8, type_value.string, "websocket.close")) {
            // App closed the connection
            const code_value = app_event.object.get("code") orelse std.json.Value{ .integer = 1000 };
            const code: u16 = if (code_value == .integer) @intCast(code_value.integer) else 1000;

            // Send close frame
            var code_bytes: [2]u8 = undefined;
            code_bytes[0] = @intCast((code >> 8) & 0xFF);
            code_bytes[1] = @intCast(code & 0xFF);
            try ws_conn.send(.close, &code_bytes);

            app_done = true;
        }

        // Check for client messages if app is still running
        if (!app_done) {
            // We don't want to block indefinitely if there's no client message,
            // so we'll use a timeout or non-blocking approach
            var ws_message = ws_conn.receive() catch |err| {
                if (err == error.WouldBlock) {
                    // No message available yet, continue
                    continue;
                }

                // Connection closed or error
                client_done = true;
                continue;
            };
            defer ws_message.deinit();

            // Create and send the appropriate message to the app
            switch (ws_message.type) {
                .text => {
                    const msg = try asgi.createWebSocketReceiveMessage(allocator, ws_message.data, null);
                    defer asgi.jsonValueDeinit(msg, allocator);
                    try to_app.push(msg);
                },
                .binary => {
                    const msg = try asgi.createWebSocketReceiveMessage(allocator, null, ws_message.data);
                    defer asgi.jsonValueDeinit(msg, allocator);
                    try to_app.push(msg);
                },
                .close => {
                    const msg = try asgi.createWebSocketDisconnectMessage(allocator, 1000);
                    defer asgi.jsonValueDeinit(msg, allocator);
                    try to_app.push(msg);
                    client_done = true;
                },
                .ping => {
                    // Automatically respond with pong
                    try ws_conn.send(.pong, ws_message.data);
                },
                .pong => {
                    // Ignore pong messages
                },
            }
        }
    }

    _ = app_thread.join();
}

/// Call the ASGI application for WebSocket handling
fn callAppWebSocket(app: *python.PyObject, scope: *python.PyObject, receive: *python.PyObject, send: *python.PyObject, logger: *const utils.Logger) void {
    logger.debug("Calling ASGI application for WebSocket", .{});

    std.debug.print("\nDEBUG: Calling ASGI application from callAppWebSocket\n", .{});
    python.callAsgiApplication(app, scope, receive, send) catch |err| {
        logger.err("Error calling ASGI application for WebSocket: {!}", .{err});
    };
}

/// Check if a request is a WebSocket upgrade request
fn isWebSocketUpgrade(request: *const http.Request) bool {
    const upgrade = request.headers.get("Upgrade") orelse return false;
    const connection = request.headers.get("Connection") orelse return false;
    const websocket_key = request.headers.get("Sec-WebSocket-Key") orelse return false;

    return std.ascii.eqlIgnoreCase(upgrade, "websocket") and
        std.mem.indexOf(u8, connection, "upgrade") != null and
        websocket_key.len > 0;
}

/// Decrease the reference count of a Python object
fn PyDecref(obj: *python.PyObject) void {
    std.debug.print("DEBUG: Decrefing object: {*}\n", .{obj});
    python.decref(obj);
}

test "simple test" {
    try std.testing.expectEqual(@as(i32, 42), 42);
}

test "use other module" {
    try std.testing.expectEqual(@as(i32, 150), lib.add(100, 50));
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
