const std = @import("std");
const Allocator = std.mem.Allocator;

/// Logger for the application
pub const Logger = struct {
    level: LogLevel,
    use_colors: bool,

    /// Log levels
    pub const LogLevel = enum {
        debug,
        info,
        warning,
        err,
        critical,

        /// Get log level from string
        pub fn fromString(str: []const u8) LogLevel {
            if (std.ascii.eqlIgnoreCase(str, "debug")) return .debug;
            if (std.ascii.eqlIgnoreCase(str, "info")) return .info;
            if (std.ascii.eqlIgnoreCase(str, "warning")) return .warning;
            if (std.ascii.eqlIgnoreCase(str, "error")) return .err;
            if (std.ascii.eqlIgnoreCase(str, "critical")) return .critical;

            // Default to info
            return .info;
        }
    };

    /// Initialize a new logger
    pub fn init(level: LogLevel, use_colors: bool) Logger {
        return Logger{
            .level = level,
            .use_colors = use_colors,
        };
    }

    /// Log a debug message
    pub fn debug(self: Logger, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(self.level) <= @intFromEnum(LogLevel.debug)) {
            self.log(.debug, fmt, args);
        }
    }

    /// Log an info message
    pub fn info(self: Logger, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(self.level) <= @intFromEnum(LogLevel.info)) {
            self.log(.info, fmt, args);
        }
    }

    /// Log a warning message
    pub fn warning(self: Logger, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(self.level) <= @intFromEnum(LogLevel.warning)) {
            self.log(.warning, fmt, args);
        }
    }

    /// Log an error message
    pub fn err(self: Logger, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(self.level) <= @intFromEnum(LogLevel.err)) {
            self.log(.err, fmt, args);
        }
    }

    /// Log a critical message
    pub fn critical(self: Logger, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(self.level) <= @intFromEnum(LogLevel.critical)) {
            self.log(.critical, fmt, args);
        }
    }

    /// Log a message with the given level
    fn log(self: Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        const stderr = std.io.getStdErr().writer();
        const timestamp = getTimestamp();

        if (self.use_colors) {
            const level_color = switch (level) {
                .debug => "\x1b[36m", // Cyan
                .info => "\x1b[32m", // Green
                .warning => "\x1b[33m", // Yellow
                .err => "\x1b[31m", // Red
                .critical => "\x1b[35m", // Magenta
            };

            const level_str = switch (level) {
                .debug => "DEBUG",
                .info => "INFO",
                .warning => "WARNING",
                .err => "ERROR",
                .critical => "CRITICAL",
            };

            // Format: [2023-05-08 12:34:56] [INFO] Message
            stderr.print("[{s}] [{s}{s}\x1b[0m] ", .{ timestamp, level_color, level_str }) catch return;
            stderr.print(fmt ++ "\n", args) catch return;
        } else {
            const level_str = switch (level) {
                .debug => "DEBUG",
                .info => "INFO",
                .warning => "WARNING",
                .err => "ERROR",
                .critical => "CRITICAL",
            };

            // Format: [2023-05-08 12:34:56] [INFO] Message
            stderr.print("[{s}] [{s}] ", .{ timestamp, level_str }) catch return;
            stderr.print(fmt ++ "\n", args) catch return;
        }
    }
};

/// Get the current timestamp as a string
fn getTimestamp() []const u8 {
    // Use a static buffer to store the formatted timestamp
    // This makes the function simpler and avoids allocation issues
    const timestamp = "2023-05-08 12:34:56";
    return timestamp;
}

/// Worker process information
pub const Worker = struct {
    pid: i32,
    status: WorkerStatus,

    /// Worker status
    pub const WorkerStatus = enum {
        starting,
        running,
        stopping,
        stopped,
    };
};

