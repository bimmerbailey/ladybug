const std = @import("std");
const Allocator = std.mem.Allocator;
const python = @import("python_wrapper");

// Re-export the python module as 'c' for compatibility with tests
// pub const c = python;

// Import ASGI protocol module - use the module name defined in build.zig
const protocol = @import("protocol");

// Export the PyObject type for external use
pub const PyObject = python.og.PyObject;

/// Workaround functions to access Python constants safely
fn getPyNone() *PyObject {
    return python.getPyNone();
}

/// Get True from Python
fn getPyTrue() *PyObject {
    return python.getPyTrue();
}

/// Get False from Python
fn getPyFalse() *PyObject {
    return python.getPyFalse();
}

/// Workaround to make Python bool values in Zig
fn getPyBool(value: bool) *PyObject {
    return if (value) python.getPyTrue() else python.getPyFalse();
}

/// Python errors
pub const PythonError = error{
    InitFailed,
    ModuleNotFound,
    AttributeNotFound,
    InvalidApplication,
    CallFailed,
    TypeError,
    ValueError,
    RuntimeError,
    Exception,
};

/// Initialize the Python interpreter
pub fn initialize() !void {
    std.debug.print("DEBUG: Initializing Python interpreter\n", .{});
    if (python.og.Py_IsInitialized() == 0) {
        std.debug.print("DEBUG: Python not initialized, calling Py_Initialize()\n", .{});
        python.og.Py_InitializeEx(0);
        if (python.og.Py_IsInitialized() == 0) {
            std.debug.print("DEBUG: Python initialization failed\n", .{});
            return PythonError.InitFailed;
        }
    } else {
        std.debug.print("DEBUG: Python already initialized\n", .{});
    }
}

/// Finalize the Python interpreter
pub fn finalize() void {
    std.debug.print("DEBUG: Finalizing Python interpreter\n", .{});
    if (python.og.Py_IsInitialized() != 0) {
        _ = python.og.Py_FinalizeEx();
    }
}

/// Check if a Python object pointer is null and handle the error
fn checkPyObjectNotNull(obj: *PyObject, errorMessage: []const u8) !void {
    if (obj == null) {
        std.debug.print("ERROR: {s} is null!\n", .{errorMessage});
        return PythonError.RuntimeError; // Return an appropriate error
    }
}

/// Import a Python module
pub fn importModule(module_name: []const u8) !*PyObject {
    std.debug.print("DEBUG: Importing module: {s}\n", .{module_name});
    const py_name = try toPyString(module_name);
    defer decref(py_name);

    std.debug.print("DEBUG: Calling PyImport_Import\n", .{});
    const module = python.og.PyImport_Import(py_name);
    if (module == null) {
        std.debug.print("DEBUG: Module import failed\n", .{});
        handlePythonError();
        return PythonError.ModuleNotFound;
    }

    std.debug.print("DEBUG: Successfully imported module {s}\n", .{module_name});
    return module;
}

/// Get an attribute from a Python object
pub fn getAttribute(object: *PyObject, attr_name: []const u8) !*PyObject {
    std.debug.print("DEBUG: Getting attribute: {s}\n", .{attr_name});
    const py_name = try toPyString(attr_name);
    defer decref(py_name);

    const attr = python.og.PyObject_GetAttr(object, py_name);
    if (attr == null) {
        handlePythonError();
        return PythonError.AttributeNotFound;
    }

    return attr;
}

/// Convert a Zig string to a Python string
pub fn toPyString(string: []const u8) !*PyObject {
    const py_string = python.og.PyUnicode_FromStringAndSize(string.ptr, @intCast(string.len));
    if (py_string == null) {
        handlePythonError();
        return PythonError.ValueError;
    }

    std.debug.print("DEBUG: Converted string to PyObject: {*}\n", .{py_string.?});
    return py_string;
}

/// Convert a Python string to a Zig string
pub fn fromPyString(allocator: Allocator, py_string: *python.PyObject) ![]u8 {
    if (python.PyUnicode_Check(py_string) == 0) {
        return PythonError.TypeError;
    }

    const utf8 = python.PyUnicode_AsUTF8(py_string);
    if (utf8 == null) {
        handlePythonError();
        return PythonError.ValueError;
    }

    return try allocator.dupe(u8, std.mem.span(utf8.?));
}

