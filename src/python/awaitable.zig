const std = @import("std");
const python = @import("python_wrapper");
const PyObject = python.PyObject;
const PyTypeObject = python.PyTypeObject;

// Custom object structure for our awaitable
pub const PyAwaitableObject = extern struct {
    ob_base: PyObject,
    // Add any custom data fields here
    value: ?*PyObject,
};

// __await__ method implementation
fn awaitable_await(self: [*c]PyObject) callconv(.C) [*c]PyObject {
    // Return self as an iterator
    python.incref(self);
    return self;
}

// __iter__ method implementation
fn awaitable_iter(self: [*c]PyObject) callconv(.C) [*c]PyObject {
    // Return self as an iterator
    python.incref(self);
    return self;
}

// __next__ method implementation
fn awaitable_next(self: [*c]PyObject) callconv(.C) ?*PyObject {
    const awaitable = @as(*PyAwaitableObject, @ptrCast(@alignCast(self)));

    // If we have a value, return it and clear it
    if (awaitable.value) |value| {
        awaitable.value = null;
        return value;
    }

    // Otherwise raise StopIteration
    _ = python.og.PyErr_SetNone(python.og.PyExc_StopIteration);
    return null;
}

// Async methods structure
var AsyncMethods = python.og.PyAsyncMethods{
    .am_await = awaitable_await,
    .am_aiter = null,
    .am_anext = null,
};

// Type object for our awaitable
var AwaitableType = PyTypeObject{
    .ob_base = undefined,
    .tp_name = "AwaitableObject",
    .tp_basicsize = @sizeOf(PyAwaitableObject),
    .tp_itemsize = 0,
    .tp_flags = python.og.Py_TPFLAGS_DEFAULT | python.og.Py_am_await,
    .tp_as_async = @ptrCast(&AsyncMethods),
    .tp_iter = awaitable_iter,
    .tp_iternext = awaitable_next,
    .tp_doc = python.og.PyDoc_STR("Custom awaitable object"),
    .tp_new = null,
    .tp_dealloc = null,
    .tp_traverse = null,
    .tp_clear = null,
};

/// Create a new awaitable object that will yield the given value
/// Returns null and sets Python error on failure
pub fn createAwaitable(value: ?*PyObject) ?*PyObject {
    // Initialize the type if not already done
    if (python.og.PyType_Ready(&AwaitableType) < 0) {
        _ = python.og.PyErr_SetString(python.og.PyExc_RuntimeError, "Failed to initialize awaitable type");
        return null;
    }

    // Create a new instance
    const instance = python.og.PyType_GenericAlloc(@ptrCast(&AwaitableType), 0);
    if (instance == null) {
        _ = python.og.PyErr_SetString(python.og.PyExc_RuntimeError, "Failed to allocate awaitable object");
        return null;
    }

    // Cast to our custom object type and set the value
    const awaitable = @as(*PyAwaitableObject, @ptrCast(@alignCast(instance)));
    if (value) |v| {
        python.incref(v);
    }
    awaitable.value = value;

    // Return the instance directly as it's already a PyObject*
    return instance;
}
