const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("Python.h");
});

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
    if (c.Py_IsInitialized() == 0) {
        c.Py_Initialize();
        if (c.Py_IsInitialized() == 0) {
            return PythonError.InitFailed;
        }
    }
}

/// Finalize the Python interpreter
pub fn finalize() void {
    if (c.Py_IsInitialized() != 0) {
        c.Py_Finalize();
    }
}

/// Import a Python module
pub fn importModule(module_name: []const u8) !*c.PyObject {
    const py_name = try toPyString(module_name);
    defer c.Py_DECREF(py_name);

    const module = c.PyImport_Import(py_name);
    if (module == null) {
        handlePythonError();
        return PythonError.ModuleNotFound;
    }

    return module;
}

/// Get an attribute from a Python object
pub fn getAttribute(object: *c.PyObject, attr_name: []const u8) !*c.PyObject {
    const py_name = try toPyString(attr_name);
    defer c.Py_DECREF(py_name);

    const attr = c.PyObject_GetAttr(object, py_name);
    if (attr == null) {
        handlePythonError();
        return PythonError.AttributeNotFound;
    }

    return attr;
}

/// Convert a Zig string to a Python string
pub fn toPyString(string: []const u8) !*c.PyObject {
    const py_string = c.PyUnicode_FromStringAndSize(string.ptr, @intCast(string.len));
    if (py_string == null) {
        handlePythonError();
        return PythonError.ValueError;
    }

    return py_string;
}

/// Convert a Python string to a Zig string
pub fn fromPyString(allocator: Allocator, py_string: *c.PyObject) ![]u8 {
    if (c.PyUnicode_Check(py_string) == 0) {
        return PythonError.TypeError;
    }

    const utf8 = c.PyUnicode_AsUTF8(py_string);
    if (utf8 == null) {
        handlePythonError();
        return PythonError.ValueError;
    }

    return try allocator.dupe(u8, std.mem.span(utf8));
}

/// Handle Python exceptions by printing them and clearing the error
fn handlePythonError() void {
    if (c.PyErr_Occurred() != null) {
        c.PyErr_Print();
        c.PyErr_Clear();
    }
}

/// Load a Python ASGI application
pub fn loadApplication(module_path: []const u8, app_name: []const u8) !*c.PyObject {
    // Import the module
    const module = try importModule(module_path);
    defer c.Py_DECREF(module);

    // Get the application attribute
    const app = try getAttribute(module, app_name);

    // Ensure it's callable
    if (c.PyCallable_Check(app) == 0) {
        c.Py_DECREF(app);
        return PythonError.InvalidApplication;
    }

    return app;
}

/// Create a Python dict from a JSON object
pub fn createPyDict(allocator: Allocator, json_obj: std.json.Value) !*c.PyObject {
    if (json_obj != .object) {
        return PythonError.TypeError;
    }

    const dict = c.PyDict_New();
    if (dict == null) {
        handlePythonError();
        return PythonError.RuntimeError;
    }

    var it = json_obj.object.iterator();
    while (it.next()) |entry| {
        const key = try toPyString(entry.key_ptr.*);
        defer c.Py_DECREF(key);

        const value = try jsonToPyObject(allocator, entry.value_ptr.*);
        defer c.Py_DECREF(value);

        if (c.PyDict_SetItem(dict, key, value) < 0) {
            c.Py_DECREF(dict);
            handlePythonError();
            return PythonError.RuntimeError;
        }
    }

    return dict;
}

/// Convert a JSON value to a Python object
pub fn jsonToPyObject(allocator: Allocator, json_value: std.json.Value) !*c.PyObject {
    switch (json_value) {
        .null => {
            c.Py_INCREF(c.Py_None);
            return c.Py_None;
        },
        .bool => |b| {
            if (b) {
                c.Py_INCREF(c.Py_True);
                return c.Py_True;
            } else {
                c.Py_INCREF(c.Py_False);
                return c.Py_False;
            }
        },
        .integer => |i| {
            const py_int = c.PyLong_FromLongLong(i);
            if (py_int == null) {
                handlePythonError();
                return PythonError.ValueError;
            }
            return py_int;
        },
        .float => |f| {
            const py_float = c.PyFloat_FromDouble(f);
            if (py_float == null) {
                handlePythonError();
                return PythonError.ValueError;
            }
            return py_float;
        },
        .string => |s| {
            return try toPyString(s);
        },
        .array => |arr| {
            const py_list = c.PyList_New(@intCast(arr.items.len));
            if (py_list == null) {
                handlePythonError();
                return PythonError.RuntimeError;
            }

            for (arr.items, 0..) |item, i| {
                const py_item = try jsonToPyObject(allocator, item);
                // PyList_SetItem steals a reference, so no DECREF
                if (c.PyList_SetItem(py_list, @intCast(i), py_item) < 0) {
                    c.Py_DECREF(py_list);
                    handlePythonError();
                    return PythonError.RuntimeError;
                }
            }

            return py_list;
        },
        .object => |obj| {
            const py_dict = c.PyDict_New();
            if (py_dict == null) {
                handlePythonError();
                return PythonError.RuntimeError;
            }

            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try toPyString(entry.key_ptr.*);
                defer c.Py_DECREF(key);

                const value = try jsonToPyObject(allocator, entry.value_ptr.*);
                defer c.Py_DECREF(value);

                if (c.PyDict_SetItem(py_dict, key, value) < 0) {
                    c.Py_DECREF(py_dict);
                    handlePythonError();
                    return PythonError.RuntimeError;
                }
            }

            return py_dict;
        },
    }
}

