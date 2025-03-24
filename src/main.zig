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

fn runWorker(allocator: std.mem.Allocator, options: *cli.Options, logger: *const utils.Logger, module_name: []const u8, app_name: []const u8) !void {
    std.debug.print("DEBUG: Running worker\n", .{});

    // Set up Python interpreter
    try python.initialize();
    defer python.finalize();

    // Load ASGI application
    logger.info("Loading ASGI application from {s}:{s}", .{ module_name, app_name });
    const app = try python.loadApplication(module_name, app_name);
    defer python.decref(app);

    const py_scope = try python.toPyString("Here we go");
    defer python.decref(py_scope);
    logger.info("Starting ladybug ASGI server...", .{});

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

    // TODO: If more than one worker use multiprocessing

    // Accept and handle connections
    while (true) {
        const conn = server.accept() catch |err| {
            logger.err("Error accepting connection: {!}", .{err});
            continue;
        };

        // Copy the connection for the thread
        const conn_copy = try allocator.create(std.net.Server.Connection);
        conn_copy.* = conn;

        try handleConnection(allocator, conn_copy, app, logger);
        // Process the request in a separate thread
        // const thread = try std.Thread.spawn(.{}, handleConnection, .{
        //     allocator, conn_copy, app, &logger,
        // });
        // thread.detach();
    }
}

/// Handle an HTTP connection
fn handleConnection(allocator: std.mem.Allocator, connection: *std.net.Server.Connection, app: *python.PyObject, logger: *const utils.Logger) !void {
    // IMPORTANT: Acquire the GIL before creating Python objects
    // const gil_state = python.PyGILState_Ensure();
    // defer python.PyGILState_Release(gil_state);

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
    var scope = try http.AsgiScope.fromRequest(allocator, &request);
    defer scope.deinit();

    // Create Python objects for the ASGI interface
    const jsonScope = try scope.toJsonValue();
    const py_scope = try python.jsonToPyObject(allocator, jsonScope);
    defer python.decref(py_scope);

    // Send response
    std.debug.print("DEBUG: Creating response\n", .{});
    var response = http.Response.init(allocator);
    defer response.deinit();
    const response_body =
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <title>Zig HTTP Server</title>
        \\</head>
        \\<body>
        \\    <h1>Hello from Zig!</h1>
        \\    <p>Your HTTP server is working on port 8080.</p>
        \\</body>
        \\</html>
    ;

    // TODO: This is a hack to get the content length
    var buf: [256]u8 = undefined;
    const length_str = try std.fmt.bufPrint(&buf, "{}", .{response_body.len});
    const status: u16 = 200;
    try response.setBody(response_body);
    try response.setHeader("Content-Type", "text/html");
    try response.setHeader("Content-Length", length_str);
    try response.setHeader("Connection", "close");
    response.status = status;

    // Send the response
    std.debug.print("DEBUG: Sending response\n", .{});
    try response.send(&connection.stream);
}