/// Handle Python exceptions by printing them and clearing the error
fn handlePythonError() void {
    if (python.og.PyErr_Occurred() != null) {
        python.og.PyErr_Print();
        python.og.PyErr_Clear();
    }
}

/// Load a Python ASGI application
pub fn loadApplication(module_path: []const u8, app_name: []const u8) !*python.PyObject {
    std.debug.print("DEBUG: Loading application\n", .{});
    // Import the module
    const module = try importModule(module_path);
    defer decref(module);

    // Get the application attribute
    const app = try getAttribute(module, app_name);

    // Ensure it's callable
    if (python.og.PyCallable_Check(app) == 0) {
        decref(app);
        return PythonError.InvalidApplication;
    }

    std.debug.print("DEBUG: Application loaded module: {s}, app: {s}\n", .{ module_path, app_name });
    return app;
}

/// Create a Python dict from a JSON object
pub fn createPyDict(allocator: Allocator, json_obj: std.json.Value) !*python.PyObject {
    std.debug.print("DEBUG: Creating Python dict from JSON object\n", .{});
    if (json_obj != .object) {
        return PythonError.TypeError;
    }

    std.debug.print("DEBUG: Creating empty Python dict\n", .{});
    const dict = python.og.PyDict_New();
    if (dict == null) {
        std.debug.print("DEBUG: Python dict creation failed\n", .{});
        handlePythonError();
        return PythonError.RuntimeError;
    }

    std.debug.print("DEBUG: Iterating over JSON object\n", .{});
    var it = json_obj.object.iterator();
    while (it.next()) |entry| {
        const key = try toPyString(entry.key_ptr.*);
        defer decref(key);

        const value = try jsonToPyObject(allocator, entry.value_ptr.*);
        defer decref(value);

        if (python.og.PyDict_SetItem(dict.?, key, value) < 0) {
            decref(dict.?);
            handlePythonError();
            return PythonError.RuntimeError;
        }
    }
    std.debug.print("DEBUG: Python dict created\n", .{});
    return dict.?;
}

/// Convert a JSON value to a Python object
pub fn jsonToPyObject(allocator: Allocator, json_value: std.json.Value) !*python.PyObject {
    switch (json_value) {
        .null => {
            // Get Python None using our C shim
            const none = python.getPyNone();
            python.incref(none);
            return none;
        },
        .bool => |b| {
            // Use PyBool_FromLong directly
            return getPyBool(b);
        },
        .integer => |i| {
            const py_int = python.og.PyLong_FromLongLong(i);
            if (py_int == null) {
                handlePythonError();
                return PythonError.ValueError;
            }
            return py_int.?;
        },
        .float => |f| {
            const py_float = python.og.PyFloat_FromDouble(f);
            if (py_float == null) {
                handlePythonError();
                return PythonError.ValueError;
            }
            return py_float.?;
        },
        .string => |s| {
            return try toPyString(s);
        },
        .array => |arr| {
            const py_list = python.og.PyList_New(@intCast(arr.items.len));
            if (py_list == null) {
                handlePythonError();
                return PythonError.RuntimeError;
            }

            for (arr.items, 0..) |item, i| {
                const py_item = try jsonToPyObject(allocator, item);
                // PyList_SetItem steals a reference, so no DECREF
                if (python.og.PyList_SetItem(py_list.?, @intCast(i), py_item) < 0) {
                    decref(py_list.?);
                    handlePythonError();
                    return PythonError.RuntimeError;
                }
            }

            return py_list.?;
        },
        .object => |obj| {
            const py_dict = python.og.PyDict_New();
            if (py_dict == null) {
                handlePythonError();
                return PythonError.RuntimeError;
            }

            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try toPyString(entry.key_ptr.*);
                defer decref(key);

                const value = try jsonToPyObject(allocator, entry.value_ptr.*);
                defer decref(value);

                if (python.PyDict_SetItem(py_dict.?, key, value) < 0) {
                    decref(py_dict.?);
                    handlePythonError();
                    return PythonError.RuntimeError;
                }
            }

            return py_dict.?;
        },
        .number_string => |s| {
            // Try to convert string to integer or float
            if (std.fmt.parseInt(i64, s, 10)) |int_val| {
                const py_int = python.PyLong_FromLongLong(int_val);
                if (py_int == null) {
                    handlePythonError();
                    return PythonError.ValueError;
                }
                return py_int.?;
            } else |_| {
                if (std.fmt.parseFloat(f64, s)) |float_val| {
                    const py_float = python.PyFloat_FromDouble(float_val);
                    if (py_float == null) {
                        handlePythonError();
                        return PythonError.ValueError;
                    }
                    return py_float.?;
                } else |_| {
                    // If parsing fails, return as a string
                    return try toPyString(s);
                }
            }
        },
    }
}

