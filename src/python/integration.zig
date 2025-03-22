const std = @import("std");
const Allocator = std.mem.Allocator;
const python = @import("python_wrapper");

// Re-export the python module as 'c' for compatibility with tests
pub const c = python;

// Import ASGI protocol module - use the module name defined in build.zig
const protocol = @import("protocol");

// Export the PyObject type for external use
pub const PyObject = python.PyObject;

/// Workaround functions to access Python constants safely
fn getPyNone() *python.PyObject {
    return python.getPyNone();
}

/// Get True from Python
fn getPyTrue() *python.PyObject {
    return python.getPyTrue();
}

/// Get False from Python
fn getPyFalse() *python.PyObject {
    return python.getPyFalse();
}

/// Workaround to make Python bool values in Zig
fn getPyBool(value: bool) *python.PyObject {
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
    if (python.Py_IsInitialized() == 0) {
        python.Py_Initialize();
        if (python.Py_IsInitialized() == 0) {
            return PythonError.InitFailed;
        }
    }
}

/// Finalize the Python interpreter
pub fn finalize() void {
    if (python.Py_IsInitialized() != 0) {
        python.Py_Finalize();
    }
}

/// Import a Python module
pub fn importModule(module_name: []const u8) !*python.PyObject {
    const py_name = try toPyString(module_name);
    defer decref(py_name);

    const module = python.PyImport_Import(py_name);
    if (module == null) {
        handlePythonError();
        return PythonError.ModuleNotFound;
    }

    return module.?;
}

/// Get an attribute from a Python object
pub fn getAttribute(object: *python.PyObject, attr_name: []const u8) !*python.PyObject {
    const py_name = try toPyString(attr_name);
    defer decref(py_name);

    const attr = python.PyObject_GetAttr(object, py_name);
    if (attr == null) {
        handlePythonError();
        return PythonError.AttributeNotFound;
    }

    return attr.?;
}

/// Convert a Zig string to a Python string
pub fn toPyString(string: []const u8) !*python.PyObject {
    const py_string = python.PyUnicode_FromStringAndSize(string.ptr, @intCast(string.len));
    if (py_string == null) {
        handlePythonError();
        return PythonError.ValueError;
    }

    return py_string.?;
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
    if (python.PyErr_Occurred() != null) {
        python.PyErr_Print();
        python.PyErr_Clear();
    }
}

/// Load a Python ASGI application
pub fn loadApplication(module_path: []const u8, app_name: []const u8) !*python.PyObject {
    // Import the module
    const module = try importModule(module_path);
    defer decref(module);

    // Get the application attribute
    const app = try getAttribute(module, app_name);

    // Ensure it's callable
    if (python.PyCallable_Check(app) == 0) {
        decref(app);
        return PythonError.InvalidApplication;
    }

    return app;
}