/// Convert a Python object to a JSON value
pub fn pyObjectToJson(allocator: Allocator, py_obj: *c.PyObject) !std.json.Value {
    if (c.PyBool_Check(py_obj) != 0) {
        return std.json.Value{ .bool = py_obj == c.Py_True };
    } else if (c.PyLong_Check(py_obj) != 0) {
        const value = c.PyLong_AsLongLong(py_obj);
        if (value == -1 and c.PyErr_Occurred() != null) {
            handlePythonError();
            return PythonError.ValueError;
        }
        return std.json.Value{ .integer = value };
    } else if (c.PyFloat_Check(py_obj) != 0) {
        const value = c.PyFloat_AsDouble(py_obj);
        if (value == -1.0 and c.PyErr_Occurred() != null) {
            handlePythonError();
            return PythonError.ValueError;
        }
        return std.json.Value{ .float = value };
    } else if (c.PyUnicode_Check(py_obj) != 0) {
        const str = try fromPyString(allocator, py_obj);
        return std.json.Value{ .string = str };
    } else if (c.PyBytes_Check(py_obj) != 0) {
        var size: c_long = undefined;
        var bytes_ptr: [*c]u8 = undefined;
        const result = c.PyBytes_AsStringAndSize(py_obj, &bytes_ptr, &size);
        if (result < 0) {
            handlePythonError();
            return PythonError.ValueError;
        }
        const data = try allocator.dupe(u8, bytes_ptr[0..@intCast(size)]);
        return std.json.Value{ .string = data };
    } else if (c.PyList_Check(py_obj) != 0 or c.PyTuple_Check(py_obj) != 0) {
        const size = if (c.PyList_Check(py_obj) != 0)
            c.PyList_Size(py_obj)
        else
            c.PyTuple_Size(py_obj);

        if (size < 0) {
            handlePythonError();
            return PythonError.RuntimeError;
        }

        var array = std.json.Value{
            .array = std.json.Array.init(allocator),
        };

        var i: c_long = 0;
        while (i < size) : (i += 1) {
            const item = if (c.PyList_Check(py_obj) != 0)
                c.PyList_GetItem(py_obj, i)
            else
                c.PyTuple_GetItem(py_obj, i);

            if (item == null) {
                array.deinit(allocator);
                handlePythonError();
                return PythonError.RuntimeError;
            }

            // These are borrowed references, no DECREF needed
            const json_item = try pyObjectToJson(allocator, item);
            try array.array.append(json_item);
        }

        return array;
    } else if (c.PyDict_Check(py_obj) != 0) {
        var object = std.json.Value{
            .object = std.json.ObjectMap.init(allocator),
        };

        const pos = 0;
        var key: ?*c.PyObject = undefined;
        var value: ?*c.PyObject = undefined;

        while (c.PyDict_Next(py_obj, &pos, &key, &value) != 0) {
            if (key == null or value == null) continue;

            if (c.PyUnicode_Check(key.?) == 0) {
                object.deinit(allocator);
                return PythonError.TypeError;
            }

            const key_str = try fromPyString(allocator, key.?);
            const json_value = try pyObjectToJson(allocator, value.?);

            try object.object.put(key_str, json_value);
        }

        return object;
    } else if (py_obj == c.Py_None) {
        return std.json.Value{ .null = {} };
    } else {
        return PythonError.TypeError;
    }
}

