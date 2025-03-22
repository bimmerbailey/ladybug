//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;

// Root file for the ladybug library
// This exports the library components that can be used by other applications

// HTTP Server
pub const http = @import("http/server.zig");

// ASGI protocol implementation
pub const asgi = @import("asgi/protocol.zig");

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
