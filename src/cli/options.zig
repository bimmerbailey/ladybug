const std = @import("std");
const Allocator = std.mem.Allocator;

// UVICORN PARITY: Add missing CLI options (--env-file, --log-config, --date-header-field)
// UVICORN PARITY: Add HTTP/2 specific options (--h2, --http2-max-concurrent-streams)
// UVICORN PARITY: Add WebSocket options (--ws-ping-interval, --ws-ping-timeout, --ws-max-size)
// UVICORN PARITY: Add development options (--reload-include, --reload-exclude patterns)
/// CLI options for the server
pub const Options = struct {
    // Server options
    host: []const u8 = "127.0.0.1",
    port: u16 = 8000,
    uds: ?[]const u8 = null,
    fd: ?u32 = null,

    // Application loading
    app: []const u8 = "", // In format "module:attr"
    factory: bool = false,

    // Process options
    workers: u16 = 1,
    loop: []const u8 = "auto", // auto, asyncio, uvloop
    http: []const u8 = "auto", // auto, h11, httptools
    ws: []const u8 = "auto", // auto, websockets, wsproto
    lifespan: []const u8 = "auto", // auto, on, off
    interface: []const u8 = "asgi3", // asgi3, asgi2, wsgi

    // Development options
    reload: bool = false,
    reload_dirs: ?[][]const u8 = null,
    reload_includes: ?[][]const u8 = null,
    reload_excludes: ?[][]const u8 = null,

    // Server resource options
    limit_concurrency: ?u32 = null,
    limit_max_requests: ?u32 = null,
    backlog: u32 = 2048,
    timeout_keep_alive: u32 = 5,

    // SSL options
    ssl_keyfile: ?[]const u8 = null,
    ssl_certfile: ?[]const u8 = null,
    ssl_version: ?u32 = null,
    ssl_cert_reqs: u32 = 1, // ssl.CERT_OPTIONAL
    ssl_ca_certs: ?[]const u8 = null,
    ssl_ciphers: ?[]const u8 = null,

    // HTTP options
    root_path: ?[]const u8 = null,
    proxy_headers: bool = true,
    forwarded_allow_ips: ?[]const u8 = null,

    // Logging options
    log_level: []const u8 = "info",
    access_log: bool = true,
    use_colors: bool = true,

    /// Initialize options with default values
    pub fn init() Options {
        return Options{};
    }

    // UVICORN PARITY: Add parsing for all missing Uvicorn CLI options
    // UVICORN PARITY: Add validation for SSL certificate files and TLS options
    // UVICORN PARITY: Add support for configuration file loading (YAML/JSON)
    /// Parse command line arguments
    pub fn parseArgs(self: *Options, allocator: Allocator, args: []const []const u8) !void {
        var i: usize = 1; // Skip the program name
        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try self.printUsage(allocator);
                std.process.exit(0);
            } else if (std.mem.startsWith(u8, arg, "--host=")) {
                self.host = try allocator.dupe(u8, arg[7..]);
            } else if (std.mem.eql(u8, arg, "--host") and i + 1 < args.len) {
                i += 1;
                self.host = try allocator.dupe(u8, args[i]);
            } else if (std.mem.startsWith(u8, arg, "--port=")) {
                self.port = try std.fmt.parseInt(u16, arg[7..], 10);
            } else if (std.mem.eql(u8, arg, "--port") and i + 1 < args.len) {
                i += 1;
                self.port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.startsWith(u8, arg, "--workers=")) {
                self.workers = try std.fmt.parseInt(u16, arg[10..], 10);
            } else if (std.mem.eql(u8, arg, "--workers") and i + 1 < args.len) {
                i += 1;
                self.workers = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--reload")) {
                self.reload = true;
            } else if (std.mem.startsWith(u8, arg, "--reload-dir=")) {
                if (self.reload_dirs == null) {
                    self.reload_dirs = try allocator.alloc([]const u8, 1);
                    self.reload_dirs.?[0] = try allocator.dupe(u8, arg[13..]);
                } else {
                    const old_dirs = self.reload_dirs.?;
                    self.reload_dirs = try allocator.alloc([]const u8, old_dirs.len + 1);
                    for (old_dirs, 0..) |dir, index| {
                        self.reload_dirs.?[index] = dir;
                    }
                    self.reload_dirs.?[old_dirs.len] = try allocator.dupe(u8, arg[13..]);
                    allocator.free(old_dirs);
                }
            } else if (std.mem.eql(u8, arg, "--reload-dir") and i + 1 < args.len) {
                i += 1;
                if (self.reload_dirs == null) {
                    self.reload_dirs = try allocator.alloc([]const u8, 1);
                    self.reload_dirs.?[0] = try allocator.dupe(u8, args[i]);
                } else {
                    const old_dirs = self.reload_dirs.?;
                    self.reload_dirs = try allocator.alloc([]const u8, old_dirs.len + 1);
                    for (old_dirs, 0..) |dir, index| {
                        self.reload_dirs.?[index] = dir;
                    }
                    self.reload_dirs.?[old_dirs.len] = try allocator.dupe(u8, args[i]);
                    allocator.free(old_dirs);
                }
            } else if (std.mem.startsWith(u8, arg, "--log-level=")) {
                self.log_level = try allocator.dupe(u8, arg[12..]);
            } else if (std.mem.eql(u8, arg, "--log-level") and i + 1 < args.len) {
                i += 1;
                self.log_level = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--no-access-log")) {
                self.access_log = false;
            } else if (std.mem.eql(u8, arg, "--no-use-colors")) {
                self.use_colors = false;
            } else if (std.mem.startsWith(u8, arg, "--lifespan=")) {
                self.lifespan = try allocator.dupe(u8, arg[11..]);
            } else if (std.mem.eql(u8, arg, "--lifespan") and i + 1 < args.len) {
                i += 1;
                self.lifespan = try allocator.dupe(u8, args[i]);
            } else if (std.mem.startsWith(u8, arg, "--interface=")) {
                self.interface = try allocator.dupe(u8, arg[12..]);
            } else if (std.mem.eql(u8, arg, "--interface") and i + 1 < args.len) {
                i += 1;
                self.interface = try allocator.dupe(u8, args[i]);
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                // Assume it's the application
                self.app = try allocator.dupe(u8, arg);
            }
        }

        // Validate options
        if (self.app.len == 0) {
            std.debug.print("Error: No application specified.\n", .{});
            try self.printUsage(allocator);
            std.process.exit(1);
        }
    }

    // UVICORN PARITY: Add complete help text matching Uvicorn's CLI options
    // UVICORN PARITY: Add examples and better formatting for help output
    /// Print usage information
    pub fn printUsage(self: *Options, allocator: Allocator) !void {
        _ = self; // Mark as used (removing parameter would break existing call sites)
        _ = allocator; // Mark as used
        const stdout = std.io.getStdOut().writer();

        try stdout.writeAll(
            \\Usage: ladybug [OPTIONS] APP
            \\
            \\Arguments:
            \\  APP                         Application to run in format "module:attribute" (required)
            \\
            \\Options:
            \\  --host TEXT                 Bind socket to this host. [default: 127.0.0.1]
            \\  --port INTEGER              Bind socket to this port. [default: 8000]
            \\  --workers INTEGER           Number of worker processes. [default: 1]
            \\  --reload                    Enable auto-reload.
            \\  --reload-dir PATH           Specify directories to watch for file changes.
            \\  --log-level TEXT            Set log level. [default: info]
            \\  --no-access-log             Disable access log.
            \\  --no-use-colors             Don't use colors in logs.
            \\  --lifespan TEXT             Lifespan implementation. [default: auto]
            \\  --interface TEXT            Select ASGI3, ASGI2, or WSGI app. [default: asgi3]
            \\  -h, --help                  Show this help message and exit.
            \\
        );
    }

    /// Parse the application string into module and attribute
    pub fn parseApp(self: *const Options, allocator: Allocator) !struct { module: []const u8, attr: []const u8 } {
        var parts = std.mem.splitScalar(u8, self.app, ':');
        const module = parts.next() orelse {
            std.debug.print("Error: Invalid application format. Expected 'module:attribute'.\n", .{});
            std.process.exit(1);
        };

        const attr = parts.next() orelse {
            std.debug.print("Error: Invalid application format. Expected 'module:attribute'.\n", .{});
            std.process.exit(1);
        };

        return .{
            .module = try allocator.dupe(u8, module),
            .attr = try allocator.dupe(u8, attr),
        };
    }

    /// Clean up allocated resources
    pub fn deinit(self: *Options, allocator: Allocator) void {
        std.debug.print("Deinitializing options\n", .{});
        if (self.reload_dirs) |dirs| {
            for (dirs) |dir| {
                allocator.free(dir);
            }
            allocator.free(dirs);
        }

        if (self.reload_includes) |includes| {
            for (includes) |include| {
                allocator.free(include);
            }
            allocator.free(includes);
        }

        if (self.reload_excludes) |excludes| {
            for (excludes) |exclude| {
                allocator.free(exclude);
            }
            allocator.free(excludes);
        }

        allocator.free(self.app);
    }
};

