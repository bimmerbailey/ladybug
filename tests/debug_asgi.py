#!/usr/bin/env python3
"""
Debugging ASGI application that prints detailed information about the Python environment.
"""
import os
import sys
import traceback
import inspect
import site

# Print detailed debugging information
print("=" * 50)
print("PYTHON DEBUGGING INFORMATION")
print("=" * 50)
print(f"Python Version: {sys.version}")
print(f"Python Executable: {sys.executable}")
print(f"Current Working Directory: {os.getcwd()}")
print(f"Current File: {__file__}")
print(f"Absolute Path: {os.path.abspath(__file__)}")
print(f"Parent Directory: {os.path.dirname(os.path.abspath(__file__))}")

print("\nPython Path:")
for i, path in enumerate(sys.path):
    print(f"  {i}: {path}")

print("\nSite Packages:")
for site_pkg in site.getsitepackages():
    print(f"  - {site_pkg}")

print("\nEnvironment Variables:")
for key, value in sorted(os.environ.items()):
    if key.startswith("PYTHON") or "PATH" in key:
        print(f"  {key}={value}")

print("\nImported Modules:")
for name, module in sorted(sys.modules.items()):
    if not name.startswith("_") and "." not in name:
        try:
            file_path = getattr(module, "__file__", "N/A")
            print(f"  {name}: {file_path}")
        except Exception as e:
            print(f"  {name}: Error accessing __file__: {e}")

# Define a simple ASGI application
async def app(scope, receive, send):
    """
    Debug ASGI application that returns diagnostic information.
    """
    print(f"\nReceived {scope['type']} request")
    print(f"Scope: {scope}")
    
    if scope["type"] == "http":
        # Get request
        request = await receive()
        print(f"Request: {request}")
        
        # Send response headers
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [
                [b"content-type", b"text/plain; charset=utf-8"],
            ],
        })
        
        # Collect debug info
        debug_info = [
            "=== PYTHON DEBUG INFO ===",
            f"Python Version: {sys.version}",
            f"Python Executable: {sys.executable}",
            f"Current Working Directory: {os.getcwd()}",
            f"Current File: {__file__}",
            f"Absolute Path: {os.path.abspath(__file__)}",
            "",
            "Python Path:",
        ]
        
        for i, path in enumerate(sys.path):
            debug_info.append(f"  {i}: {path}")
        
        debug_info.append("\nEnvironment Variables:")
        for key, value in sorted(os.environ.items()):
            if key.startswith("PYTHON") or "PATH" in key:
                debug_info.append(f"  {key}={value}")
        
        # Add info about the request
        debug_info.extend([
            "",
            "=== REQUEST INFO ===",
            f"Method: {scope.get('method', 'N/A')}",
            f"Path: {scope.get('path', 'N/A')}",
            f"Query String: {scope.get('query_string', b'').decode('utf-8', 'replace')}",
            f"HTTP Version: {scope.get('http_version', 'N/A')}",
            "",
            "Headers:",
        ])
        
        for header in scope.get('headers', []):
            name, value = header
            debug_info.append(f"  {name.decode('utf-8', 'replace')}: {value.decode('utf-8', 'replace')}")
        
        # Send debug info as response
        await send({
            "type": "http.response.body",
            "body": ("\n".join(debug_info)).encode('utf-8'),
        })
    elif scope["type"] == "lifespan":
        while True:
            message = await receive()
            message_type = message["type"]
            print(f"Lifespan message: {message_type}")
            
            if message_type == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message_type == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                break

# Try to manually import "tests" module to see what happens
try:
    print("\nAttempting to import 'tests' module...")
    import tests
    print(f"Successfully imported 'tests' module: {tests.__file__}")
    
    print("\nAttempting to import 'tests.simple' module...")
    import tests.simple
    print(f"Successfully imported 'tests.simple' module: {tests.simple.__file__}")
except ImportError as e:
    print(f"Import error: {e}")
    print("Traceback:")
    traceback.print_exc()

# Print final message
print("\nDebug ASGI app initialized and ready")
print("=" * 50) 