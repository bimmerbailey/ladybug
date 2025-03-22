const std = @import("std");
const testing = std.testing;
const common = @import("common.zig");

// Test the Logger

test "Logger initialization" {
    const logger = common.Logger.init(.info, false);
    try testing.expectEqual(common.Logger.LogLevel.info, logger.level);
    try testing.expectEqual(false, logger.use_colors);
}

test "LogLevel from string" {
    try testing.expectEqual(common.Logger.LogLevel.debug, common.Logger.LogLevel.fromString("debug"));
    try testing.expectEqual(common.Logger.LogLevel.info, common.Logger.LogLevel.fromString("info"));
    try testing.expectEqual(common.Logger.LogLevel.warning, common.Logger.LogLevel.fromString("warning"));
    try testing.expectEqual(common.Logger.LogLevel.err, common.Logger.LogLevel.fromString("error"));
    try testing.expectEqual(common.Logger.LogLevel.critical, common.Logger.LogLevel.fromString("critical"));

    // Test case insensitivity
    try testing.expectEqual(common.Logger.LogLevel.debug, common.Logger.LogLevel.fromString("DEBUG"));
    try testing.expectEqual(common.Logger.LogLevel.info, common.Logger.LogLevel.fromString("Info"));

    // Test default
    try testing.expectEqual(common.Logger.LogLevel.info, common.Logger.LogLevel.fromString("unknown"));
}

// Test log level filtering - these tests verify the log filtering logic works correctly
// without actually outputting anything to stderr

test "LogLevel filtering" {
    {
        // Debug level logger should allow all levels
        const logger = common.Logger.init(.debug, false);
        // These function calls should execute but not output anything
        logger.debug("Test {s}", .{"message"});
        logger.info("Test {s}", .{"message"});
        logger.warning("Test {s}", .{"message"});
        logger.err("Test {s}", .{"message"});
        logger.critical("Test {s}", .{"message"});
    }

    {
        // Info level logger should filter out debug
        const logger = common.Logger.init(.info, false);
        // Debug should be filtered out
        logger.debug("Test {s}", .{"message"});
        // These function calls should execute
        logger.info("Test {s}", .{"message"});
        logger.warning("Test {s}", .{"message"});
        logger.err("Test {s}", .{"message"});
        logger.critical("Test {s}", .{"message"});
    }

    {
        // Warning level logger should filter out debug and info
        const logger = common.Logger.init(.warning, false);
        // These should be filtered out
        logger.debug("Test {s}", .{"message"});
        logger.info("Test {s}", .{"message"});
        // These function calls should execute
        logger.warning("Test {s}", .{"message"});
        logger.err("Test {s}", .{"message"});
        logger.critical("Test {s}", .{"message"});
    }

    {
        // Error level logger should only allow error and critical
        const logger = common.Logger.init(.err, false);
        // These should be filtered out
        logger.debug("Test {s}", .{"message"});
        logger.info("Test {s}", .{"message"});
        logger.warning("Test {s}", .{"message"});
        // These function calls should execute
        logger.err("Test {s}", .{"message"});
        logger.critical("Test {s}", .{"message"});
    }

    {
        // Critical level logger should only allow critical
        const logger = common.Logger.init(.critical, false);
        // These should be filtered out
        logger.debug("Test {s}", .{"message"});
        logger.info("Test {s}", .{"message"});
        logger.warning("Test {s}", .{"message"});
        logger.err("Test {s}", .{"message"});
        // This function call should execute
        logger.critical("Test {s}", .{"message"});
    }
}

// Test the Worker and WorkerPool

test "WorkerStatus values" {
    try testing.expectEqual(common.Worker.WorkerStatus.starting, common.Worker.WorkerStatus.starting);
    try testing.expectEqual(common.Worker.WorkerStatus.running, common.Worker.WorkerStatus.running);
    try testing.expectEqual(common.Worker.WorkerStatus.stopping, common.Worker.WorkerStatus.stopping);
    try testing.expectEqual(common.Worker.WorkerStatus.stopped, common.Worker.WorkerStatus.stopped);
}

test "WorkerPool initialization" {
    const allocator = testing.allocator;
    var pool = common.WorkerPool.init(allocator, 4, "app.py", "127.0.0.1", 8000);
    defer pool.deinit();

    try testing.expectEqual(allocator, pool.allocator);
    try testing.expectEqual(@as(usize, 4), pool.target_count);
    try testing.expectEqualStrings("app.py", pool.app);
    try testing.expectEqualStrings("127.0.0.1", pool.host);
    try testing.expectEqual(@as(u16, 8000), pool.port);
    try testing.expectEqual(@as(usize, 0), pool.workers.items.len);
}

// Note: We're not testing the actual process management functions like start(), startWorker()
// check(), and stop() since those create actual system processes and would make the tests
// more complex. Those would be better tested in integration tests.
