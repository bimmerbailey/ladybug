# Troubleshooting Guide for Ladybug

This document addresses common issues that might occur when setting up or running the Ladybug ASGI server.

## Common Startup Errors

### Python Integration Issues

#### 'Python.h' file not found

**Error**:

```
'Python.h' file not found
```

**Fix**:

1. Make sure Python development headers are installed on your system:
   - Debian/Ubuntu: `sudo apt-get install python3-dev`
   - Fedora: `sudo dnf install python3-devel`
   - macOS: `brew install python`
   - Windows: Install the Python development version from python.org

2. Update the build.zig file to include the correct path to Python headers:

   ```zig
   exe.addIncludePath("/usr/include/python3.x"); // Replace x with your Python version
   exe.linkSystemLibrary("python3.x");
   ```

#### Python Function Signature Errors

**Error**:
```
expected 1 argument, found 2
```

This often occurs in the Python integration module with functions like `@ptrCast()` or `PyBytes_AsStringAndSize()`.

**Fix**:
Modify `src/python/integration.zig` to ensure:

1. Pointers are cast with the correct number of arguments:

   ```zig
   // Change:
   @ptrCast(*TypeName, @alignCast(@alignOf(*TypeName), ptr));
   // To:
   @as(*TypeName, @ptrCast(ptr));
   ```

2. Correct signatures for C API functions:

   ```zig
   // Make sure PyBytes_AsStringAndSize has correct parameters:
   var bytes_ptr: [*c]u8 = undefined;
   const result = c.PyBytes_AsStringAndSize(py_obj, &bytes_ptr, &size);
   ```

### Missing Libraries

**Error**:

```
error: library not found for -lpython3.x
```

**Fix**:

1. Install Python development libraries
2. Add the library path to build.zig:

   ```zig
   exe.addLibraryPath("/usr/lib/python3.x/config-3.x-xxx-linux-gnu");
   ```

### Signal Handler Issues

**Error**:
Signal handlers not working correctly or compiler warnings.

**Fix**:
The signal handler struct in `src/main.zig` should be modified to match the expected signature:

```zig
fn handle(sig: c_int, handler_ptr: ?*anyopaque) callconv(.C) void {
    _ = sig;
    if (handler_ptr) |ptr| {
        const self = @as(*@This(), @ptrCast(ptr));
        self.flag.* = true;
    }
}
```

## Runtime Errors

### ASGI Application Errors

**Error**:

```
Error loading ASGI application: ModuleNotFound
```

**Fix**:

1. Make sure the module name is correct
2. Ensure the module is in the Python path:

   ```bash
   export PYTHONPATH=/path/to/your/app:$PYTHONPATH
   ```

### WebSocket Connection Issues

**Error**:

```
Error in WebSocket handshake
```

**Fix**:

1. Verify the WebSocket protocol implementation
2. Check headers handling and handshake response

## Performance Issues

### Slow Request Handling

**Issue**: Requests are being processed slowly.

**Fix**:

1. Increase worker count with `--workers=N`
2. Check for memory leaks in request processing
3. Optimize connection handling to reduce overhead

### Memory Usage Growing

**Issue**: Memory usage grows over time.

**Fix**:

1. Add `--limit-max-requests=N` to recycle workers after N requests
2. Check Python object reference counting in integration.zig
3. Ensure all allocated memory is properly freed

## Building Issues

### Zig Version Compatibility

**Issue**: Build errors related to Zig version.

**Fix**:
Ladybug is developed with Zig 0.11.x. If you're using a different version:

1. Update to compatible Zig version
2. Check for API changes in the Zig standard library that may affect the code

## Contributing Fixes

If you find and fix issues not documented here, please submit a pull request to help improve the project. 