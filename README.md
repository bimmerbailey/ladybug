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

## Component Overview

### Server Core

- `main()`: Entry point that parses CLI options and configures the server
- `runMaster()`: Manages worker processes for multi-process deployment using a worker pool
- `runWorker()`: Sets up and runs a single server process, initializes the Python interpreter
- `handleConnection()`: Processes incoming HTTP requests in separate threads
- `handleWebSocketConnection()`: Manages WebSocket connections and protocol upgrades

### HTTP Implementation

- `http.Server`: Core HTTP server that binds to ports and accepts connections
- `http.parseRequest()`: Parses raw HTTP requests into structured request objects
- `http.Request`: Represents HTTP requests with methods, paths, headers, and bodies
- `http.Response`: Represents HTTP responses with status codes, headers, and bodies

### WebSocket Support

- `websocket.Connection`: Manages WebSocket connections with framing and masking
- `websocket.Message`: Represents WebSocket messages of different types (text/binary/etc.)
- `websocket.handshake()`: Implements the WebSocket protocol handshake
- `websocket.Opcode`: Defines WebSocket frame operation codes

### ASGI Protocol

- `asgi.MessageQueue`: Thread-safe queue for communication between server and application
- `asgi.createHttpScope()`: Creates the HTTP scope dictionary for ASGI applications
- `asgi.createWebSocketScope()`: Creates WebSocket scope for ASGI applications
- `asgi.createLifespanScope()`: Creates scopes for application lifecycle events
- `asgi.handleLifespan()`: Manages application startup/shutdown protocol

### Python Integration

- `python.initialize()`: Sets up the Python interpreter
- `python.loadApplication()`: Loads the Python ASGI application from module:app string
- `python.callAsgiApplication()`: Invokes the ASGI application with appropriate arguments
- `python.createPyDict()`: Converts Zig data structures to Python dictionaries
- `python.toPyString()/fromPyString()`: Converts between Zig and Python strings

### Utilities

- `utils.Logger`: Configurable logging with multiple severity levels and timestamps
- `utils.WorkerPool`: Manages worker processes for multi-process deployments
- `cli.Options`: Parses and manages command-line options with sensible defaults

The architecture follows the ASGI specification, providing a high-performance server implementation in Zig that can communicate with Python web frameworks like FastAPI, Django, and Starlette.

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
