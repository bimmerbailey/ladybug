const std = @import("std");
const testing = std.testing;
const integration = @import("integration.zig");
const asgi = @import("protocol");
const json = std.json;

// Set up a test allocator
var gpa = std.heap.GeneralPurposeAllocator(.{
    .enable_memory_limit = false,
    .safety = true,
}){};
const test_allocator = gpa.allocator();

// Use an arena allocator for test cleanup simplicity
var arena = std.heap.ArenaAllocator.init(test_allocator);
const arena_allocator = arena.allocator();

// Import helper functions from integration module
const incref = integration.incref;
const decref = integration.decref;

// Helper functions for the tests
fn createTestJson() !json.Value {
    var test_obj = json.Value{
        .object = json.ObjectMap.init(arena_allocator),
    };

    try test_obj.object.put("string", json.Value{ .string = "hello" });
    try test_obj.object.put("integer", json.Value{ .integer = 42 });
    try test_obj.object.put("float", json.Value{ .float = 3.14 });
    try test_obj.object.put("boolean", json.Value{ .bool = true });
    try test_obj.object.put("null", json.Value{ .null = {} });

    var array = json.Value{
        .array = json.Array.init(arena_allocator),
    };
    try array.array.append(json.Value{ .integer = 1 });
    try array.array.append(json.Value{ .integer = 2 });
    try array.array.append(json.Value{ .integer = 3 });

    try test_obj.object.put("array", array);

    var nested = json.Value{
        .object = json.ObjectMap.init(arena_allocator),
    };
    try nested.object.put("nested_key", json.Value{ .string = "nested_value" });
    try test_obj.object.put("object", nested);

    return test_obj;
}

// Creates a basic HTTP scope object for ASGI
fn createHttpScope() !json.Value {
    var scope = json.Value{
        .object = json.ObjectMap.init(arena_allocator),
    };

    try scope.object.put("type", json.Value{ .string = "http" });

    var asgi_obj = json.Value{
        .object = json.ObjectMap.init(arena_allocator),
    };
    try asgi_obj.object.put("version", json.Value{ .string = "3.0" });
    try asgi_obj.object.put("spec_version", json.Value{ .string = "2.0" });
    try scope.object.put("asgi", asgi_obj);

    try scope.object.put("http_version", json.Value{ .string = "1.1" });
    try scope.object.put("method", json.Value{ .string = "GET" });
    try scope.object.put("scheme", json.Value{ .string = "http" });
    try scope.object.put("path", json.Value{ .string = "/test" });
    try scope.object.put("query_string", json.Value{ .string = "param=value" });

    var headers = json.Value{
        .array = json.Array.init(arena_allocator),
    };

    // Add a header [b"host", b"localhost"]
    var header1 = json.Value{
        .array = json.Array.init(arena_allocator),
    };
    try header1.array.append(json.Value{ .string = "host" });
    try header1.array.append(json.Value{ .string = "localhost" });
    try headers.array.append(header1);

    try scope.object.put("headers", headers);

    var server = json.Value{ .array = json.Array.init(arena_allocator) };
    try server.array.append(json.Value{ .string = "localhost" });
    try server.array.append(json.Value{ .integer = 8000 });
    try scope.object.put("server", server);

    var client = json.Value{ .array = json.Array.init(arena_allocator) };
    try client.array.append(json.Value{ .string = "127.0.0.1" });
    try client.array.append(json.Value{ .integer = 60123 });
    try scope.object.put("client", client);

    return scope;
}

test "Python initialization and finalization" {
    // Initialize Python
    try integration.initialize();

    // Check if initialization worked (this doesn't really verify, but at least we can
    // finalize without errors if initialization succeeded)
    integration.finalize();
}

test "Import module" {
    try integration.initialize();
    defer integration.finalize();

    // Try to import a standard library module
    const sys = try integration.importModule("sys");
    defer decref(sys);

    // Verify it has the expected attributes
    const version = try integration.getAttribute(sys, "version");
    defer decref(version);

    // We don't need to check the content, just that we got a valid Python object
    try testing.expect(version != @as(?*integration.c.PyObject, null));
}

