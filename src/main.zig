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

// OPTIMIZATION 1: Memory Management - Use arena allocator for request-scoped allocations
// OPTIMIZATION 7: Compilation - Ensure this is compiled with ReleaseFast for production
// UVICORN PARITY: Add support for configuration files (YAML/JSON), environment file loading (.env)
// UVICORN PARITY: Add metrics collection and health check endpoints
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
        // TODO: Implement master process
        try runMaster(allocator, &options, &logger);
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

// OPTIMIZATION 10: Monitoring - Add performance metrics and health monitoring for master process
// UVICORN PARITY: Add graceful worker restarts, better signal handling for SIGTERM/SIGINT/SIGHUP
// UVICORN PARITY: Add worker health monitoring and automatic restart on failures
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

    // TODO: These handlers don't appear directly used in the code but are referenced indirectly by the signal system.
    // The handlers are stored in variables to maintain their lifetime for the duration of signal handling.
    var _term_handler = SignalHandler{ .flag = &sigterm_flag };
    var _int_handler = SignalHandler{ .flag = &sigint_flag };

    // Tell the compiler these variables are intentionally here, even if not directly referenced
    _ = &_term_handler;
    _ = &_int_handler;

    if (builtin.os.tag != .macos and builtin.os.tag != .darwin) {
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
        logger.info("Signal handling limited on macOS. Use Ctrl+C to exit.", .{});
        // We'll handle cleanup in the main loop with manual checks
    }

    // Main loop
    while (!sigterm_flag and !sigint_flag) {
        try pool.check();
        std.time.sleep(500 * std.time.ns_per_ms); // 500ms
    }

    // Stop worker processes
    logger.info("Shutting down...", .{});
    pool.stop();
}
// Global variable for signal handling
var global_shutdown_flag: bool = false;

