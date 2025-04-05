const std = @import("std");
const Allocator = std.mem.Allocator;
const python = @import("python_wrapper");
const thread = std.Thread;
const base = @import("bases.zig");

const decref = base.decref;
const handlePythonError = base.handlePythonError;
const PythonError = base.PythonError;
const importModule = base.importModule;
const getAttribute = base.getAttribute;
const toPyString = base.toPyString;

// Import ASGI protocol module - use the module name defined in build.zig
const protocol = @import("protocol");

// Export the PyObject type for external use
pub const PyObject = python.og.PyObject;
const PyTypeObject = python.og.PyTypeObject;

pub fn is_loop_running(loop: *PyObject) bool {
    const is_running_cmd = try getAttribute(loop, "is_running");
    defer decref(is_running_cmd);

    const is_running = python.og.PyObject_CallObject(is_running_cmd, null);
    if (is_running == 0) {
        std.debug.print("DEBUG: Loop is not running\n", .{});
        return false;
    }
    std.debug.print("Loop is running {}\n", .{is_running.*});
    return true;
}

pub fn set_event_loop(loop: *PyObject) !void {
    const gil_state = python.og.PyGILState_Ensure();
    defer python.og.PyGILState_Release(gil_state);

    const module = try importModule("asyncio");
    defer decref(module);

    const func = try getAttribute(module, "set_event_loop");
    defer decref(func);

    const run_args = python.og.PyTuple_New(1);
    if (run_args == null) {
        handlePythonError();
        return PythonError.RuntimeError;
    }

    // PyTuple_SetItem steals the reference
    if (python.og.PyTuple_SetItem(run_args.?, 0, loop) < 0) {
        python.decref(run_args.?);
        handlePythonError();
        return PythonError.RuntimeError;
    }
    // TODO: Tuple for args that will take loop
    const called = python.og.PyObject_CallObject(func, run_args);
    if (called == 0) {
        std.debug.print("DEBUG: was not able to set loop\n", .{});
        handlePythonError();
        return PythonError.RuntimeError;
    }
    std.debug.print("INFO: Set event loop\n", .{});
}

pub fn start_python_event_loop(py_module: []const u8) !void {
    _ = try thread.spawn(.{}, create_event_loop, .{py_module});
}

pub fn create_event_loop(py_module: []const u8) !void {
    const module = try importModule(py_module);
    defer decref(module);

    const func = try getAttribute(module, "new_event_loop");
    defer decref(func);

    const loop = python.og.PyObject_CallObject(func, null);
    if (loop == 0) {
        std.debug.print("DEBUG: was not able to create loop\n", .{});
        // return python.og.Py_None();
    }

    try set_event_loop(loop);
    // std.debug.print("Getting event loop in create\n", .{});
    // const is_existing = try get_event_loop();
    // if (is_existing == python.zig_get_py_none()) {
    //     std.debug.print("Not able to get the event loop\n", .{});
    // }
    std.debug.print("INFO: Created event loop\n", .{});
    // return @as(*PyObject, loop);
}

pub fn get_event_loop() !*PyObject {
    // Import moduled
    const module = try importModule("asyncio");
    defer decref(module);

    const func = try getAttribute(@as(*PyObject, module), "get_running_loop");
    defer decref(func);

    const loop = python.og.PyObject_CallObject(func, null);
    if (loop == null) {
        std.debug.print("DEBUG: was not able to get loop\n", .{});
        return python.og.Py_None();
    }
    std.debug.print("INFO: Got event loop\n", .{});
    return @as(*PyObject, loop);
}

/// Structure to hold event loop and its thread
pub const EventLoopContext = struct {
    loop: *PyObject,
    thread: *PyObject,
};

