const std = @import("std");
const Allocator = std.mem.Allocator;
const python = @import("python_wrapper");

// Re-export the python module as 'c' for compatibility with tests
// pub const c = python;

// Import ASGI protocol module - use the module name defined in build.zig
const protocol = @import("protocol");

// Export the PyObject type for external use
pub const PyObject = python.og.PyObject;
const PyTypeObject = python.og.PyTypeObject;

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

pub fn PyGILState_Ensure() python.og.PyGILState_STATE {
    return python.og.PyGILState_Ensure();
}

pub fn PyGILState_Release(gil_state: python.og.PyGILState_STATE) void {
    return python.og.PyGILState_Release(gil_state);
}

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

pub fn asgi_receive_vectorcall(callable: [*c]?*python.PyObject, args: [*c]?*python.PyObject, nargs: usize) callconv(.C) *python.PyObject {
    _ = nargs;

    const receive_obj = @as(*ReceiveObject, @ptrCast(callable.?));
    const queue = receive_obj.queue.?;

    std.debug.print("DEBUG: In asgi_receive_vectorcall, queue: {*}\n", .{queue});
    std.debug.print("DEBUG: In asgi_receive_vectorcall, callable: {*}\n", .{callable});
    std.debug.print("DEBUG: In asgi_receive_vectorcall, args: {*}\n", .{args});

    const body = "{ \"message\": \"Hello from Zig!\" }";

    const dict = python.og.PyDict_New();
    if (dict == null) return python.getPyNone();
    _ = python.og.PyDict_SetItemString(dict, "type", python.og.PyUnicode_FromString("http.request"));
    _ = python.og.PyDict_SetItemString(dict, "body", python.og.PyBytes_FromString(body));

    return dict;
}

pub fn handle_send_message(message: [*c]python.PyObject) void {
    std.debug.print("DEBUG: Received message: {*}\n", .{message});
    // const event_type_str = python.og.PyUnicode_AsUTF8(message);
    // const event_type = python.og.PyDict_GetItemString(event_type_str, "type");
    // std.debug.print("DEBUG: Received event type: {s}\n", .{event_type});
    // if (std.mem.eql(u8, event_type_str, "http.response.start")) {
    //     std.debug.print("Received response headers\n", .{});
    // }
}

pub fn asgi_send_vectorcall(callable: [*c]?*python.PyObject, args: [*c]?*python.PyObject, nargs: usize) callconv(.C) *python.PyObject {
    _ = callable;
    _ = nargs;

    std.debug.print("DEBUG: In asgi_send_vectorcall, \n", .{});

    // NOTE: Checks if args is null, then sets an error and returns None
    // Otherwise, gets the first item from the tuple and checks if it's null, then sets an error and returns None
    if (args) |arg| {
        // Cast arg to a non-optional pointer before passing to PyTuple_GetItem
        const arg_non_opt = @as([*c]python.PyObject, @ptrCast(arg));
        const message = python.og.PyTuple_GetItem(arg_non_opt, 0);
        if (message == null) {
            std.debug.print("DEBUG: Message is null\n", .{});
            return python.getPyNone();
        }

        handle_send_message(message);
    } else {
        _ = python.og.PyErr_SetString(python.PyExc_TypeError, "Expected exactly one argument");
        return python.getPyNone();
    }

    return python.getPyNone();
}

// Define a struct for the receive callable that includes the queue pointer
pub const ReceiveObject = extern struct {
    // PyObject header must come first
    ob_base: python.PyObject,
    // Custom data follows
    queue: ?*protocol.MessageQueue,
};

// TODO: tp_name
var ReceiveType = PyTypeObject{
    .ob_base = undefined,
    .tp_name = "ReceiveCallable",
    .tp_basicsize = @sizeOf(ReceiveObject),
    .tp_itemsize = 0,
    .tp_flags = python.og.Py_TPFLAGS_DEFAULT,
    .tp_call = @ptrCast(&asgi_receive_vectorcall),
    .tp_doc = python.og.PyDoc_STR("Receive a message from the queue"),
};

pub fn create_receive_vectorcall_callable(queue: *protocol.MessageQueue) !*python.PyObject {
    if (python.og.PyType_Ready(&ReceiveType) < 0) return error.PythonTypeInitFailed;

    // Use PyType_GenericAlloc to create an instance of the type
    const instance = python.og.PyType_GenericAlloc(@ptrCast(&ReceiveType), 0);
    if (instance == null) return error.PythonAllocationFailed;

    // Cast to our custom object type to access the queue field
    const receive_obj = @as(*ReceiveObject, @ptrCast(instance));
    receive_obj.queue = queue;

    // Return as a PyObject*
    return @as(*python.PyObject, @ptrCast(receive_obj));
}

