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
        try runMaster(allocator, &options, &logger);
    } else {
        try runWorker(allocator, &options, &logger, app_info.module, app_info.attr);
    }
}

/// Run as master process, managing worker processes
fn runMaster(allocator: std.mem.Allocator, options: *cli.Options, logger: *const utils.Logger) !void {
    logger.info("Running in master mode with {d} workers", .{options.workers});

    // Create worker pool
    var pool = utils.WorkerPool.init(allocator, options.workers, options.app, options.host, options.port);
    defer pool.deinit();

    // Start worker processes
    try pool.start();

    // Set up signal handling
    var sigterm_flag = false;
    var sigint_flag = false;

    const SignalHandler = struct {
        flag: *bool,

        fn handle(sig: c_int, handler_ptr: ?*anyopaque) callconv(.C) void {
            _ = sig;
            if (handler_ptr) |ptr| {
                // TODO: Fix this cast - the current implementation causes linter errors with argument count
                // We're expecting a pointer to the struct itself passed as opaque pointer in the signal handler
                const self = @as(*@This(), @ptrCast(ptr));
                self.flag.* = true;
            }
        }
    };

    // TODO: These handlers don't appear directly used in the code but are referenced indirectly by the signal system.
    // The handlers are stored in variables to maintain their lifetime for the duration of signal handling.
    var _term_handler = SignalHandler{ .flag = &sigterm_flag };
    var _int_handler = SignalHandler{ .flag = &sigint_flag };

    // Tell the compiler these variables are intentionally here, even if not directly referenced
    _ = &_term_handler;
    _ = &_int_handler;

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

    // Main loop
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
        try handleLifespan(allocator, app, logger);
    }

    // Handle connections
    while (true) {
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
fn handleLifespan(allocator: std.mem.Allocator, app: *python.c.PyObject, logger: *const utils.Logger) !void {
    logger.debug("Running lifespan protocol", .{});

    // Create message queues
    var to_app = asgi.MessageQueue.init(allocator);
    defer to_app.deinit();

    var from_app = asgi.MessageQueue.init(allocator);
    defer from_app.deinit();

    // Create scope
    const scope = try asgi.createLifespanScope(allocator);
    defer scope.deinit(allocator);

    // Create Python scope dict
    const py_scope = try python.createPyDict(allocator, scope);
    defer PyDecref(py_scope);

    // Create callables
    const receive = try python.createReceiveCallable(&to_app);
    defer PyDecref(receive);

    const send = try python.createSendCallable(&from_app);
    defer PyDecref(send);

    // Send startup message
    const startup_msg = try asgi.createLifespanStartupMessage(allocator);
    defer startup_msg.deinit(allocator);
    try to_app.push(startup_msg);

    // Call the application (don't wait for it to complete)
    const app_thread = try std.Thread.spawn(.{}, callAppLifespan, .{
        app, py_scope, receive, send, logger,
    });

    // Wait for startup.complete or startup.failed
    while (true) {
        var event = try from_app.receive();
        defer event.deinit(allocator);

        // Check event type
        const type_value = event.object.get("type") orelse continue;
        if (type_value != .string) continue;

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

    // Don't wait for the thread to complete - it will run for the lifetime of the application
    app_thread.detach();
}

/// Call the ASGI application for lifespan protocol
fn callAppLifespan(app: *python.c.PyObject, scope: *python.c.PyObject, receive: *python.c.PyObject, send: *python.c.PyObject, logger: *const utils.Logger) void {
    logger.debug("Calling ASGI application for lifespan", .{});

    python.callAsgiApplication(app, scope, receive, send) catch |err| {
        logger.err("Error calling ASGI application for lifespan: {!}", .{err});
    };
}

/// Handle an HTTP connection
fn handleConnection(allocator: std.mem.Allocator, connection: *std.net.Server.Connection, app: *python.c.PyObject, logger: *const utils.Logger) !void {
    // Make sure we clean up the connection and memory
    defer {
        connection.stream.close();
        allocator.destroy(connection);
    }

    // Parse the HTTP request
    const request = http.parseRequest(allocator, &connection.stream) catch |err| {
        logger.err("Error parsing HTTP request: {!}", .{err});
        return;
    };
    defer request.deinit();

    logger.debug("Received request: {s} {s}", .{ request.method, request.path });

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
    // TODO: These addresses are immutable after creation, but defined as var for potential future modifications
    const client_addr = try connection.address.getIp(allocator);
    const server_addr = [_]u8{ '1', '2', '7', '.', '0', '.', '0', '.', '1' };

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
        &server_addr,
        connection.address.getPort(),
        client_addr,
        connection.address.getPort(),
        request.method,
        request.path,
        request.query,
        headers_list.items,
    );
    defer scope.deinit(allocator);

    // Create Python objects for the ASGI interface
    const py_scope = try python.createPyDict(allocator, scope);
    defer PyDecref(py_scope);

    const receive = try python.createReceiveCallable(&to_app);
    defer PyDecref(receive);

    const send = try python.createSendCallable(&from_app);
    defer PyDecref(send);

    // Push initial http.request message
    const request_msg = try asgi.createHttpRequestMessage(allocator, null, false);
    defer request_msg.deinit(allocator);
    try to_app.push(request_msg);

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
        defer event.deinit(allocator);

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
            const more_body = event.object.get("more_body") orelse .{ .bool = false };
            if (more_body != .bool or !more_body.bool) {
                break;
            }
        }
    }
}

/// Handle a WebSocket connection
fn handleWebSocketConnection(allocator: std.mem.Allocator, connection: *std.net.Server.Connection, request: *const http.Request, app: *python.c.PyObject, logger: *const utils.Logger) !void {
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
    // TODO: These addresses are immutable after creation, but defined as var for potential future modifications
    const client_addr = try connection.address.getIp(allocator);
    const server_addr = [_]u8{ '1', '2', '7', '.', '0', '.', '0', '.', '1' };

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
        &server_addr,
        connection.address.getPort(),
        client_addr,
        connection.address.getPort(),
        request.path,
        request.query,
        headers_list.items,
    );
    defer scope.deinit(allocator);

    // Create Python objects
    const py_scope = try python.createPyDict(allocator, scope);
    defer PyDecref(py_scope);

    const receive = try python.createReceiveCallable(&to_app);
    defer PyDecref(receive);

    const send = try python.createSendCallable(&from_app);
    defer PyDecref(send);

    // Send connect message
    const connect_msg = try asgi.createWebSocketConnectMessage(allocator);
    defer connect_msg.deinit(allocator);
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
        defer app_event.deinit(allocator);

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
            const code_value = app_event.object.get("code") orelse .{ .integer = 1000 };
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
            const ws_message = ws_conn.receive() catch |err| {
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
                    defer msg.deinit(allocator);
                    try to_app.push(msg);
                },
                .binary => {
                    const msg = try asgi.createWebSocketReceiveMessage(allocator, null, ws_message.data);
                    defer msg.deinit(allocator);
                    try to_app.push(msg);
                },
                .close => {
                    const msg = try asgi.createWebSocketDisconnectMessage(allocator, 1000);
                    defer msg.deinit(allocator);
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
fn callAppWebSocket(app: *python.c.PyObject, scope: *python.c.PyObject, receive: *python.c.PyObject, send: *python.c.PyObject, logger: *const utils.Logger) void {
    logger.debug("Calling ASGI application for WebSocket", .{});

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
fn PyDecref(obj: *python.c.PyObject) void {
    python.c.Py_DECREF(obj);
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
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