/// Function to be called from Python's receive() callable
fn pyReceiveCallback(self: *c.PyObject, args: *c.PyObject) callconv(.C) ?*c.PyObject {
    // Expecting self to be a pointer to a Message Queue
    if (c.PyCapsule_CheckExact(self) == 0) {
        _ = c.PyErr_SetString(c.PyExc_TypeError, "Expected a capsule as self");
        return null;
    }

    const queue_ptr = c.PyCapsule_GetPointer(self, "MessageQueue");
    if (queue_ptr == null) {
        return null;
    }

    const queue = @ptrCast(*@import("../asgi/protocol.zig").MessageQueue, @alignCast(@alignOf(*@import("../asgi/protocol.zig").MessageQueue), queue_ptr));

    // Create async task for awaiting
    const asyncio = c.PyImport_ImportModule("asyncio");
    if (asyncio == null) {
        _ = c.PyErr_SetString(c.PyExc_ImportError, "Failed to import asyncio");
        return null;
    }
    defer c.Py_DECREF(asyncio);

    const create_task = c.PyObject_GetAttrString(asyncio, "create_task");
    if (create_task == null) {
        _ = c.PyErr_SetString(c.PyExc_AttributeError, "Failed to get create_task");
        return null;
    }
    defer c.Py_DECREF(create_task);

    // Create a Future to handle asynchronous receive
    const future_type = c.PyObject_GetAttrString(asyncio, "Future");
    if (future_type == null) {
        _ = c.PyErr_SetString(c.PyExc_AttributeError, "Failed to get Future");
        return null;
    }
    defer c.Py_DECREF(future_type);

    const future = c.PyObject_CallObject(future_type, null);
    if (future == null) {
        return null;
    }

    // Spawn a separate thread to wait for the message
    const thread_state = c.PyEval_SaveThread();

    // Receive message (this will block until a message is available)
    const message = queue.receive() catch {
        c.PyEval_RestoreThread(thread_state);
        _ = c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to receive message from queue");
        c.Py_DECREF(future);
        return null;
    };

    c.PyEval_RestoreThread(thread_state);

    // Convert to Python dict
    const gpa = std.heap.c_allocator;
    const py_message = jsonToPyObject(gpa, message) catch {
        _ = c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to convert message to Python object");
        c.Py_DECREF(future);
        return null;
    };

    // Set the result on the future
    const set_result = c.PyObject_GetAttrString(future, "set_result");
    if (set_result == null) {
        c.Py_DECREF(py_message);
        c.Py_DECREF(future);
        return null;
    }
    defer c.Py_DECREF(set_result);

    const result = c.PyObject_CallFunctionObjArgs(set_result, py_message, null);
    c.Py_DECREF(py_message);

    if (result == null) {
        c.Py_DECREF(future);
        return null;
    }
    c.Py_DECREF(result);

    return future;
}

/// Function to be called from Python's send() callable
fn pySendCallback(self: *c.PyObject, args: *c.PyObject) callconv(.C) ?*c.PyObject {
    // Ensure we have exactly one argument
    if (c.PyTuple_Size(args) != 1) {
        _ = c.PyErr_SetString(c.PyExc_TypeError, "Expected exactly one argument");
        return null;
    }

    // Expecting self to be a pointer to a Message Queue
    if (c.PyCapsule_CheckExact(self) == 0) {
        _ = c.PyErr_SetString(c.PyExc_TypeError, "Expected a capsule as self");
        return null;
    }

    const queue_ptr = c.PyCapsule_GetPointer(self, "MessageQueue");
    if (queue_ptr == null) {
        return null;
    }

    const queue = @ptrCast(*@import("../asgi/protocol.zig").MessageQueue, @alignCast(@alignOf(*@import("../asgi/protocol.zig").MessageQueue), queue_ptr));

    // Get the message argument
    const message = c.PyTuple_GetItem(args, 0);
    if (message == null) {
        return null;
    }

    // Convert to JSON
    const gpa = std.heap.c_allocator;
    const json_message = pyObjectToJson(gpa, message) catch {
        _ = c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to convert message to JSON");
        return null;
    };

    // Create async task for awaiting
    const asyncio = c.PyImport_ImportModule("asyncio");
    if (asyncio == null) {
        _ = c.PyErr_SetString(c.PyExc_ImportError, "Failed to import asyncio");
        return null;
    }
    defer c.Py_DECREF(asyncio);

    // Create a Future to handle asynchronous send
    const future_type = c.PyObject_GetAttrString(asyncio, "Future");
    if (future_type == null) {
        _ = c.PyErr_SetString(c.PyExc_AttributeError, "Failed to get Future");
        return null;
    }
    defer c.Py_DECREF(future_type);

    const future = c.PyObject_CallObject(future_type, null);
    if (future == null) {
        return null;
    }

    // Push the message to the queue
    queue.push(json_message) catch {
        _ = c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to push message to queue");
        c.Py_DECREF(future);
        return null;
    };

    // Set the result on the future to None (indicating success)
    const set_result = c.PyObject_GetAttrString(future, "set_result");
    if (set_result == null) {
        c.Py_DECREF(future);
        return null;
    }
    defer c.Py_DECREF(set_result);

    c.Py_INCREF(c.Py_None);
    const result = c.PyObject_CallFunctionObjArgs(set_result, c.Py_None, null);
    if (result == null) {
        c.Py_DECREF(future);
        return null;
    }
    c.Py_DECREF(result);

    return future;
}

