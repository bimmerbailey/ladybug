const std = @import("std");
const Allocator = std.mem.Allocator;
const python = @import("python_wrapper");
const thread = std.Thread;
pub const base = @import("bases.zig");
pub const event_loop = @import("event_loop.zig");

// Import ASGI protocol module - use the module name defined in build.zig
const protocol = @import("protocol");

// Export the PyObject type for external use
pub const PyObject = python.og.PyObject;
const PyTypeObject = python.og.PyTypeObject;
const decref = base.decref;
const handlePythonError = base.handlePythonError;
const PythonError = base.PythonError;
pub const c = base.c;

/// Load a Python ASGI application
pub fn loadApplication(module_path: []const u8, app_name: []const u8) !*python.PyObject {
    std.debug.print("DEBUG: Loading application\n", .{});
    // Import the module
    const module = try base.importModule(module_path);
    defer decref(module);

    // Get the application attribute
    const app = try base.getAttribute(module, app_name);

    // Ensure it's callable
    if (python.og.PyCallable_Check(app) == 0) {
        decref(app);
        return PythonError.InvalidApplication;
    }

    std.debug.print("DEBUG: Application loaded module: {s}, app: {s}\n", .{ module_path, app_name });
    return app;
}

// Define a struct for the receive callable that includes the queue pointer
pub const AsgiCallableObject = extern struct {
    // PyObject header must come first
    ob_base: PyObject,
    // Custom data follows
    queue: ?*protocol.MessageQueue,
    // Event loop to run tasks
    loop: *PyObject,
};

// TODO: Come back to this once more familiar
fn create_asgi_callable_object(name: [*c]const u8, doc: [*c]const u8, vectorcall: *fn ([*c]?*PyObject, [*c]?*PyObject, usize) callconv(.C) *python.PyObject) PyTypeObject {
    return PyTypeObject{
        .ob_base = undefined,
        .tp_name = name,
        .tp_basicsize = @sizeOf(AsgiCallableObject),
        .tp_itemsize = 0,
        .tp_flags = python.og.Py_TPFLAGS_DEFAULT | python.og.CO_COROUTINE,
        .tp_call = @ptrCast(vectorcall),
        .tp_doc = doc,
    };
}

pub fn asgi_receive_vectorcall(callable: [*c]?*python.PyObject, args: [*c]?*python.PyObject, nargs: usize) callconv(.C) *python.PyObject {
    _ = nargs;
    _ = args;

    const receive_obj = @as(*AsgiCallableObject, @ptrCast(callable.?));
    const queue = receive_obj.queue.?;
    const loop = receive_obj.loop;

    // Spawn a separate thread to wait for the message
    const thread_state = python.PyEval_SaveThread();

    // Receive message (this will block until a message is available)
    const message = queue.receive() catch {
        python.PyEval_RestoreThread(thread_state);
        _ = python.PyErr_SetString(python.PyExc_RuntimeError, "Failed to receive message from queue");
        return null;
    };
    std.debug.print("DEBUG: Received message from queue: {}\n", .{message});

    // Restore the thread state breaks when using python.og.PyEval_RestoreThread
    python.PyEval_RestoreThread(thread_state);

    // Convert to Python dict
    const gpa = std.heap.c_allocator;
    const py_message = base.jsonToPyObject(gpa, message) catch {
        _ = python.og.PyErr_SetString(python.PyExc_RuntimeError, "Failed to convert message to Python object");
        return python.og.PyDict_New();
    };

    // Call create_asgi_future_for_event_loop and check for errors explicitly
    const future_or_error = create_asgi_future_for_event_loop(py_message, loop);
    if (future_or_error) |future| {
        std.debug.print("DEBUG: asgi_receive_vectorcall returning future: {*}\n", .{future});
        return future;
    } else |err| {
        // Handle the error (e.g., set Python exception)
        std.debug.print("Error creating ASGI future: {}\n", .{err});
        _ = python.og.PyErr_SetString(python.PyExc_RuntimeError, "Failed to create future for event loop");
        return python.og.PyDict_New(); // Return empty dict for Python error
    }
}

// The await function: This gets called when `await receive()` is used
fn receive_await(self: [*c]python.PyObject) callconv(.C) [*c]python.PyObject {
    return self; // Return self to indicate it's an awaitable
}

var AsyncMethods = python.og.PyAsyncMethods{
    .am_await = receive_await,
    .am_aiter = python.og.PyObject_SelfIter,
    .am_anext = null,
};

