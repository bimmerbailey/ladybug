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

**Fix**: ✅ FIXED

The Python integration module has been updated to use the correct function signatures. The current version correctly uses:

```zig
const self = @as(*@This(), @ptrCast(ptr));
```

instead of the deprecated:

```zig
@ptrCast(*TypeName, @alignCast(@alignOf(*TypeName), ptr));
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

**Fix**: ✅ FIXED

The signal handler struct in `src/main.zig` has been corrected to match the expected signature:

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

**Fix**: ✅ FIXED

Ladybug now works with Zig 0.11.x and later. The build.zig file has been updated to use the new module system introduced in Zig 0.11. If you're using an older version, please update to a compatible Zig version.

## Contributing Fixes

If you find and fix issues not documented here, please submit a pull request to help improve the project. 