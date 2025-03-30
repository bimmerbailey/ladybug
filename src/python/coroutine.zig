const std = @import("std");
const py = @import("python_wrapper");
const c = py.og;

// Coroutine state structure
pub const ASGICoroutine = struct {
    py_coro: *py.PyObject,

    // Initialize the coroutine wrapper
    pub fn init(py_coro: *py.PyObject) ASGICoroutine {
        return ASGICoroutine{
            .py_coro = py_coro,
        };
    }

    // Send method to pass data to the Python coroutine
    pub fn send(self: *ASGICoroutine, data: []const u8) !void {
        // Create a Python bytes object from the data
        const py_data = py.PyBytes_FromStringAndSize(@ptrCast(data.ptr), @intCast(data.len));
        defer py.Py_DECREF(py_data);

        // Call the send method of the coroutine
        const send_method = py.PyObject_GetAttrString(self.py_coro, "send");
        defer py.Py_XDECREF(send_method);

        if (send_method == null) {
            return error.MethodNotFound;
        }

        // Call send method
        const result = py.PyObject_CallOneArg(send_method, py_data);
        defer py.Py_XDECREF(result);

        // Check for Python exceptions
        if (result == null) {
            py.PyErr_Print();
            return error.PythonException;
        }
    }

    // Receive method to get data from the Python coroutine
    pub fn receive(self: *ASGICoroutine) ![]const u8 {
        // Call the receive method of the coroutine
        const recv_method = py.PyObject_GetAttrString(self.py_coro, "receive");
        defer py.Py_XDECREF(recv_method);

        if (recv_method == null) {
            return error.MethodNotFound;
        }

        // Call receive method
        const result = py.PyObject_CallNoArgs(recv_method);
        defer py.Py_XDECREF(result);

        // Check for Python exceptions
        if (result == null) {
            py.PyErr_Print();
            return error.PythonException;
        }

        // Convert result to bytes
        if (!py.PyBytes_Check(result)) {
            return error.InvalidReturnType;
        }

        const data_ptr = py.PyBytes_AsString(result);
        const data_len = py.PyBytes_Size(result);

        return data_ptr[0..@intCast(data_len)];
    }

    // Close the coroutine
    pub fn close(self: *ASGICoroutine) !void {
        // Call the close method of the coroutine
        const close_method = py.PyObject_GetAttrString(self.py_coro, "close");
        defer py.Py_XDECREF(close_method);

        if (close_method == null) {
            return error.MethodNotFound;
        }

        // Call close method
        const result = py.PyObject_CallNoArgs(close_method);
        defer py.Py_XDECREF(result);

        // Check for Python exceptions
        if (result == null) {
            py.PyErr_Print();
            return error.PythonException;
        }
    }
};

// Example C function to create a coroutine wrapper
pub export fn create_asgi_coroutine(self: [*c]py.PyObject, args: [*c]py.PyObject) callconv(.C) [*c]py.PyObject {
    _ = self;
    // Expect a Python coroutine object
    var py_coro: *py.PyObject = undefined;

    // Parse input arguments
    if (c.PyArg_ParseTuple(args, "O", &py_coro) == 0) {
        return py.getPyNone();
    }

    // Check if the object is a coroutine
    if (c.PyCoro_CheckExact(py_coro) == 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Argument must be a Python coroutine");
        return py.getPyNone();
    }

    // Create a capsule to hold the coroutine
    return c.PyCapsule_New(py_coro, "ASGI_COROUTINE", null);
}

// Module methods
const ModuleMethods = [_]c.PyMethodDef{
    c.PyMethodDef{
        .ml_name = "wrap_asgi_coroutine",
        .ml_meth = @ptrCast(create_asgi_coroutine),
        .ml_flags = c.METH_VARARGS,
        .ml_doc = "Wrap a Python ASGI coroutine",
    },
    c.PyMethodDef{ // Sentinel
        .ml_name = null,
        .ml_meth = null,
        .ml_flags = 0,
        .ml_doc = null,
    },
};

// Module definition
var module_def = c.PyModuleDef{
    .m_base = py.PyModuleDef_HEAD_INIT,
    .m_name = "asgi_wrapper",
    .m_doc = null,
    .m_size = -1,
    .m_methods = &ModuleMethods[0],
    .m_slots = null,
    .m_traverse = null,
    .m_clear = null,
    .m_free = null,
};

// Module initialization function
pub export fn PyInit_asgi_wrapper() *py.PyObject {
    return c.PyModule_Create(&module_def);
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

fn handlePythonError() void {
    if (c.PyErr_Occurred() != null) {
        c.PyErr_Print();
        c.PyErr_Clear();
    }
}

fn toPyString(string: []const u8) !*c.PyObject {
    const py_string = c.PyUnicode_FromStringAndSize(string.ptr, @intCast(string.len));
    if (py_string == null) {
        handlePythonError();
        return PythonError.ValueError;
    }
    return py_string;
}

pub fn CreateCoro(name: []const u8) *c.PyObject {
    const py_name = toPyString(name) catch return py.getPyNone();
    // Get the frame type from Python
    const frame_type = c.PyFrame_Type;
    // Create a new frame object
    const frame = c.PyFrame_Type{ c.PyThreadState_Get(), frame_type, py_name, null };
    if (frame == null) {
        return py.getPyNone();
    }
    return c.PyCoro_New(py_name, py_name);
}
