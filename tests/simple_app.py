"""
Simple ASGI application for testing the Python import mechanism.
"""
import sys
import os

# Print current directory and Python path for debugging
print(f"Current directory: {os.getcwd()}")
print(f"__file__: {__file__}")
print(f"Python path: {sys.path}")

# Add the current directory to Python's path if it's not already there
current_dir = os.getcwd()
if current_dir not in sys.path:
    sys.path.insert(0, current_dir)
    print(f"Added {current_dir} to Python path")

async def app(scope, receive, send):
    """
    A very simple ASGI application for testing.
    """
    if scope["type"] == "http":
        # Get request
        await receive()
        
        # Send simple response
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [
                [b"content-type", b"text/plain"],
            ],
        })
        
        # Build response with debug info
        debug_info = [
            "Simple ASGI App",
            f"Current directory: {os.getcwd()}",
            f"Python path: {sys.path}",
            f"Modules in sys.modules: {list(sys.modules.keys())}",
        ]
        
        await send({
            "type": "http.response.body",
            "body": ("\n".join(debug_info)).encode(),
        })
    elif scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                print("Server is starting up")
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                print("Server is shutting down")
                await send({"type": "lifespan.shutdown.complete"})
                break 