/// Create a Python dict from a JSON object
pub fn createPyDict(allocator: Allocator, json_obj: std.json.Value) !*python.PyObject {
    if (json_obj != .object) {
        return PythonError.TypeError;
    }

    const dict = python.PyDict_New();
    if (dict == null) {
        handlePythonError();
        return PythonError.RuntimeError;
    }

    var it = json_obj.object.iterator();
    while (it.next()) |entry| {
        const key = try toPyString(entry.key_ptr.*);
        defer decref(key);

        const value = try jsonToPyObject(allocator, entry.value_ptr.*);
        defer decref(value);

        if (python.PyDict_SetItem(dict.?, key, value) < 0) {
            decref(dict.?);
            handlePythonError();
            return PythonError.RuntimeError;
        }
    }

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
            const py_int = python.PyLong_FromLongLong(i);
            if (py_int == null) {
                handlePythonError();
                return PythonError.ValueError;
            }
            return py_int.?;
        },
        .float => |f| {
            const py_float = python.PyFloat_FromDouble(f);
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
            const py_list = python.PyList_New(@intCast(arr.items.len));
            if (py_list == null) {
                handlePythonError();
                return PythonError.RuntimeError;
            }

            for (arr.items, 0..) |item, i| {
                const py_item = try jsonToPyObject(allocator, item);
                // PyList_SetItem steals a reference, so no DECREF
                if (python.PyList_SetItem(py_list.?, @intCast(i), py_item) < 0) {
                    decref(py_list.?);
                    handlePythonError();
                    return PythonError.RuntimeError;
                }
            }

            return py_list.?;
        },
        .object => |obj| {
            const py_dict = python.PyDict_New();
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
    if (python.PyBool_Check(py_obj) != 0) {
        const py_true = python.getPyTrue();
        return std.json.Value{ .bool = py_obj == py_true };
    } else if (python.PyLong_Check(py_obj) != 0) {
        const value = python.PyLong_AsLongLong(py_obj);
        if (value == -1 and python.PyErr_Occurred() != null) {
            handlePythonError();
            return PythonError.ValueError;
        }
        return std.json.Value{ .integer = value };
    } else if (python.PyFloat_Check(py_obj) != 0) {
        const value = python.PyFloat_AsDouble(py_obj);
        if (value == -1.0 and python.PyErr_Occurred() != null) {
            handlePythonError();
            return PythonError.ValueError;
        }
        return std.json.Value{ .float = value };
    } else if (python.PyUnicode_Check(py_obj) != 0) {
        const str = try fromPyString(allocator, py_obj);
        return std.json.Value{ .string = str };
    } else if (python.PyBytes_Check(py_obj) != 0) {
        var size: c_long = undefined;
        var bytes_ptr: [*c]u8 = undefined;
        const result = python.PyBytes_AsStringAndSize(py_obj, &bytes_ptr, &size);
        if (result < 0) {
            handlePythonError();
            return PythonError.ValueError;
        }
        const data = try allocator.dupe(u8, bytes_ptr[0..@intCast(size)]);
        return std.json.Value{ .string = data };
    } else if (python.PyList_Check(py_obj) != 0 or python.PyTuple_Check(py_obj) != 0) {
        const size = if (python.PyList_Check(py_obj) != 0)
            python.PyList_Size(py_obj)
        else
            python.PyTuple_Size(py_obj);

        if (size < 0) {
            handlePythonError();
            return PythonError.RuntimeError;
        }

        var array = std.json.Value{
            .array = std.json.Array.init(allocator),
        };

        var i: c_long = 0;
        while (i < size) : (i += 1) {
            const item = if (python.PyList_Check(py_obj) != 0)
                python.PyList_GetItem(py_obj, i)
            else
                python.PyTuple_GetItem(py_obj, i);

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
    } else if (python.PyDict_Check(py_obj) != 0) {
        var object = std.json.Value{
            .object = std.json.ObjectMap.init(allocator),
        };

        var pos: c_long = 0;
        var key: ?*python.PyObject = undefined;
        var value: ?*python.PyObject = undefined;

        while (python.PyDict_Next(py_obj, @ptrCast(&pos), &key, &value) != 0) {
            if (key == null or value == null) continue;

            if (python.PyUnicode_Check(key.?) == 0) {
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
fn getNoneForCallback() ?*python.PyObject {
    const none = python.getPyNone();
    python.incref(none);
    return none;
}

/// Function to be called from Python's receive() callable
fn pyReceiveCallback(self: *python.PyObject, _: *python.PyObject) callconv(.C) ?*python.PyObject {
    // Expecting self to be a pointer to a Message Queue
    if (python.PyCapsule_CheckExact(self) == 0) {
        _ = python.PyErr_SetString(python.PyExc_TypeError, "Expected a capsule as self");
        return null;
    }

    const queue_ptr = python.PyCapsule_GetPointer(self, "MessageQueue");
    if (queue_ptr == null) {
        return null;
    }

    // Cast with alignment correction
    const queue = @as(*protocol.MessageQueue, @alignCast(@ptrCast(queue_ptr)));

    // Create async task for awaiting
    const asyncio = python.PyImport_ImportModule("asyncio");
    if (asyncio == null) {
        _ = python.PyErr_SetString(python.PyExc_ImportError, "Failed to import asyncio");
        return null;
    }
    defer decref(asyncio.?);

    const create_task = python.PyObject_GetAttrString(asyncio.?, "create_task");
    if (create_task == null) {
        _ = python.PyErr_SetString(python.PyExc_AttributeError, "Failed to get create_task");
        return null;
    }
    defer decref(create_task.?);

    // Create a Future to handle asynchronous receive
    const future_type = python.PyObject_GetAttrString(asyncio.?, "Future");
    if (future_type == null) {
        _ = python.PyErr_SetString(python.PyExc_AttributeError, "Failed to get Future");
        return null;
    }
    defer decref(future_type.?);

    const future = python.PyObject_CallObject(future_type.?, null);
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

    python.PyEval_RestoreThread(thread_state);

    // Set the result on the future
    const set_result = python.PyObject_GetAttrString(future.?, "set_result");
    if (set_result == null) {
        decref(future.?);
        return null;
    }
    defer decref(set_result.?);

    // Convert to Python dict
    const gpa = std.heap.c_allocator;
    const py_message = jsonToPyObject(gpa, message) catch {
        _ = python.PyErr_SetString(python.PyExc_RuntimeError, "Failed to convert message to Python object");
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
fn pySendCallback(self: *python.PyObject, args: *python.PyObject) callconv(.C) ?*python.PyObject {
    // Ensure we have exactly one argument
    if (python.PyTuple_Size(args) != 1) {
        _ = python.PyErr_SetString(python.PyExc_TypeError, "Expected exactly one argument");
        return null;
    }

    // Expecting self to be a pointer to a Message Queue
    if (python.PyCapsule_CheckExact(self) == 0) {
        _ = python.PyErr_SetString(python.PyExc_TypeError, "Expected a capsule as self");
        return null;
    }

    const queue_ptr = python.PyCapsule_GetPointer(self, "MessageQueue");
    if (queue_ptr == null) {
        return null;
    }

    // Cast with alignment correction
    const queue = @as(*protocol.MessageQueue, @alignCast(@ptrCast(queue_ptr)));

    // Get the message argument
    const message = python.PyTuple_GetItem(args, 0);
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
    const asyncio = python.PyImport_ImportModule("asyncio");
    if (asyncio == null) {
        _ = python.PyErr_SetString(python.PyExc_ImportError, "Failed to import asyncio");
        return null;
    }
    defer decref(asyncio.?);

    // Create a Future to handle asynchronous send
    const future_type = python.PyObject_GetAttrString(asyncio.?, "Future");
    if (future_type == null) {
        _ = python.PyErr_SetString(python.PyExc_AttributeError, "Failed to get Future");
        return null;
    }
    defer decref(future_type.?);

    const future = python.PyObject_CallObject(future_type.?, null);
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
    const set_result = python.PyObject_GetAttrString(future.?, "set_result");
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
    const capsule = python.PyCapsule_New(queue, "MessageQueue", null);
    if (capsule == null) {
        handlePythonError();
        return PythonError.RuntimeError;
    }

    // Create method definition
    var method_def = python.PyMethodDef{
        .ml_name = "receive",
        .ml_meth = @ptrCast(&pyReceiveCallback),
        .ml_flags = python.METH_NOARGS,
        .ml_doc = "ASGI receive callable",
    };

    // Create function object for receive
    const py_func = python.PyCFunction_New(&method_def, capsule);

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
    const capsule = python.PyCapsule_New(queue, "MessageQueue", null);
    if (capsule == null) {
        handlePythonError();
        return PythonError.RuntimeError;
    }

    // Create method definition
    var method_def = python.PyMethodDef{
        .ml_name = "send",
        .ml_meth = @ptrCast(&pySendCallback),
        .ml_flags = python.METH_VARARGS,
        .ml_doc = "ASGI send callable",
    };

    // Create function object for send
    const py_func = python.PyCFunction_New(&method_def, capsule);

    if (py_func == null) {
        decref(capsule.?);
        handlePythonError();
        return PythonError.RuntimeError;
    }

    return py_func.?;
}

/// Call an ASGI application with scope, receive, and send
pub fn callAsgiApplication(app: *python.PyObject, scope: *python.PyObject, receive: *python.PyObject, send: *python.PyObject) !void {
    // Create arguments tuple (app(scope, receive, send))
    const args = python.PyTuple_New(3);
    if (args == null) {
        handlePythonError();
        return PythonError.RuntimeError;
    }
    defer decref(args.?);

    // Incref to counteract the stolen references
    python.incref(scope);
    python.incref(receive);
    python.incref(send);

    if (python.PyTuple_SetItem(args.?, 0, scope) < 0 or
        python.PyTuple_SetItem(args.?, 1, receive) < 0 or
        python.PyTuple_SetItem(args.?, 2, send) < 0)
    {
        handlePythonError();
        return PythonError.RuntimeError;
    }

    // Call the application
    const result = python.PyObject_Call(app, args.?, null);
    if (result == null) {
        handlePythonError();
        return PythonError.CallFailed;
    }

    // Handle coroutine case (async def app)
    if (python.PyCoro_CheckExact(result.?) != 0) {
        // We need to run this coroutine - import asyncio
        const asyncio = python.PyImport_ImportModule("asyncio");
        if (asyncio == null) {
            decref(result.?);
            handlePythonError();
            return PythonError.RuntimeError;
        }
        defer decref(asyncio.?);

        // Get asyncio.run
        const run_func = python.PyObject_GetAttrString(asyncio.?, "run");
        if (run_func == null) {
            decref(result.?);
            handlePythonError();
            return PythonError.RuntimeError;
        }
        defer decref(run_func.?);

        // Run the coroutine
        const run_args = python.PyTuple_New(1);
        if (run_args == null) {
            decref(result.?);
            handlePythonError();
            return PythonError.RuntimeError;
        }
        defer decref(run_args.?);

        // PyTuple_SetItem steals a reference
        if (python.PyTuple_SetItem(run_args.?, 0, result.?) < 0) {
            decref(result.?);
            handlePythonError();
            return PythonError.RuntimeError;
        }

        const run_result = python.PyObject_Call(run_func.?, run_args.?, null);
        if (run_result == null) {
            handlePythonError();
            return PythonError.CallFailed;
        }
        decref(run_result.?);
    } else {
        decref(result.?);
    }
}

// Helper function to replace all Py_INCREF and Py_DECREF calls throughout the file
pub fn incref(obj: *python.PyObject) void {
    python.incref(obj);
}

pub fn decref(obj: *python.PyObject) void {
    python.decref(obj);
}