/// Create a Python receive callable for ASGI
pub fn createReceiveCallable(queue: *@import("../asgi/protocol.zig").MessageQueue) !*c.PyObject {
    // Create capsule to hold the queue pointer
    const capsule = c.PyCapsule_New(queue, "MessageQueue", null);
    if (capsule == null) {
        handlePythonError();
        return PythonError.RuntimeError;
    }

    // Create method definition
    const method_def = c.PyMethodDef{
        .ml_name = "receive",
        .ml_meth = @ptrCast(c.PyCFunction, pyReceiveCallback),
        .ml_flags = c.METH_NOARGS,
        .ml_doc = "ASGI receive callable",
    };

    // Create function object for receive
    const py_func = c.PyCFunction_New(&method_def, capsule);

    if (py_func == null) {
        c.Py_DECREF(capsule);
        handlePythonError();
        return PythonError.RuntimeError;
    }

    return py_func;
}

/// Create a Python send callable for ASGI
pub fn createSendCallable(queue: *@import("../asgi/protocol.zig").MessageQueue) !*c.PyObject {
    // Create capsule to hold the queue pointer
    const capsule = c.PyCapsule_New(queue, "MessageQueue", null);
    if (capsule == null) {
        handlePythonError();
        return PythonError.RuntimeError;
    }

    // Create method definition
    const method_def = c.PyMethodDef{
        .ml_name = "send",
        .ml_meth = @ptrCast(c.PyCFunction, pySendCallback),
        .ml_flags = c.METH_VARARGS,
        .ml_doc = "ASGI send callable",
    };

    // Create function object for send
    const py_func = c.PyCFunction_New(&method_def, capsule);

    if (py_func == null) {
        c.Py_DECREF(capsule);
        handlePythonError();
        return PythonError.RuntimeError;
    }

    return py_func;
}

/// Call an ASGI application with scope, receive, and send
pub fn callAsgiApplication(app: *c.PyObject, scope: *c.PyObject, receive: *c.PyObject, send: *c.PyObject) !void {
    // Create arguments tuple (app(scope, receive, send))
    const args = c.PyTuple_New(3);
    if (args == null) {
        handlePythonError();
        return PythonError.RuntimeError;
    }
    defer c.Py_DECREF(args);

    // Incref to counteract the stolen references
    c.Py_INCREF(scope);
    c.Py_INCREF(receive);
    c.Py_INCREF(send);

    if (c.PyTuple_SetItem(args, 0, scope) < 0 or
        c.PyTuple_SetItem(args, 1, receive) < 0 or
        c.PyTuple_SetItem(args, 2, send) < 0)
    {
        handlePythonError();
        return PythonError.RuntimeError;
    }

    // Call the application
    const result = c.PyObject_Call(app, args, null);
    if (result == null) {
        handlePythonError();
        return PythonError.CallFailed;
    }

    // Handle coroutine case (async def app)
    if (c.PyCoro_CheckExact(result) != 0) {
        // We need to run this coroutine - import asyncio
        const asyncio = c.PyImport_ImportModule("asyncio");
        if (asyncio == null) {
            c.Py_DECREF(result);
            handlePythonError();
            return PythonError.RuntimeError;
        }
        defer c.Py_DECREF(asyncio);

        // Get asyncio.run
        const run_func = c.PyObject_GetAttrString(asyncio, "run");
        if (run_func == null) {
            c.Py_DECREF(result);
            handlePythonError();
            return PythonError.RuntimeError;
        }
        defer c.Py_DECREF(run_func);

        // Run the coroutine
        const run_args = c.PyTuple_New(1);
        if (run_args == null) {
            c.Py_DECREF(result);
            handlePythonError();
            return PythonError.RuntimeError;
        }
        defer c.Py_DECREF(run_args);

        // PyTuple_SetItem steals a reference
        if (c.PyTuple_SetItem(run_args, 0, result) < 0) {
            c.Py_DECREF(result);
            handlePythonError();
            return PythonError.RuntimeError;
        }

        const run_result = c.PyObject_Call(run_func, run_args, null);
        if (run_result == null) {
            handlePythonError();
            return PythonError.CallFailed;
        }
        c.Py_DECREF(run_result);
    } else {
        c.Py_DECREF(result);
    }
}