// TODO: ,
var ReceiveType = PyTypeObject{
    .ob_base = undefined,
    .tp_name = "ReceiveCallable",
    .tp_basicsize = @sizeOf(AsgiCallableObject),
    .tp_itemsize = 0,
    .tp_flags = python.og.CO_COROUTINE,
    .tp_call = @ptrCast(&asgi_receive_vectorcall),
    .tp_as_async = @ptrCast(&AsyncMethods),
    .tp_doc = python.og.PyDoc_STR("Receive a message from the queue"),
};

pub fn create_receive_vectorcall_callable(queue: *protocol.MessageQueue, loop: *PyObject) !*python.PyObject {
    if (python.og.PyType_Ready(&ReceiveType) < 0) return error.PythonTypeInitFailed;

    // Use PyType_GenericAlloc to create an instance of the type
    const instance = python.og.PyType_GenericAlloc(@ptrCast(&ReceiveType), 0);
    if (instance == null) return error.PythonAllocationFailed;

    // Cast to our custom object type to access the queue field
    const receive_obj = @as(*AsgiCallableObject, @ptrCast(instance));
    receive_obj.queue = queue;
    receive_obj.loop = loop;

    // Return as a PyObject*
    return @as(*python.PyObject, @ptrCast(receive_obj));
}

pub fn asgi_send_vectorcall(callable: [*c]?*python.PyObject, args: [*c]?*python.PyObject, nargs: usize) callconv(.C) *python.PyObject {
    _ = nargs;

    const send_obj = @as(*AsgiCallableObject, @ptrCast(callable.?));
    const queue = send_obj.queue.?;
    const loop = send_obj.loop;
    std.debug.print("DEBUG: In asgi_send_vectorcall, queue: {*}\n", .{queue});

    // NOTE: Checks if args is null, then sets an error and returns None
    // Otherwise, gets the first item from the tuple and checks if it's null, then sets an error and returns None
    if (args) |arg| {
        // Cast arg to a non-optional pointer before passing to PyTuple_GetItem
        const arg_non_opt = @as([*c]python.PyObject, @ptrCast(arg));
        const message = python.og.PyTuple_GetItem(arg_non_opt, 0);
        if (message == null) {
            std.debug.print("DEBUG: Message is null\n", .{});
        } else {
            const gpa = std.heap.c_allocator;
            const json_message = base.pyObjectToJson(gpa, message) catch {
                _ = python.PyErr_SetString(python.PyExc_RuntimeError, "Failed to convert message to JSON");
                return python.getPyNone();
            };
            // Push the message to the queue
            queue.push(json_message) catch {
                _ = python.PyErr_SetString(python.PyExc_RuntimeError, "Failed to push message to queue");
            };
        }
    } else {
        _ = python.og.PyErr_SetString(python.PyExc_TypeError, "Expected exactly one argument");
    }

    const value = python.getPyNone();
    const future_or_error = create_asgi_future_for_event_loop(value, loop);
    if (future_or_error) |future| {
        std.debug.print("DEBUG: asgi_send_vectorcall returning future: {*}\n", .{future});
        return future;
    } else |err| {
        // Handle the error (e.g., set Python exception)
        std.debug.print("Error creating ASGI future: {}\n", .{err});
        _ = python.og.PyErr_SetString(python.PyExc_RuntimeError, "Failed to create future for event loop");
        return python.og.Py_None();
    }
}
var SendType = PyTypeObject{
    .ob_base = undefined,
    .tp_name = "SendCallable",
    .tp_basicsize = @sizeOf(AsgiCallableObject),
    .tp_itemsize = 0,
    .tp_flags = python.og.Py_TPFLAGS_DEFAULT,
    .tp_call = @ptrCast(&asgi_send_vectorcall),
    .tp_as_async = @ptrCast(&AsyncMethods),
    .tp_doc = python.og.PyDoc_STR("Send a message to the queue"),
};

pub fn create_send_vectorcall_callable(queue: *protocol.MessageQueue, loop: *PyObject) !*python.PyObject {
    if (python.og.PyType_Ready(&SendType) < 0) return error.PythonTypeInitFailed;

    // Use PyType_GenericAlloc to create an instance of the type
    const instance = python.og.PyType_GenericAlloc(@ptrCast(&SendType), 0);
    if (instance == null) return error.PythonAllocationFailed;

    // Cast to our custom object type to access the queue field
    const send_obj = @as(*AsgiCallableObject, @ptrCast(instance));
    send_obj.queue = queue;
    send_obj.loop = loop;
    // Return as a PyObject*
    return @as(*python.PyObject, @ptrCast(send_obj));
}