/// Create and set up the Python event loop for ASGI applications
pub fn createAndSetEventLoop() !EventLoopContext {
    // Import asyncio
    const asyncio = try importModule("asyncio");
    defer python.decref(asyncio);

    // Create a new event loop
    const new_loop_func = try getAttribute(asyncio, "new_event_loop");
    defer python.decref(new_loop_func);

    const loop = python.og.PyObject_CallObject(new_loop_func, null);
    if (loop == null) {
        return PythonError.RuntimeError;
    }

    // Set it as the default loop
    const set_loop_func = try getAttribute(asyncio, "set_event_loop");
    defer python.decref(set_loop_func);

    const args = python.og.PyTuple_New(1);
    if (args == null) {
        python.decref(loop.?);
        return PythonError.RuntimeError;
    }
    defer python.decref(args.?);

    // PyTuple_SetItem steals a reference, so we need to incref
    python.incref(loop.?);
    if (python.og.PyTuple_SetItem(args.?, 0, loop.?) < 0) {
        python.decref(loop.?);
        return PythonError.RuntimeError;
    }

    const result = python.og.PyObject_CallObject(set_loop_func, args.?);
    if (result == null) {
        return PythonError.RuntimeError;
    }
    python.decref(result.?);

    // Import threading
    const threading = try importModule("threading");
    defer python.decref(threading);

    // Get the run_forever function
    const run_forever_func = try getAttribute(loop.?, "run_forever");
    defer python.decref(run_forever_func);

    // Get the Thread class
    const thread_class = try getAttribute(threading, "Thread");
    defer python.decref(thread_class);

    // Create kwargs for Thread constructor
    const kwargs = python.og.PyDict_New();
    if (kwargs == null) {
        return PythonError.RuntimeError;
    }
    defer python.decref(kwargs.?);

    // Add target=loop.run_forever
    const target_key = try toPyString("target");
    defer python.decref(target_key);
    if (python.og.PyDict_SetItem(kwargs.?, target_key, run_forever_func) < 0) {
        return PythonError.RuntimeError;
    }

    // Add daemon=False - Changed to False to ensure proper cleanup
    const daemon_key = try toPyString("daemon");
    defer python.decref(daemon_key);
    const py_false = python.getPyFalse();
    if (python.og.PyDict_SetItem(kwargs.?, daemon_key, py_false) < 0) {
        return PythonError.RuntimeError;
    }

    // Add name="AsyncioEventLoop"
    const name_key = try toPyString("name");
    defer python.decref(name_key);
    const name_value = try toPyString("AsyncioEventLoop");
    defer python.decref(name_value);
    if (python.og.PyDict_SetItem(kwargs.?, name_key, name_value) < 0) {
        return PythonError.RuntimeError;
    }

    // Create thread object
    const py_thread = python.og.PyObject_Call(thread_class, python.og.PyTuple_New(0), kwargs.?);
    if (py_thread == null) {
        return PythonError.RuntimeError;
    }

    // Start the thread
    const start_method = try getAttribute(py_thread.?, "start");
    defer python.decref(start_method);

    const start_result = python.og.PyObject_CallObject(start_method, null);
    if (start_result == null) {
        python.decref(py_thread.?);
        return PythonError.RuntimeError;
    }
    python.decref(start_result.?);

    // Wait a small amount of time to let the event loop start
    std.time.sleep(100 * std.time.ns_per_ms); // 100ms

    // Verify the loop is running
    const is_running_func = try getAttribute(loop.?, "is_running");
    defer python.decref(is_running_func);

    const is_running_result = python.og.PyObject_CallObject(is_running_func, null);
    if (is_running_result == null) {
        python.decref(py_thread.?);
        return PythonError.RuntimeError;
    }
    defer python.decref(is_running_result.?);

    const is_running = python.og.PyObject_IsTrue(is_running_result.?);
    if (is_running <= 0) {
        std.debug.print("WARNING: Event loop thread started but loop is not running! Will retry...\n", .{});

        // Give it a bit more time and check again
        std.time.sleep(500 * std.time.ns_per_ms); // 500ms

        const retry_result = python.og.PyObject_CallObject(is_running_func, null);
        if (retry_result != null) {
            defer python.decref(retry_result.?);
            const is_running_retry = python.og.PyObject_IsTrue(retry_result.?);
            if (is_running_retry <= 0) {
                std.debug.print("ERROR: Event loop still not running after waiting!\n", .{});
            } else {
                std.debug.print("INFO: Event loop is now running after waiting\n", .{});
            }
        }
    } else {
        std.debug.print("INFO: Event loop is running in background thread\n", .{});
    }

    std.debug.print("DEBUG: Event loop created and started in background thread\n", .{});
    return EventLoopContext{ .loop = loop.?, .thread = py_thread.? };
}