var SendType = PyTypeObject{
    .ob_base = undefined,
    .tp_name = "SendCallable",
    .tp_basicsize = @sizeOf(python.PyObject),
    .tp_itemsize = 0,
    .tp_flags = python.og.Py_TPFLAGS_DEFAULT,
    .tp_call = @ptrCast(&asgi_send_vectorcall),
};

pub fn create_send_vectorcall_callable(queue: *protocol.MessageQueue) !*python.PyObject {
    _ = queue; // Unused
    if (python.og.PyType_Ready(&SendType) < 0) return error.PythonTypeInitFailed;

    // Use PyType_GenericAlloc to create an instance of the type
    // This is the correct way to instantiate a Python type object
    const instance = python.og.PyType_GenericAlloc(@ptrCast(&ReceiveType), 0);
    if (instance == null) return error.PythonAllocationFailed;

    return instance;
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

    // Set the tuple items - PyTuple_SetItem steals references
    python.incref(scope);
    python.incref(receive);
    python.incref(send);

    if (python.og.PyTuple_SetItem(args.?, 0, scope) < 0 or
        python.og.PyTuple_SetItem(args.?, 1, receive) < 0 or
        python.og.PyTuple_SetItem(args.?, 2, send) < 0)
    {
        std.debug.print("DEBUG: Failed to set values in tuple\n", .{});
        python.decref(args.?);
        handlePythonError();
        return PythonError.RuntimeError;
    }

    std.debug.print("DEBUG: Calling PyObject_CallObject\n", .{});
    const coroutine = python.og.PyObject_CallObject(app, args.?);
    python.decref(args.?);

    if (coroutine == null) {
        std.debug.print("DEBUG: Call failed\n", .{});
        handlePythonError();
        return PythonError.CallFailed;
    }
    std.debug.print("DEBUG: Call succeeded of asgi app, got coroutine: {*}\n", .{coroutine.?});

    // Import asyncio to run the coroutine
    const asyncio = python.og.PyImport_ImportModule("asyncio");
    if (asyncio == null) {
        python.decref(coroutine.?);
        handlePythonError();
        return PythonError.ModuleNotFound;
    }
    defer python.decref(asyncio.?);

    // Get the run_coroutine_threadsafe function
    const run_coro = python.og.PyObject_GetAttrString(asyncio.?, "run");
    if (run_coro == null) {
        python.decref(coroutine.?);
        handlePythonError();
        return PythonError.AttributeNotFound;
    }
    defer python.decref(run_coro.?);

    // Create args for run_coroutine_threadsafe
    const run_args = python.og.PyTuple_New(1);
    if (run_args == null) {
        python.decref(coroutine.?);
        handlePythonError();
        return PythonError.RuntimeError;
    }

    // PyTuple_SetItem steals the reference
    if (python.og.PyTuple_SetItem(run_args.?, 0, coroutine.?) < 0) {
        python.decref(coroutine.?);
        python.decref(run_args.?);
        handlePythonError();
        return PythonError.RuntimeError;
    }

    // Call asyncio.run(coroutine)
    const result = python.og.PyObject_CallObject(run_coro.?, run_args.?);
    python.decref(run_args.?);

    if (result == null) {
        std.debug.print("DEBUG: asyncio.run failed\n", .{});
        handlePythonError();
        return PythonError.CallFailed;
    }

    std.debug.print("DEBUG: asyncio.run succeeded, result: {*}\n", .{result.?});
    python.decref(result.?);

    std.debug.print("DEBUG: ASGI application call completed\n", .{});
    return;
}

// Helper function to replace all Py_INCREF and Py_DECREF calls throughout the file
pub fn incref(obj: *PyObject) void {
    python.og.Py_INCREF(obj);
}

pub fn decref(obj: *PyObject) void {
    python.og.Py_DECREF(obj);
}

// NOTE: We are only keeping below here for reference
// TODO: Remove when the above vectorcall functions are working

