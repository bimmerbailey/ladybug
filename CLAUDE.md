# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ladybug is a Zig implementation of a lightning-fast ASGI server inspired by uvicorn. It provides high-performance HTTP/WebSocket handling in Zig while integrating with Python ASGI applications through the Python C API.

## Architecture

### Core Components

- **Main Server Flow**: `main.zig` - Entry point, worker management, signal handling
- **HTTP Server**: `src/http/server.zig` - HTTP request/response handling
- **ASGI Protocol**: `src/asgi/protocol.zig` - ASGI specification implementation
- **Python Integration**: `src/python/` - Python interpreter integration and ASGI communication
- **WebSocket Support**: `src/websocket/server.zig` - WebSocket protocol handling
- **CLI Options**: `src/cli/options.zig` - Command-line argument parsing

### Python Integration Strategy

The server embeds a Python interpreter to communicate with ASGI applications:

- `loadApplication()` - Loads Python ASGI apps from modules
- `callAsgiApplication()` - Handles ASGI protocol communication  
- `MessageQueue` - Manages async message passing between Zig and Python
- Lifespan protocol support for startup/shutdown events

## Common Commands

### Building

```bash
# Build the server
zig build

# Build with optimizations (production)
zig build -Doptimize=ReleaseFast

# Install binary to zig-out/bin/
zig build install
```

### Testing

```bash
# Run all tests (recommended)
zig build test

# Detailed test output
zig build test --summary all

# Python integration tests
zig build test-python

# Individual component tests
zig test src/asgi/protocol_test.zig
zig test src/http/server_test.zig
zig test src/websocket/server_test.zig
zig test src/utils/common_test.zig
zig test src/python/integration_test.zig
```

### Running

```bash
# Run with test ASGI app
./zig-out/bin/ladybug -app tests.app:app

# Run with wrapper script (sets PYTHONPATH)
./run_ladybug.sh

# Common options
./zig-out/bin/ladybug -app module:app -host 0.0.0.0 -port 8000 -workers 4
```

## Python Environment Setup

The build system auto-detects Python installations but can be configured:

```bash
# Set custom Python paths
export PYTHON_INCLUDE_PATH="/path/to/python/include"
export PYTHON_LIB_PATH="/path/to/python/lib"
```

Default paths:

- **macOS**: `/opt/homebrew/opt/python@3.13/`
- **Linux**: `/usr/include/python3.13`, `/usr/lib`

## Key Development Notes

### Memory Management

- Uses arena allocators for request-scoped allocations
- Manual memory management for Python object references
- Connection objects are heap-allocated and cleaned up per-request

### Concurrency Model  

- Master process manages worker processes
- Each worker runs single-threaded with async Python integration
- Signal handling for graceful shutdown (SIGINT/SIGTERM)

### ASGI Communication

- Bidirectional message queues between Zig server and Python app
- JSON serialization for ASGI scope/message objects
- Supports HTTP and lifespan protocols, WebSocket in progress

### Error Handling

- Zig error handling with try/catch patterns
- Python exception propagation through C API
- Graceful connection cleanup on errors

## Test Applications

Located in `tests/` directory:

- `app.py` - Main test ASGI application with HTTP/WebSocket/lifespan support
- `simple.py`, `robust.py` - Various test scenarios
- `websocket_test.html` - Browser WebSocket client for testing