/// Stop the event loop and clean up resources
pub fn stopEventLoop(ctx: EventLoopContext) !void {
    // Acquire GIL for Python API calls
    const gil_state = python.og.PyGILState_Ensure();
    defer python.og.PyGILState_Release(gil_state);

    // Get call_soon_threadsafe method
    const call_soon = try getAttribute(ctx.loop, "call_soon_threadsafe");
    defer python.decref(call_soon);

    // Get stop method
    const stop_func = try getAttribute(ctx.loop, "stop");
    defer python.decref(stop_func);

    // Schedule stop using call_soon_threadsafe
    const call_args = python.og.PyTuple_New(1);
    if (call_args == null) {
        return PythonError.RuntimeError;
    }
    defer python.decref(call_args.?);

    if (python.og.PyTuple_SetItem(call_args.?, 0, stop_func) < 0) {
        return PythonError.RuntimeError;
    }

    const schedule_result = python.og.PyObject_CallObject(call_soon, call_args);
    if (schedule_result == null) {
        return PythonError.RuntimeError;
    }
    python.decref(schedule_result.?);

    // Wait for the loop to stop (with timeout)
    const is_running_func = try getAttribute(ctx.loop, "is_running");
    defer python.decref(is_running_func);

    var attempts: u32 = 0;
    const max_attempts: u32 = 100; // 1 second total (10ms * 100)

    while (attempts < max_attempts) : (attempts += 1) {
        const is_running_result = python.og.PyObject_CallObject(is_running_func, null);
        if (is_running_result == null) {
            return PythonError.RuntimeError;
        }
        defer python.decref(is_running_result.?);

        const is_running = python.og.PyObject_IsTrue(is_running_result.?);
        if (is_running <= 0) {
            std.debug.print("DEBUG: Event loop has stopped\n", .{});
            break;
        }

        // Release GIL while sleeping
        python.og.PyGILState_Release(gil_state);
        std.time.sleep(10 * std.time.ns_per_ms); // 10ms sleep
        _ = python.og.PyGILState_Ensure();
    }

    if (attempts >= max_attempts) {
        std.debug.print("WARNING: Event loop did not stop after timeout\n", .{});
    }

    // Now close the loop
    const close_func = try getAttribute(ctx.loop, "close");
    defer python.decref(close_func);

    const close_result = python.og.PyObject_CallObject(close_func, null);
    if (close_result == null) {
        std.debug.print("DEBUG: Error closing event loop\n", .{});
        return PythonError.RuntimeError;
    }
    python.decref(close_result.?);
    std.debug.print("DEBUG: Closed loop\n", .{});

    // Get thread join method
    const join_func = try getAttribute(ctx.thread, "join");
    defer python.decref(join_func);

    // Join the thread with a timeout
    const timeout_args = python.og.PyTuple_New(1);
    if (timeout_args == null) {
        return PythonError.RuntimeError;
    }
    defer python.decref(timeout_args.?);

    // Set timeout to 1 second
    const timeout = python.og.PyFloat_FromDouble(1.0);
    if (timeout == null) {
        return PythonError.RuntimeError;
    }
    defer python.decref(timeout.?);

    if (python.og.PyTuple_SetItem(timeout_args.?, 0, timeout.?) < 0) {
        return PythonError.RuntimeError;
    }

    // Join the thread
    const join_result = python.og.PyObject_CallObject(join_func, timeout_args.?);
    if (join_result == null) {
        std.debug.print("DEBUG: Error joining thread\n", .{});
        return PythonError.RuntimeError;
    }
    python.decref(join_result.?);
    std.debug.print("DEBUG: Joined thread\n", .{});

    // Cleanup references
    python.decref(ctx.loop);
    python.decref(ctx.thread);
}