/// Function to be called from Python's receive() callable
fn pyReceiveCallback(self: *PyObject, args: *PyObject) callconv(.C) ?*PyObject {
    _ = args; // Unused
    std.debug.print("\nDEBUG: pyReceiveCallback called with\n", .{});

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
    std.debug.print("DEBUG: Queue: {*}\n", .{queue});

    // Create async task for awaiting
    const asyncio = python.og.PyImport_ImportModule("asyncio");
    if (asyncio == null) {
        _ = python.PyErr_SetString(python.PyExc_ImportError, "Failed to import asyncio");
        return null;
    }
    defer decref(asyncio.?);

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
    std.debug.print("DEBUG: Received message: {*}\n", .{message});

    // Restore the thread state breaks when using python.og.PyEval_RestoreThread
    python.PyEval_RestoreThread(thread_state);

    // Create Python dictionary directly instead of using JSON conversion
    const py_dict = python.og.PyDict_New();
    if (py_dict == null) {
        decref(future.?);
        return null;
    }

    // Add "type": "lifespan.startup" to the dict
    const type_key = python.og.PyUnicode_FromString("type");
    if (type_key == null) {
        decref(py_dict.?);
        decref(future.?);
        return null;
    }

    const type_val = python.og.PyUnicode_FromString("lifespan.startup");
    if (type_val == null) {
        decref(type_key.?);
        decref(py_dict.?);
        decref(future.?);
        return null;
    }

    if (python.og.PyDict_SetItem(py_dict.?, type_key.?, type_val.?) < 0) {
        decref(type_val.?);
        decref(type_key.?);
        decref(py_dict.?);
        decref(future.?);
        return null;
    }

    // We can decref these now as PyDict_SetItem increases their refcounts
    decref(type_val.?);
    decref(type_key.?);

    // Set the result on the future
    const set_result = python.og.PyObject_GetAttrString(future.?, "set_result");
    if (set_result == null) {
        decref(py_dict.?);
        decref(future.?);
        return null;
    }
    defer decref(set_result.?);

    // Set the result with our message
    const result = python.zig_call_function_with_arg(set_result.?, py_dict.?);
    decref(py_dict.?);

    if (result == null) {
        decref(future.?);
        return null;
    }
    decref(result.?);

    std.debug.print("DEBUG: pyReceiveCallback returning future: {*}\n", .{future.?});
    return future;
}

/// Function to be called from Python's send() callable
fn pySendCallback(self: *PyObject, args: *PyObject) callconv(.C) ?*PyObject {
    // Note: we're not using self parameter for now to avoid bus errors

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
    std.debug.print("DEBUG: Queue: {*}\n", .{queue});

    // We won't try to access the queue directly for now, as that was causing the bus error
    // Instead we'll just acknowledge the message for the lifespan protocol

    // Get the message argument - this is just a borrowed reference
    const message = python.og.PyTuple_GetItem(args, 0);
    if (message == null) {
        return null;
    }

    // For debugging only - print the message type
    if (python.og.PyDict_Check(message.?) != 0) {
        const type_key = python.og.PyUnicode_FromString("type");
        if (type_key != null) {
            const type_val = python.og.PyDict_GetItem(message.?, type_key.?);
            if (type_val != null and python.og.PyUnicode_Check(type_val.?) != 0) {
                const utf8 = python.og.PyUnicode_AsUTF8(type_val.?);
                if (utf8 != null) {
                    std.debug.print("DEBUG: Python send received message type: {s}\n", .{utf8.?});
                }
            }
            decref(type_key.?);
        }
    }

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

    // Import types module to get coroutine decorator
    const types = python.og.PyImport_ImportModule("types");
    if (types == null) {
        // decref(capsule.?);
        handlePythonError();
        return PythonError.ModuleNotFound;
    }
    defer decref(types.?);

    std.debug.print("DEBUG: Creating method definitions!\n", .{});
    // Create method definition that will stay in scope
    var method_def = python.og.PyMethodDef{
        .ml_name = "receive",
        .ml_meth = @ptrCast(&pyReceiveCallback),
        .ml_flags = python.og.METH_VARARGS,
        .ml_doc = "ASGI receive callable",
    };

    std.debug.print("DEBUG: Creating function object!\n", .{});
    // Create a function that returns a future
    const py_func = python.og.PyCFunction_New(&method_def, null);
    if (py_func == null) {
        // decref(capsule.?);
        handlePythonError();
        return PythonError.RuntimeError;
    }

    // Get the coroutine decorator from types module
    const coroutine_decorator = python.og.PyObject_GetAttrString(types.?, "coroutine");
    if (coroutine_decorator == null) {
        decref(py_func.?);
        // decref(capsule.?);
        handlePythonError();
        return PythonError.RuntimeError;
    }
    defer decref(coroutine_decorator.?);

    // Create a tuple with one argument (our function)
    const args = python.og.PyTuple_New(1);
    if (args == null) {
        decref(py_func.?);
        // decref(capsule.?);
        handlePythonError();
        return PythonError.RuntimeError;
    }
    defer decref(args.?);

    // PyTuple_SetItem steals a reference, so we need to incref py_func
    python.incref(py_func.?);
    if (python.og.PyTuple_SetItem(args.?, 0, py_func.?) < 0) {
        decref(py_func.?);
        // decref(capsule.?);
        handlePythonError();
        return PythonError.RuntimeError;
    }

    std.debug.print("DEBUG: Creating wrapped function!\n", .{});
    // Create the coroutine by calling the decorator with our function as a tuple argument
    const wrapped_func = python.og.PyObject_CallObject(coroutine_decorator.?, args.?);
    if (wrapped_func == null) {
        decref(py_func.?);
        // decref(capsule.?);
        handlePythonError();
        return PythonError.RuntimeError;
    }

    // Clean up the original function since we now have the wrapped version
    decref(py_func.?);
    std.debug.print("DEBUG: Returning wrapped function!\n", .{});
    return wrapped_func.?;
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