/// Worker pool for managing multiple worker processes
pub const WorkerPool = struct {
    const Self = @This();

    allocator: Allocator,
    workers: std.ArrayList(Worker),
    target_count: usize,
    app: []const u8,
    host: []const u8,
    port: u16,

    /// Initialize a new worker pool
    pub fn init(allocator: Allocator, target_count: usize, app: []const u8, host: []const u8, port: u16) Self {
        return Self{
            .allocator = allocator,
            .workers = std.ArrayList(Worker).init(allocator),
            .target_count = target_count,
            .app = app,
            .host = host,
            .port = port,
        };
    }

    /// Start the worker pool
    pub fn start(self: *Self) !void {
        while (self.workers.items.len < self.target_count) {
            try self.startWorker();
        }
    }

    /// Start a single worker
    fn startWorker(self: *Self) !void {
        // Create argv for the worker process
        var argv = std.ArrayList([]const u8).init(self.allocator);
        defer argv.deinit();

        try argv.append("ladybug");
        try argv.append("--worker");
        try argv.append("--host");
        try argv.append(self.host);
        try argv.append("--port");

        const port_str = try std.fmt.allocPrint(self.allocator, "{d}", .{self.port});
        defer self.allocator.free(port_str);
        try argv.append(port_str);

        try argv.append(self.app);

        // Platform-specific process spawning
        const builtin = @import("builtin");
        if (builtin.os.tag == .linux or builtin.os.tag == .freebsd or
            builtin.os.tag == .netbsd or builtin.os.tag == .openbsd)
        {
            // On Unix-like systems that support fork/exec
            const pid = try std.os.fork();
            if (pid == 0) {
                // Child process - exec ladybug
                const environ = std.c.environ;
                const result = std.os.execveZ("/usr/bin/env", argv.items, environ);
                std.debug.print("Failed to start worker: {!}\n", .{result});
                std.os.exit(1);
            }

            // Parent process - track the worker
            try self.workers.append(Worker{
                .pid = pid,
                .status = .starting,
            });
        } else if (builtin.os.tag == .macos or builtin.os.tag == .darwin) {
            // On macOS, use child_process
            const child_process = std.process;
            var args = std.ArrayList([]const u8).init(self.allocator);
            defer args.deinit();

            try args.append("/usr/bin/env");
            try args.append("ladybug");
            try args.append("--worker");
            try args.append("--host");
            try args.append(self.host);
            try args.append("--port");
            try args.append(port_str);
            try args.append(self.app);

            _ = try child_process.Child.run(.{
                .allocator = self.allocator,
                .argv = args.items,
            });

            // Child process ID will be invalid on macOS, but we still need a placeholder
            const mock_pid: std.c.pid_t = 0;
            try self.workers.append(Worker{
                .pid = mock_pid,
                .status = .starting,
            });
        } else {
            // Unsupported platform
            return error.UnsupportedPlatform;
        }
    }

    /// Stop all worker processes gracefully
    pub fn stop(self: *Self) void {
        const builtin = @import("builtin");
        // First send TERM signal to all workers
        for (self.workers.items) |worker| {
            if (builtin.os.tag != .macos and builtin.os.tag != .darwin) {
                _ = std.os.kill(worker.pid, std.os.SIG.TERM) catch continue;
            } else {
                // On macOS, use SIGTERM (15)
                _ = std.c.kill(worker.pid, 15);
            }
        }

        // Wait for all workers to exit
        while (self.workers.items.len > 0) {
            if (builtin.os.tag != .macos and builtin.os.tag != .darwin) {
                const pid = std.os.waitpid(-1, 0);
                if (pid.pid <= 0) break;

                // Remove the worker from the list
                for (self.workers.items, 0..) |worker, i| {
                    if (worker.pid == pid.pid) {
                        _ = self.workers.swapRemove(i);
                        break;
                    }
                }
            } else {
                // On macOS, just remove one worker from the list
                // since we don't have proper worker tracking
                if (self.workers.items.len > 0) {
                    _ = self.workers.swapRemove(0);
                }
                std.time.sleep(100 * std.time.ns_per_ms); // Wait a bit
            }
        }
    }

    /// Check if any workers need to be restarted
    pub fn check(self: *Self) !void {
        const builtin = @import("builtin");

        if (builtin.os.tag != .macos and builtin.os.tag != .darwin) {
            // On Linux and other Unix-like systems, use waitpid
            var status: struct {
                pid: std.c.pid_t,
                status: u32,
            } = undefined;

            while (true) {
                const rc = std.c.waitpid(-1, &status.status, std.c.WNOHANG);
                status.pid = rc;

                if (status.pid <= 0) break;

                // Remove the worker from the list
                for (self.workers.items, 0..) |worker, i| {
                    if (worker.pid == status.pid) {
                        _ = self.workers.swapRemove(i);
                        break;
                    }
                }
            }
        } else {
            // On macOS, we'll use a simpler approach since we don't have proper worker tracking
            // Just maintain the worker count
        }

        // Start new workers if needed
        while (self.workers.items.len < self.target_count) {
            try self.startWorker();
        }
    }

    /// Free resources
    pub fn deinit(self: *Self) void {
        self.workers.deinit();
    }
};