/// Convert a Python object to a JSON value
pub fn pyObjectToJson(allocator: Allocator, py_obj: *python.PyObject) !std.json.Value {
    if (python.og.PyBool_Check(py_obj) != 0) {
        const py_true = python.getPyTrue();
        return std.json.Value{ .bool = py_obj == py_true };
    } else if (python.og.PyLong_Check(py_obj) != 0) {
        const value = python.og.PyLong_AsLongLong(py_obj);
        if (value == -1 and python.og.PyErr_Occurred() != null) {
            handlePythonError();
            return PythonError.ValueError;
        }
        return std.json.Value{ .integer = value };
    } else if (python.og.PyFloat_Check(py_obj) != 0) {
        const value = python.og.PyFloat_AsDouble(py_obj);
        if (value == -1.0 and python.og.PyErr_Occurred() != null) {
            handlePythonError();
            return PythonError.ValueError;
        }
        return std.json.Value{ .float = value };
    } else if (python.og.PyUnicode_Check(py_obj) != 0) {
        const str = try fromPyString(allocator, py_obj);
        return std.json.Value{ .string = str };
    } else if (python.og.PyBytes_Check(py_obj) != 0) {
        var size: c_long = undefined;
        var bytes_ptr: [*c]u8 = undefined;
        const result = python.og.PyBytes_AsStringAndSize(py_obj, &bytes_ptr, &size);
        if (result < 0) {
            handlePythonError();
            return PythonError.ValueError;
        }
        const data = try allocator.dupe(u8, bytes_ptr[0..@intCast(size)]);
        return std.json.Value{ .string = data };
    } else if (python.og.PyList_Check(py_obj) != 0 or python.og.PyTuple_Check(py_obj) != 0) {
        const size = if (python.og.PyList_Check(py_obj) != 0)
            python.og.PyList_Size(py_obj)
        else
            python.og.PyTuple_Size(py_obj);

        if (size < 0) {
            handlePythonError();
            return PythonError.RuntimeError;
        }

        var array = std.json.Value{
            .array = std.json.Array.init(allocator),
        };

        var i: c_long = 0;
        while (i < size) : (i += 1) {
            const item = if (python.og.PyList_Check(py_obj) != 0)
                python.og.PyList_GetItem(py_obj, i)
            else
                python.og.PyTuple_GetItem(py_obj, i);

            if (item == null) {
                // Free the array items we've already added - manually free each item
                for (array.array.items) |*json_item| {
                    switch (json_item.*) {
                        .string => |s| allocator.free(s),
                        .array => |*a| a.deinit(),
                        .object => |*o| o.deinit(),
                        else => {},
                    }
                }
                array.array.deinit();
                handlePythonError();
                return PythonError.RuntimeError;
            }

            // These are borrowed references, no DECREF needed
            const json_item = try pyObjectToJson(allocator, item.?);
            try array.array.append(json_item);
        }

        return array;
    } else if (python.og.PyDict_Check(py_obj) != 0) {
        var object = std.json.Value{
            .object = std.json.ObjectMap.init(allocator),
        };

        var pos: c_long = 0;
        var key: ?*python.PyObject = undefined;
        var value: ?*python.PyObject = undefined;

        while (python.og.PyDict_Next(py_obj, @ptrCast(&pos), &key, &value) != 0) {
            if (key == null or value == null) continue;

            if (python.og.PyUnicode_Check(key.?) == 0) {
                protocol.jsonValueDeinit(object, allocator);
                return PythonError.TypeError;
            }

            const key_str = try fromPyString(allocator, key.?);
            const json_value = try pyObjectToJson(allocator, value.?);

            try object.object.put(key_str, json_value);
        }

        return object;
    } else if (python.isNone(py_obj)) {
        return std.json.Value{ .null = {} };
    } else {
        return PythonError.TypeError;
    }
}