// Tests for the Options module
test "Options initialization" {
    const options = Options.init();
    try std.testing.expectEqualStrings("127.0.0.1", options.host);
    try std.testing.expectEqual(@as(u16, 8000), options.port);
    try std.testing.expectEqual(@as(u16, 1), options.workers);
    try std.testing.expectEqualStrings("info", options.log_level);
    try std.testing.expect(options.access_log);
    try std.testing.expect(options.use_colors);
    try std.testing.expectEqualStrings("auto", options.lifespan);
    try std.testing.expectEqualStrings("asgi3", options.interface);
    try std.testing.expect(!options.reload);
}

test "Options.parseArgs basic functionality" {
    var options = Options.init();
    const allocator = std.testing.allocator;

    // Test arguments array
    const args = [_][]const u8{ "program_name", "--host=example.com", "--port=9000", "--workers=4", "--reload", "--log-level=debug", "module:app" };

    try options.parseArgs(allocator, &args);

    try std.testing.expectEqualStrings("example.com", options.host);
    try std.testing.expectEqual(@as(u16, 9000), options.port);
    try std.testing.expectEqual(@as(u16, 4), options.workers);
    try std.testing.expect(options.reload);
    try std.testing.expectEqualStrings("debug", options.log_level);
    try std.testing.expectEqualStrings("module:app", options.app);

    // Clean up
    options.deinit(allocator);
    allocator.free(options.host);
    allocator.free(options.log_level);
    allocator.free(options.app);
}

test "Options.parseApp functionality" {
    var options = Options.init();
    const allocator = std.testing.allocator;

    // Set app value directly for testing
    options.app = "module:attribute";

    const result = try options.parseApp(allocator);
    defer {
        allocator.free(result.module);
        allocator.free(result.attr);
    }

    try std.testing.expectEqualStrings("module", result.module);
    try std.testing.expectEqualStrings("attribute", result.attr);
}

test "Options with reload directories" {
    var options = Options.init();
    const allocator = std.testing.allocator;

    // Test arguments with reload directories
    const args = [_][]const u8{ "program_name", "--reload", "--reload-dir=src", "--reload-dir=tests", "module:app" };

    try options.parseArgs(allocator, &args);

    try std.testing.expect(options.reload);
    try std.testing.expect(options.reload_dirs != null);
    if (options.reload_dirs) |dirs| {
        try std.testing.expectEqual(@as(usize, 2), dirs.len);
        try std.testing.expectEqualStrings("src", dirs[0]);
        try std.testing.expectEqualStrings("tests", dirs[1]);
    }

    // Clean up
    options.deinit(allocator);
    allocator.free(options.app);
}