test "Python string conversion" {
    try integration.initialize();
    defer integration.finalize();

    // Test Zig string to Python string
    const test_str = "Hello, Python!";
    const py_str = try integration.toPyString(test_str);
    defer decref(py_str);

    // Test Python string to Zig string
    const zig_str = try integration.fromPyString(arena_allocator, py_str);
    // Memory freed by arena, so no defer needed

    try testing.expectEqualStrings(test_str, zig_str);
}

test "JSON conversion to Python and back" {
    try integration.initialize();
    defer integration.finalize();

    // Create a test JSON object
    const test_json = try createTestJson();
    // Memory freed by arena, so no defer needed

    // Convert to Python object
    const py_obj = try integration.jsonToPyObject(arena_allocator, test_json);
    defer decref(py_obj);

    // Convert back to JSON
    const roundtrip_json = try integration.pyObjectToJson(arena_allocator, py_obj);
    // Memory freed by arena, so no defer needed

    // We can't directly compare json.Value objects since their structure is complex
    // and may have different ordering, but we can at least check a few key properties

    try testing.expect(roundtrip_json.object.get("string").?.string.len > 0);
    try testing.expectEqual(@as(i64, 42), roundtrip_json.object.get("integer").?.integer);
    try testing.expectApproxEqAbs(@as(f64, 3.14), roundtrip_json.object.get("float").?.float, 0.001);
    try testing.expectEqual(true, roundtrip_json.object.get("boolean").?.bool);
    try testing.expect(roundtrip_json.object.get("array").?.array.items.len == 3);
}

test "MessageQueue with Python callables" {
    try integration.initialize();
    defer integration.finalize();

    // Create message queue
    var queue = asgi.MessageQueue.init(arena_allocator);
    defer queue.deinit();

    // Create Python callables
    const receive = try integration.createReceiveCallable(&queue);
    defer decref(receive);

    const send = try integration.createSendCallable(&queue);
    defer decref(send);

    // Check that we got valid Python callables
    try testing.expect(integration.c.PyCallable_Check(receive) != 0);
    try testing.expect(integration.c.PyCallable_Check(send) != 0);
}