/// Function to get Python None for callback function
fn getNoneForCallback() ?*PyObject {
    const none = python.getPyNone();
    python.incref(none);
    return none;
}

/// Function to be called from Python's receive() callable
fn pyReceiveCallback(self: *PyObject, _: *PyObject) callconv(.C) ?*PyObject {
    // Expecting self to be a pointer to a Message Queue
    if (python.PyCapsule_CheckExact(self) == 0) {
        _ = python.PyErr_SetString(python.PyExc_TypeError, "Expected a capsule as self");
        return null;
    }

    const queue_ptr = python.og.PyCapsule_GetPointer(self, "MessageQueue");
    if (queue_ptr == null) {
        return null;
    }

    // Cast with alignment correction
    const queue = @as(*protocol.MessageQueue, @alignCast(@ptrCast(queue_ptr)));

    // Create async task for awaiting
    const asyncio = python.og.PyImport_ImportModule("asyncio");
    if (asyncio == null) {
        _ = python.PyErr_SetString(python.PyExc_ImportError, "Failed to import asyncio");
        return null;
    }
    defer decref(asyncio.?);

    const create_task = python.og.PyObject_GetAttrString(asyncio.?, "create_task");
    if (create_task == null) {
        _ = python.PyErr_SetString(python.PyExc_AttributeError, "Failed to get create_task");
        return null;
    }
    defer decref(create_task.?);

    // Create a Future to handle asynchronous receive
    const future_type = python.og.PyObject_GetAttrString(asyncio.?, "Future");
    if (future_type == null) {
        _ = python.PyErr_SetString(python.PyExc_AttributeError, "Failed to get Future");
        return null;
    }
    defer decref(future_type.?);

    const future = python.og.PyObject_CallObject(future_type.?, null);
    if (future == null) {
        return null;
    }

    // Spawn a separate thread to wait for the message
    const thread_state = python.PyEval_SaveThread();

    // Receive message (this will block until a message is available)
    const message = queue.receive() catch {
        python.PyEval_RestoreThread(thread_state);
        _ = python.PyErr_SetString(python.PyExc_RuntimeError, "Failed to receive message from queue");
        decref(future.?);
        return null;
    };

    // Restore the thread state breaks when using python.og.PyEval_RestoreThread
    python.PyEval_RestoreThread(thread_state);

    // Set the result on the future
    const set_result = python.og.PyObject_GetAttrString(future.?, "set_result");
    if (set_result == null) {
        decref(future.?);
        return null;
    }
    defer decref(set_result.?);

    // Convert to Python dict
    const gpa = std.heap.c_allocator;
    const py_message = jsonToPyObject(gpa, message) catch {
        _ = python.og.PyErr_SetString(python.PyExc_RuntimeError, "Failed to convert message to Python object");
        decref(future.?);
        return null;
    };

    // Set the result on the future
    const result = python.zig_call_function_with_arg(set_result.?, py_message);
    decref(py_message);

    if (result == null) {
        decref(future.?);
        return null;
    }
    decref(result.?);

    return future;
}

