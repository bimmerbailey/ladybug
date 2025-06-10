//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;

// Root file for the ladybug library
// This exports the library components that can be used by other applications

// HTTP Server with HTTP/2 components
pub const http = struct {
    pub const server = @import("http/server.zig");
    pub const h2_frames = @import("http/h2_frames.zig");
    pub const h2_streams = @import("http/h2_streams.zig");
    pub const hpack = @import("http/hpack.zig");

    // Re-export commonly used items from server
    pub const Server = server.Server;
    pub const Config = server.Config;
    pub const Request = server.Request;
    pub const Response = server.Response;
    pub const AsgiScope = server.AsgiScope;
    pub const parseRequest = server.parseRequest;
};

// ASGI protocol implementation
pub const asgi = struct {
    pub const protocol = @import("asgi/protocol.zig");
    pub const h2_integration = @import("asgi/h2_integration.zig");
};

// WebSocket support
pub const websocket = @import("websocket/server.zig");

// Python integration
pub const python = @import("python/integration.zig");

// CLI utilities
pub const cli = @import("cli/options.zig");

// Utility functions
pub const utils = @import("utils/common.zig");

// Functions for the library
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}
