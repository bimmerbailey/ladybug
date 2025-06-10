# Ladybug

A Zig implementation of a lightning-fast ASGI server, inspired by uvicorn.

This project aims to rewrite the popular Python ASGI server [uvicorn](https://github.com/encode/uvicorn) in Zig, taking advantage of Zig's performance characteristics and safety guarantees. The development approach is exploratory and iterative, focusing on understanding and reimplementing uvicorn's core functionality while maintaining its speed and reliability.

## Status

This is a work in progress. The project is being developed through "vibe coding" - an intuitive, exploratory approach to understanding and reimplementing uvicorn's architecture and features.

## Goals

- Provide a high-performance ASGI server implementation in Zig
- Maintain compatibility with ASGI specification
- Learn and document the process of porting Python async code to Zig
- Explore Zig's concurrency and networking capabilities

## Current Features

- Basic HTTP server implementation
- More features coming soon!

## Testing

The project includes comprehensive unit tests and integration tests to ensure reliability and correctness.

### Run All Tests

To run all unit tests (recommended):
```bash
zig build test
```

For more detailed test output:
```bash
zig build test --summary all
```

### Available Test Commands

- **`zig build test`** - Runs all unit tests (library and executable tests)
- **`zig build test-python`** - Runs Python integration tests
- **`zig build --help`** - Shows all available build steps and options

### Individual Component Tests

You can test specific components by running individual test files:

```bash
# Test ASGI protocol functionality
zig test src/asgi/protocol_test.zig

# Test HTTP server functionality  
zig test src/http/server_test.zig

# Test WebSocket server functionality
zig test src/websocket/server_test.zig

# Test utility functions
zig test src/utils/common_test.zig

# Test Python integration
zig test src/python/integration_test.zig
```

### Test Structure

- **Unit Tests**: Built into library and executable modules, covering core functionality
- **Integration Tests**: Separate test files for specific components (HTTP, WebSocket, ASGI)
- **Python Integration Tests**: Tests for Python-Zig interoperability and ASGI communication

### Running Tests During Development

For continuous testing during development, you can use:
```bash
zig build test --watch
```

This will automatically rerun tests when source files change.

## Component Overview

### Main Server Flow

- `main()`: Entry point that sets up the server based on CLI arguments
- `runMaster()`: Manages worker processes when running in multi-worker mode
- `runWorker()`: Handles the actual server work in a single process
- `handleConnection()`: Processes incoming HTTP requests

### ASGI Communication

- `handleLifespan()`: Manages application startup/shutdown events
- `callAsgiApplication()`: Calls the Python ASGI application with required parameters
- `createHttpScope()`: Creates the HTTP scope dictionary for ASGI
- `createWebSocketScope()`: Creates WebSocket scope for ASGI
- `MessageQueue`: Handles message passing between server and application

### Python Integration

- `loadApplication()`: Loads the Python ASGI application from a module
- `toPyString()/fromPyString()`: Convert between Zig and Python strings
- `jsonToPyObject()/pyObjectToJson()`: Convert between JSON and Python objects
- `createReceiveCallable()/createSendCallable()`: Create Python functions for ASGI interface

### WebSocket Support

- `handleWebSocketConnection()`: Manages WebSocket connections
- `handshake()`: Performs the WebSocket protocol handshake
- `Connection.send()/Connection.receive()`: Send/receive WebSocket messages

### Utilities

- `Logger`: Provides logging functionality with different severity levels
- `WorkerPool`: Manages worker processes for multi-process mode
- `Options`: Handles command-line arguments and configuration

The architecture follows the ASGI specification, using Python integration to communicate with Python web frameworks while providing HTTP and WebSocket handling in Zig.

### **Estimated Speedup for FastAPI**

For a basic FastAPI app (`/hello` returning JSON), here's a rough comparison:

| **Server** | **Avg Latency (ms)** | **Requests/sec** |
| --- | --- | --- |
| Uvicorn (default) | ~1.5 - 3.0 ms | ~50,000 - 80,000 |
| Zig-based ASGI | ~0.5 - 2.0 ms | ~70,000 - 120,000 |

### **Summary**

- You could see a **20-50% increase** in requests per second.
- Latency could **drop by 30-70%**, especially under high concurrency.
- **CPU & memory usage** would likely be **lower** compared to Uvicorn.

## License

This project is licensed under the BSD 3-Clause License. See the [LICENSE](LICENSE) file for details.

This project is inspired by and based on concepts from the [Uvicorn project](https://github.com/encode/uvicorn), which is also licensed under the BSD 3-Clause License.