/// Function to be called from Python's send() callable
fn pySendCallback(self: *PyObject, args: *PyObject) callconv(.C) ?*PyObject {
    // Ensure we have exactly one argument
    if (python.PyTuple_Size(args) != 1) {
        _ = python.og.PyErr_SetString(python.PyExc_TypeError, "Expected exactly one argument");
        return null;
    }

    // Expecting self to be a pointer to a Message Queue
    if (python.og.PyCapsule_CheckExact(self) == 0) {
        _ = python.PyErr_SetString(python.PyExc_TypeError, "Expected a capsule as self");
        return null;
    }

    const queue_ptr = python.og.PyCapsule_GetPointer(self, "MessageQueue");
    if (queue_ptr == null) {
        return null;
    }

    // Cast with alignment correction
    const queue = @as(*protocol.MessageQueue, @alignCast(@ptrCast(queue_ptr)));

    // Get the message argument
    const message = python.og.PyTuple_GetItem(args, 0);
    if (message == null) {
        return null;
    }

    // Convert to JSON
    const gpa = std.heap.c_allocator;
    const json_message = pyObjectToJson(gpa, message.?) catch {
        _ = python.PyErr_SetString(python.PyExc_RuntimeError, "Failed to convert message to JSON");
        return null;
    };

    // Create async task for awaiting
    const asyncio = python.og.PyImport_ImportModule("asyncio");
    if (asyncio == null) {
        _ = python.PyErr_SetString(python.PyExc_ImportError, "Failed to import asyncio");
        return null;
    }
    defer decref(asyncio.?);

    // Create a Future to handle asynchronous send
    const future_type = python.og.PyObject_GetAttrString(asyncio.?, "Future");
    if (future_type == null) {
        _ = python.PyErr_SetString(python.PyExc_AttributeError, "Failed to get Future");
        return null;
    }
    defer decref(future_type.?);

    const future = python.og.PyObject_CallObject(future_type.?, null);
    if (future == null) {
        return null;
    }

    // Push the message to the queue
    queue.push(json_message) catch {
        _ = python.PyErr_SetString(python.PyExc_RuntimeError, "Failed to push message to queue");
        decref(future.?);
        return null;
    };

    // Set the result on the future to None (indicating success)
    const set_result = python.og.PyObject_GetAttrString(future.?, "set_result");
    if (set_result == null) {
        decref(future.?);
        return null;
    }
    defer decref(set_result.?);

    // Get None for the result
    const none = getNoneForCallback();
    if (none == null) {
        decref(future.?);
        return null;
    }

    const result = python.zig_call_function_with_arg(set_result.?, none.?);
    decref(none.?);

    if (result == null) {
        decref(future.?);
        return null;
    }
    decref(result.?);

    return future;
}

/// Create a Python receive callable for ASGI
pub fn createReceiveCallable(queue: *protocol.MessageQueue) !*python.PyObject {
    // Create capsule to hold the queue pointer
    const capsule = python.og.PyCapsule_New(queue, "MessageQueue", null);
    if (capsule == null) {
        handlePythonError();
        return PythonError.RuntimeError;
    }

    // Create method definition
    var method_def = python.og.PyMethodDef{
        .ml_name = "receive",
        .ml_meth = @ptrCast(&pyReceiveCallback),
        .ml_flags = python.METH_NOARGS,
        .ml_doc = "ASGI receive callable",
    };

    // Create function object for receive
    const py_func = python.og.PyCFunction_New(&method_def, capsule);

    if (py_func == null) {
        decref(capsule.?);
        handlePythonError();
        return PythonError.RuntimeError;
    }

    return py_func.?;
}

/// Create a Python send callable for ASGI
pub fn createSendCallable(queue: *protocol.MessageQueue) !*python.PyObject {
    // Create capsule to hold the queue pointer
    const capsule = python.og.PyCapsule_New(queue, "MessageQueue", null);
    if (capsule == null) {
        handlePythonError();
        return PythonError.RuntimeError;
    }

    // Create method definition
    var method_def = python.og.PyMethodDef{
        .ml_name = "send",
        .ml_meth = @ptrCast(&pySendCallback),
        .ml_flags = python.METH_VARARGS,
        .ml_doc = "ASGI send callable",
    };

    // Create function object for send
    const py_func = python.og.PyCFunction_New(&method_def, capsule);

    if (py_func == null) {
        decref(capsule.?);
        handlePythonError();
        return PythonError.RuntimeError;
    }

    return py_func.?;
}

