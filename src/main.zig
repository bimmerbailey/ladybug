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

    // // Start listening
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

    // Accept and handle connections
    while (true) {
        const conn = server.accept() catch |err| {
            logger.err("Error accepting connection: {!}", .{err});
            continue;
        };

        // Copy the connection for the thread
        const conn_copy = try allocator.create(std.net.Server.Connection);
        conn_copy.* = conn;

        // Process the request in a separate thread
        const thread = try std.Thread.spawn(.{}, handleConnection, .{
            allocator, conn_copy, &logger,
        });
        thread.detach();
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

/// Handle an HTTP connection
fn handleConnection(allocator: std.mem.Allocator, connection: *std.net.Server.Connection, logger: *const utils.Logger) !void {
    // Make sure we clean up the connection and memory
    defer {
        connection.stream.close();
        allocator.destroy(connection);
    }

    logger.info("Handling HTTP connection", .{});
    // Parse the HTTP request
    var request = http.parseRequest(allocator, &connection.stream) catch |err| {
        std.debug.print("Error parsing HTTP request: {!}", .{err});
        return;
    };
    defer request.deinit();
    std.debug.print("\nParsed request\n", .{});

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

    var response_buffer: [1024]u8 = undefined;
    const response = try std.fmt.bufPrint(&response_buffer, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ response_body.len, response_body });

    // Send the response
    std.debug.print("DEBUG: Sending response\n", .{});
    _ = try connection.stream.writeAll(response);
}