pub fn create_app_coroutine_for_event_loop(function: *PyObject, args: *PyObject, loop: *PyObject) !*PyObject {

    // Debug the send object type
    if (python.og.PyCallable_Check(function) == 0) {
        std.debug.print("DEBUG: send is not callable!\n", .{});
        handlePythonError();
        return PythonError.RuntimeError;
    }
    std.debug.print("DEBUG: send is callable\n", .{});
    std.debug.print("DEBUG: Calling PyObject_CallObject\n", .{});

    // NOTE: Calls object to create a coroutine
    const coroutine = python.og.PyObject_CallObject(function, args);
    python.decref(args);

    if (coroutine == null) {
        std.debug.print("DEBUG: Call failed\n", .{});
        handlePythonError();
        return PythonError.CallFailed;
    }

    const asyncio = try base.importModule("asyncio");
    defer python.decref(asyncio);

    // Get the run_coroutine_threadsafe function
    const run_coro = try base.getAttribute(asyncio, "run_coroutine_threadsafe");
    defer python.decref(run_coro);

    // Create args for run_coroutine_threadsafe - needs (coro, loop)
    const run_args = python.og.PyTuple_New(2);
    if (run_args == null) {
        python.decref(coroutine.?);
        handlePythonError();
        return PythonError.RuntimeError;
    }
    defer python.decref(run_args.?);

    // PyTuple_SetItem steals references
    if (python.og.PyTuple_SetItem(run_args.?, 0, coroutine.?) < 0 or
        python.og.PyTuple_SetItem(run_args.?, 1, loop) < 0)
    {
        python.decref(coroutine.?);
        python.decref(run_args.?);
        handlePythonError();
        return PythonError.RuntimeError;
    }

    // Run the coroutine in the event loop
    const future = python.og.PyObject_CallObject(run_coro, run_args.?);
    if (future == null) {
        std.debug.print("DEBUG: run_coroutine_threadsafe failed\n", .{});
        handlePythonError();
        return PythonError.CallFailed;
    }
    std.debug.print("DEBUG: run_coroutine_threadsafe succeeded, got future: {*}\n", .{future.?});

    // NOTE: Return future to be awaited
    return future;
}

pub fn create_asgi_future_for_event_loop(value: *PyObject, loop: *PyObject) !*PyObject {

    // Get the run_coroutine_threadsafe function
    const create_future = try base.getAttribute(@as(*PyObject, loop), "create_future");
    defer python.decref(create_future);

    const future = python.og.PyObject_CallObject(create_future, python.PyTuple_New(0));
    if (future == null) {
        std.debug.print("DEBUG: create_future failed\n", .{});
        return python.og.PyDict_New();
    }
    std.debug.print("DEBUG: create_future succeeded, got future\n", .{});

    // NOTE: Return future to be awaited
    // Set the result on the future
    const set_result = python.og.PyObject_GetAttrString(future, "set_result");
    if (set_result == null) {
        decref(future.?);
        return python.og.PyDict_New();
    }
    defer decref(set_result);

    // Set the result with our message
    const result = python.zig_call_function_with_arg(set_result, value);
    if (result == null) {
        decref(future.?);
        return python.og.PyDict_New();
    }
    decref(result.?);
    return @as(*PyObject, future);
}

/// Call an ASGI application with scope, receive, and send
pub fn callAsgiApplication(app: *PyObject, scope: *PyObject, receive: *PyObject, send: *PyObject, loop: *PyObject) !void {
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

    const future = try create_app_coroutine_for_event_loop(app, args, loop);

    // Get the result() method from the future
    const result_method = base.getAttribute(future, "result") catch {
        handlePythonError();
        return PythonError.RuntimeError;
    };
    defer python.decref(result_method);

    // Call result() to get the actual result
    const result = python.og.PyObject_CallObject(result_method, python.og.PyTuple_New(0));
    if (result == null) {
        python.decref(future);
        handlePythonError();
        return PythonError.CallFailed;
    }
    std.debug.print("DEBUG: Got result from future: {*}\n", .{result.?});

    // Clean up
    python.decref(future);
    python.decref(result.?);

    std.debug.print("DEBUG: ASGI application call completed\n", .{});
    return;
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
    std.debug.print("DEBUG: Received message: {}\n", .{message});

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
    const none = base.getNoneForCallback();
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
    defer decref(capsule.?);

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
    const py_func = python.og.PyCFunction_New(&method_def, capsule);
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