/// Call an ASGI application with scope, receive, and send
pub fn callAsgiApplication(app: *python.PyObject, scope: *python.PyObject, receive: *python.PyObject, send: *python.PyObject) !void {
    std.debug.print("\nDEBUG: Calling ASGI application\n", .{});

    // Debug the app object type
    if (python.og.PyCallable_Check(app) == 0) {
        std.debug.print("DEBUG: App is not callable!\n", .{});
    } else {
        std.debug.print("DEBUG: App is callable\n", .{});
    }

    // Debug the receive object type
    if (python.og.PyCallable_Check(receive) == 0) {
        std.debug.print("DEBUG: receive is not callable!\n", .{});
    } else {
        std.debug.print("DEBUG: receive is callable\n", .{});
    }

    // Debug the send object type
    if (python.og.PyCallable_Check(send) == 0) {
        std.debug.print("DEBUG: send is not callable!\n", .{});
    } else {
        std.debug.print("DEBUG: send is callable\n", .{});
    }

    // Debug the scope object type
    if (python.og.PyDict_Check(scope) == 0) {
        std.debug.print("DEBUG: scope is not a dict!\n", .{});
    } else {
        std.debug.print("DEBUG: scope is a dict\n", .{});
    }

    // Run tuple operations test first
    // try testTupleOperations();

    // Check pointer addresses (don't try to validate content which might cause segfault)
    std.debug.print("DEBUG: Argument pointers:\n", .{});
    std.debug.print("DEBUG: app: {*}\n", .{app});
    std.debug.print("DEBUG: scope: {*}\n", .{scope});
    std.debug.print("DEBUG: receive: {*}\n", .{receive});
    std.debug.print("DEBUG: send: {*}\n", .{send});

    // Allocate tuple as var so we can clear it in case of error
    const args = python.og.PyTuple_New(3);
    if (args == null) {
        std.debug.print("DEBUG: Failed to create args tuple\n", .{});
        handlePythonError();
        return PythonError.RuntimeError;
    }

    std.debug.print("DEBUG: Args tuple created successfully: {*}\n", .{args.?});

    // Create temporary copies of arguments
    std.debug.print("DEBUG: Creating temporary None values for tuple\n", .{});
    const temp_none = python.og.Py_None();
    python.incref(temp_none);
    python.incref(temp_none);
    python.incref(temp_none);

    // Try setting the items to None first
    std.debug.print("DEBUG: Filling tuple with None values first\n", .{});
    if (python.og.PyTuple_SetItem(args.?, 0, temp_none) < 0 or
        python.og.PyTuple_SetItem(args.?, 1, temp_none) < 0 or
        python.og.PyTuple_SetItem(args.?, 2, temp_none) < 0)
    {
        std.debug.print("DEBUG: Failed to set None values in tuple\n", .{});
        // Don't need to decref temp_none as it was stolen or failed
        python.og.Py_DECREF(args.?);
        handlePythonError();
        return PythonError.RuntimeError;
    }

    // std.debug.print("DEBUG: Successfully filled tuple with None values\n", .{});

    // // Now try to replace with actual values one by one
    // std.debug.print("DEBUG: Replacing tuple items with actual arguments\n", .{});

    // // We'll use a simpler approach - just pass None values instead of the real arguments
    // // This way we can test if the code path works at all
    // std.debug.print("DEBUG: Using None values instead of real arguments for now\n", .{});

    // // Call the application with the tuple of Nones
    // std.debug.print("DEBUG: Calling PyObject_CallObject with None tuple\n", .{});
    // const result = python.og.PyObject_CallObject(app, args.?);
    // python.decref(args.?);

    // if (result == null) {
    //     std.debug.print("DEBUG: Call failed\n", .{});
    //     handlePythonError();
    //     return PythonError.CallFailed;
    // }

    // std.debug.print("DEBUG: Call succeeded, result: {*}\n", .{result.?});
    // python.decref(result.?);

    // std.debug.print("DEBUG: ASGI application call completed\n", .{});
    return;
}

// Helper function to replace all Py_INCREF and Py_DECREF calls throughout the file
pub fn incref(obj: *PyObject) void {
    python.og.Py_INCREF(obj);
}

pub fn decref(obj: *PyObject) void {
    python.og.Py_DECREF(obj);
}