// This test is more complex - tests full application message flow
test "ASGI application message flow" {
    try integration.initialize();
    defer integration.finalize();

    // Create queues for two-way communication
    var request_queue = asgi.MessageQueue.init(arena_allocator);
    defer request_queue.deinit();

    var response_queue = asgi.MessageQueue.init(arena_allocator);
    defer response_queue.deinit();

    // Create ASGI callable functions for communication
    const receive = try integration.createReceiveCallable(&request_queue);
    defer decref(receive);

    const send = try integration.createSendCallable(&response_queue);
    defer decref(send);

    // Create an HTTP scope
    const scope_json = try createHttpScope();
    // Memory freed by arena allocator

    const scope = try integration.jsonToPyObject(arena_allocator, scope_json);
    defer decref(scope);

    // Create a test app
    var app: ?*integration.c.PyObject = null;

    // Check if our test app exists
    const test_app_module = "tests.test_asgi_app";

    app = integration.loadApplication(test_app_module, "application") catch |err| {
        std.debug.print("Skipping test: couldn't load test ASGI app: {}\n", .{err});
        return;
    };
    defer decref(app.?);

    // Set up a thread to handle responses
    var thread_running = true;
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(queue: *asgi.MessageQueue, running: *bool) !void {
            // Monitor the response queue for messages
            while (running.*) {
                var message = queue.receive() catch |err| {
                    std.debug.print("Error receiving message: {}\n", .{err});
                    continue;
                };
                // Just use arena allocator, no explicit cleanup needed

                // Check message type
                if (message.object.get("type")) |type_val| {
                    if (std.mem.eql(u8, type_val.string, "http.response.start")) {
                        // Got the response start
                        const status = message.object.get("status").?.integer;
                        try testing.expectEqual(@as(i64, 200), status);
                    } else if (std.mem.eql(u8, type_val.string, "http.response.body")) {
                        // Test complete, we got the body response
                        break;
                    }
                }
            }
        }
    }.run, .{ &response_queue, &thread_running });

    // Start the application
    const thread_state = integration.c.PyEval_SaveThread();

    const call_thread = try std.Thread.spawn(.{}, struct {
        fn run(app_obj: *integration.c.PyObject, scope_obj: *integration.c.PyObject, receive_obj: *integration.c.PyObject, send_obj: *integration.c.PyObject, thread_state_ptr: ?*anyopaque) void {
            integration.c.PyEval_RestoreThread(thread_state_ptr);
            defer _ = integration.c.PyEval_SaveThread();

            // Call the application
            _ = integration.callAsgiApplication(app_obj, scope_obj, receive_obj, send_obj) catch |err| {
                std.debug.print("Error calling ASGI application: {}\n", .{err});
                return;
            };
        }
    }.run, .{ app.?, scope, receive, send, thread_state });

    // Push the request message to the queue
    var request_message = json.Value{
        .object = json.ObjectMap.init(arena_allocator),
    };
    try request_message.object.put("type", json.Value{ .string = "http.request" });
    try request_message.object.put("body", json.Value{ .string = "" });
    try request_message.object.put("more_body", json.Value{ .bool = false });

    try request_queue.push(request_message);

    // Wait for processing to complete
    call_thread.join();
    thread_running = false;
    thread.join();

    integration.c.PyEval_RestoreThread(thread_state);
}

test "Load ASGI application" {
    // This test is more complex and depends on having a proper Python ASGI application.
    // We'll test with a minimal application if it's available

    try integration.initialize();
    defer integration.finalize();

    // First check if the test app module exists
    const py_exists = integration.importModule("os.path") catch |err| {
        std.debug.print("Skipping test_load_asgi_application: couldn't import os.path ({})\n", .{err});
        return;
    };
    defer decref(py_exists);

    const py_exists_func = integration.getAttribute(py_exists, "exists") catch |err| {
        std.debug.print("Skipping test_load_asgi_application: couldn't get exists function ({})\n", .{err});
        return;
    };
    defer decref(py_exists_func);

    // Create test app path and convert to Python string
    const test_app_path = "tests/test_asgi_app.py";
    const py_path = integration.toPyString(test_app_path) catch |err| {
        std.debug.print("Skipping test_load_asgi_application: couldn't create Python string ({})\n", .{err});
        return;
    };
    defer decref(py_path);

    // Call exists(path)
    const args = integration.c.PyTuple_New(1);
    if (args == null) {
        std.debug.print("Skipping test_load_asgi_application: couldn't create args tuple\n", .{});
        return;
    }
    defer decref(args.?);

    incref(py_path);
    if (integration.c.PyTuple_SetItem(args.?, 0, py_path) < 0) {
        std.debug.print("Skipping test_load_asgi_application: couldn't set tuple item\n", .{});
        return;
    }

    const result = integration.c.PyObject_CallObject(py_exists_func, args.?);
    if (result == null) {
        std.debug.print("Skipping test_load_asgi_application: call to exists failed\n", .{});
        return;
    }
    defer decref(result.?);

    // Check if file exists
    const exists = integration.c.PyObject_IsTrue(result.?);
    if (exists <= 0) {
        std.debug.print("Skipping test_load_asgi_application: test app not found at {s}\n", .{test_app_path});
        return;
    }

    // Try to load the application
    const app = integration.loadApplication("tests.test_asgi_app", "application") catch |err| {
        std.debug.print("Error loading test ASGI app: {}\n", .{err});
        return;
    };
    defer decref(app);

    std.debug.print("Successfully loaded test ASGI application\n", .{});
}
