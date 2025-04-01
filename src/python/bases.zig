const std = @import("std");
const Allocator = std.mem.Allocator;
const python = @import("python_wrapper");
const thread = std.Thread;
const protocol = @import("protocol");

// Export the PyObject type for external use
pub const PyObject = python.og.PyObject;
const PyTypeObject = python.og.PyTypeObject;

// Helper function to replace all Py_INCREF and Py_DECREF calls throughout the file
pub fn incref(obj: *PyObject) void {
    python.og.Py_INCREF(obj);
}

pub fn decref(obj: *PyObject) void {
    python.og.Py_DECREF(obj);
}

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
pub fn handlePythonError() void {
    if (python.og.PyErr_Occurred() != null) {
        python.og.PyErr_Print();
        python.og.PyErr_Clear();
    }
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
