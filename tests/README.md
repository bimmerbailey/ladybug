# ASGI Test Application

This directory contains a simple ASGI application for testing the Zig ASGI server implementation.

## Files

- `app.py`: A simple ASGI application that handles HTTP requests, WebSocket connections, and lifespan protocol
- `websocket_test.html`: A browser-based client for testing WebSocket functionality
- `test_asgi_app.py`: Original test ASGI application

## Running the ASGI Application

To run the ASGI application with your Zig server:

1. Make sure you have built your Zig application according to the main project README

2. Run the Zig server pointing to the ASGI app:
   ```
   ./zig-out/bin/ladybug -app tests/app:app
   ```
   
   This tells the server to import the app from the tests directory.

3. Open your browser and navigate to:
   ```