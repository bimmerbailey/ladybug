//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const print = std.debug.print;
const net = std.net;

pub fn main() !void {
    // Set up allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Choose a port - let's use 8080 to match what you're using
    const port: u16 = 8080;

    // Start listening
    const address = try std.net.Address.parseIp("127.0.0.1", port);
    var server = try address.listen(.{});
    std.debug.print("Server listening on http://127.0.0.1:{d}\n", .{port});

    // Accept and handle connections
    while (true) {
        // Accept a new connection
        const conn = try server.accept();

        // We need to allocate a persistent copy of the connection
        // that will survive until the thread is done with it
        const conn_copy = try allocator.create(std.net.Server.Connection);
        conn_copy.* = conn;

        // Process the request in a separate thread
        const thread = try std.Thread.spawn(.{}, handleHttpConnection, .{ allocator, conn_copy });
        thread.detach();
    }
}

fn handleHttpConnection(allocator: std.mem.Allocator, connection: *std.net.Server.Connection) !void {
    // Make sure we clean up the connection and the allocated memory
    defer {
        connection.stream.close();
        allocator.destroy(connection);
    }

    // Create a buffer for reading the request
    const buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(buffer);

    // Read the request
    const bytes_read = try connection.stream.read(buffer);
    if (bytes_read == 0) return;

    // Print the request to the console (for debugging)
    std.debug.print("Received request of {d} bytes\n", .{bytes_read});

    // Prepare a simple HTTP response with content length
    // The Content-Length header is important for browsers to know when the response is complete
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
    _ = try connection.stream.writeAll(response);

    // Debug info
    std.debug.print("Sent response of {d} bytes\n", .{response.len});
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

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("ladybug_lib");