const AnotherSignalHandler = struct {
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

// OPTIMIZATION 4: Python Integration - Optimize Python interpreter initialization and reuse
// OPTIMIZATION 5: Network I/O - Implement non-blocking I/O and connection pooling
// OPTIMIZATION 3: Concurrency - Improve worker process management and load balancing
// OPTIMIZATION 10: Monitoring - Remove debug prints from hot paths for production
// UVICORN PARITY: Add auto-reload functionality with file watching for development mode
// UVICORN PARITY: Add access logging with configurable formats and structured output
fn runWorker(allocator: std.mem.Allocator, options: *cli.Options, logger: *const utils.Logger, module_name: []const u8, app_name: []const u8) !void {
    std.debug.print("DEBUG: Running worker\n", .{});

    // Set up Python interpreter
    try python.base.initialize();
    defer python.base.finalize();

    // Create and set up the event loop
    const event_loop_ctx = try python.event_loop.createAndSetEventLoop();
    defer {
        python.event_loop.stopEventLoop(event_loop_ctx) catch |err| {
            logger.err("Error stopping event loop: {!}", .{err});
        };
    }

    // Load ASGI application
    logger.info("Loading ASGI application from {s}:{s}", .{ module_name, app_name });
    const app = try python.loadApplication(module_name, app_name);
    defer python.base.decref(app);

    logger.info("Starting ladybug ASGI server...", .{});

    // Create HTTP server
    const server_config = http.Config{
        .host = options.host,
        .port = options.port,
    };

    var server = http.Server.init(allocator, server_config);
    defer server.stop();

    const internal_handler = struct {
        fn internal_handler(sig: c_int) callconv(.C) void {
            // try python.event_loop.stopEventLoop(event_loop_ctx) catch |err| {
            //     logger.err("Error stopping event loop: {!}", .{err});
            // };
            std.debug.print("DEBUG: Received signal {}\n", .{sig});
            global_shutdown_flag = true;
            std.debug.print("DEBUG: Shutting down server, flag: {}\n", .{global_shutdown_flag});
        }
    }.internal_handler;

    const act = std.posix.Sigaction{
        .handler = .{ .handler = internal_handler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    // Start the server
    try server.start();
    logger.info("Listening on http://{s}:{d}", .{ server_config.host, server_config.port });

    std.debug.print("DEBUG: Should run lifespan protocol: {s}\n", .{options.lifespan});
    // Run the lifespan protocol if enabled
    if (!std.mem.eql(u8, options.lifespan, "off")) {
        std.debug.print("DEBUG: Starting lifespan protocol\n", .{});
        // TODO: Handle event loop?
        try handleLifespan(allocator, app, logger, event_loop_ctx.loop);
    }
    logger.info("Finished lifespan protocol\n", .{});

    // OPTIMIZATION 5: Network I/O - Replace blocking accept() with epoll/kqueue event loop
    // OPTIMIZATION 3: Concurrency - This main loop should dispatch to worker threads
    // Main server loop
    while (!global_shutdown_flag) {
        const conn = server.accept() catch |err| {
            switch (err) {
                error.WouldBlock => {
                    // No connection available, sleep briefly and check shutdown flag
                    std.time.sleep(10 * std.time.ns_per_ms); // 10ms sleep
                    continue;
                },
                else => {
                    logger.err("Error accepting connection: {!}", .{err});
                    continue;
                },
            }
        };

        if (global_shutdown_flag) {
            // TODO: send shutdown message to application
            break;
        }

        // Copy the connection for the thread
        const conn_copy = try allocator.create(std.net.Server.Connection);
        conn_copy.* = conn;

        // TODO: Handle event loop?
        try handleConnection(allocator, conn_copy, app, logger, event_loop_ctx.loop);
    }

    logger.info("Shutting down server...", .{});
}

// OPTIMIZATION 1: Memory Management - Use memory pools for connection objects
// OPTIMIZATION 2: HTTP Parsing - Implement zero-copy parsing and streaming
// OPTIMIZATION 4: Python Integration - Cache Python objects and reduce transitions
// OPTIMIZATION 8: Protocol-Specific - Optimize ASGI message handling
// UVICORN PARITY: Add WebSocket connection upgrade handling and protocol support
// UVICORN PARITY: Add HTTP/2 protocol support and connection multiplexing
// UVICORN PARITY: Add middleware chain execution for ASGI applications
// UVICORN PARITY: Add request/response logging and metrics collection
/// Handle an HTTP connection
fn handleConnection(allocator: std.mem.Allocator, connection: *std.net.Server.Connection, app: *python.PyObject, logger: *const utils.Logger, loop: *python.PyObject) !void {
    // Make sure we clean up the connection and memory
    defer {
        connection.stream.close();
        allocator.destroy(connection);
    }

    logger.info("Handling HTTP connection in app: {}", .{app});
    // Parse the HTTP request
    var request = http.parseRequest(allocator, &connection.stream) catch |err| {
        std.debug.print("Error parsing HTTP request: {!}", .{err});
        return;
    };
    defer request.deinit();
    std.debug.print("\nParsed request\n", .{});

    // Create message queues for communication
    var to_app = asgi.MessageQueue.init(allocator);
    defer to_app.deinit();

    var from_app = asgi.MessageQueue.init(allocator);
    defer from_app.deinit();

    // TODO: Get actual addresses
    // Extract client and server addresses
    // Simple approach to avoid union type issues
    const client_addr = try allocator.dupe(u8, "127.0.0.1");
    defer allocator.free(client_addr);
    const server_addr = try allocator.dupe(u8, "127.0.0.1");
    defer allocator.free(server_addr);

    // OPTIMIZATION 1: Memory Management - Avoid allocating for each header
    // OPTIMIZATION 6: Data Structure - Use more efficient header representation
    // Convert headers to ASGI format
    var headers_list = std.ArrayList([2][]const u8).init(allocator);
    defer {
        // Free each header key and value pair
        for (headers_list.items) |header| {
            allocator.free(header[0]);
            allocator.free(header[1]);
        }
        headers_list.deinit();
    }

    var headers_iter = request.headers.iterator();
    while (headers_iter.next()) |header| {
        const key_buf = try allocator.alloc(u8, header.key_ptr.len);
        _ = std.ascii.lowerString(key_buf, header.key_ptr.*);
        try headers_list.append([2][]const u8{
            key_buf,
            try allocator.dupe(u8, header.value_ptr.*),
        });
    }

    // Create ASGI scope
    var scope = try http.AsgiScope.fromRequest(allocator, &request);
    defer scope.deinit();

    // Create Python objects for the ASGI interface

    const jsonScope = try scope.toJsonValue();
    const py_scope = try python.base.jsonToPyObject(allocator, jsonScope);
    defer python.base.decref(py_scope);
    defer asgi.jsonValueDeinit(jsonScope, allocator);
    // Push initial http.request message
    try to_app.push(jsonScope);

    const receive = try python.create_receive_vectorcall_callable(&to_app, loop);
    defer python.base.decref(receive);

    const send = try python.create_send_vectorcall_callable(&from_app, loop);
    defer python.base.decref(send);

    std.debug.print("\nDEBUG: Calling ASGI application from handleConnection\n", .{});
    // Call ASGI application
    try python.callAsgiApplication(app, py_scope, receive, send, loop);

    // Send response
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

    // OPTIMIZATION 8: Protocol-Specific - Batch ASGI messages for better performance
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

// OPTIMIZATION 8: Protocol-Specific - Optimize lifespan protocol for faster startup
// UVICORN PARITY: Add proper error handling for lifespan startup/shutdown failures
// UVICORN PARITY: Add timeout handling for lifespan events
// UVICORN PARITY: Add graceful shutdown coordination with active connections
/// Handle the lifespan protocol for startup/shutdown events
fn handleLifespan(allocator: std.mem.Allocator, app: *python.PyObject, logger: *const utils.Logger, loop: *python.PyObject) !void {
    logger.debug("Running lifespan protocol", .{});

    // Create message queues
    var to_app = asgi.MessageQueue.init(allocator);
    defer to_app.deinit();

    var from_app = asgi.MessageQueue.init(allocator);
    defer from_app.deinit();

    std.debug.print("DEBUG: Creating lifespan scope\n", .{});
    // Create scope
    const scope = try asgi.createLifespanScope(allocator);
    defer asgi.jsonValueDeinit(scope, allocator);

    std.debug.print("DEBUG: Creating Python scope\n", .{});
    // Create Python scope dict
    const py_scope = try python.base.createPyDict(allocator, scope);
    defer python.base.decref(py_scope);

    std.debug.print("DEBUG: Creating receive callable\n", .{});
    // Create callables
    // const receive = try python.createReceiveCallable(&to_app);
    const receive = try python.create_receive_vectorcall_callable(&to_app, loop);
    defer python.base.decref(receive);

    std.debug.print("DEBUG: Creating send callable\n", .{});
    // const send = try python.createSendCallable(&from_app);
    const send = try python.create_send_vectorcall_callable(&from_app, loop);
    defer python.base.decref(send);

    std.debug.print("DEBUG: Creating startup message\n", .{});
    // Send startup message
    const startup_msg = try asgi.createLifespanStartupMessage(allocator);
    defer asgi.jsonValueDeinit(startup_msg, allocator);

    // Add the startup message to the queue BEFORE calling the application
    try to_app.push(startup_msg);
    std.debug.print("DEBUG: Pushed startup message to queue\n", .{});

    // Call the application (wait for it to complete)
    try python.callAsgiApplication(app, py_scope, receive, send, loop);
    logger.info("Finished calling lifespan", .{});

    // Wait for startup.complete or startup.failed
    while (true) {
        var event = try from_app.receive();
        defer asgi.jsonValueDeinit(event, allocator);

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
    std.debug.print("DEBUG: Lifespan complete\n", .{});
}

/// Call the ASGI application for lifespan protocol
// NOTE: ! return means it can "throw" an error
fn callAppLifespan(app: *python.PyObject, scope: *python.PyObject, receive: *python.PyObject, send: *python.PyObject, logger: *const utils.Logger) !void {
    logger.debug("Calling ASGI application for lifespan", .{});

    python.callAsgiApplication(app, scope, receive, send) catch |err| {
        logger.err("Error calling ASGI application for lifespan: {!}", .{err});
        return python.PythonError.RuntimeError;
    };
}
