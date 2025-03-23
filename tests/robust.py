"""
Robust ASGI application for testing with better error handling.
"""
import os
import sys
import traceback

# Add debugging information right at the module load time
print("=" * 50)
print(f"Loading robust.py from {__file__}")
print(f"Python version: {sys.version}")
print(f"Python executable: {sys.executable}")
print(f"Working directory: {os.getcwd()}")

# Try to fix imports by adding parent directory to path
try:
    # Get the parent directory of the tests folder
    parent_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if parent_dir not in sys.path:
        sys.path.insert(0, parent_dir)
        print(f"Added {parent_dir} to sys.path")
    
    # Add the tests directory itself
    tests_dir = os.path.dirname(os.path.abspath(__file__))
    if tests_dir not in sys.path:
        sys.path.insert(0, tests_dir)
        print(f"Added {tests_dir} to sys.path")
    
    print(f"Python path now: {sys.path}")
except Exception as e:
    print(f"Error setting up path: {e}")
    traceback.print_exc()

async def app(scope, receive, send):
    """
    Robust ASGI application that handles errors gracefully.
    """
    try:
        print(f"Received request: {scope['type']}")
        
        if scope["type"] == "http":
            # Get request
            request = await receive()
            print(f"Request details: {request}")
            
            # Send response headers
            await send({
                "type": "http.response.start",
                "status": 200,
                "headers": [
                    [b"content-type", b"text/plain"],
                ],
            })
            
            # Build response with debug info
            debug_info = [
                "Robust ASGI Test App",
                "=====================",
                f"Python version: {sys.version}",
                f"Python executable: {sys.executable}",
                f"Working directory: {os.getcwd()}",
                f"Module file: {__file__}",
                "",
                "Python Path:",
            ]
            
            for i, path in enumerate(sys.path):
                debug_info.append(f"  {i}: {path}")
            
            debug_info.extend([
                "",
                "Request Details:",
                f"  Type: {scope['type']}",
                f"  Path: {scope.get('path', 'N/A')}",
                f"  Method: {scope.get('method', 'N/A')}",
            ])
            
            await send({
                "type": "http.response.body",
                "body": ("\n".join(debug_info)).encode(),
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
                    
        else:
            print(f"Unsupported scope type: {scope['type']}")
            await send({
                "type": "error",
                "message": f"Unsupported scope type: {scope['type']}"
            })
            
    except Exception as e:
        # Log the error
        print(f"Error in ASGI app: {e}")
        traceback.print_exc()
        
        # Try to send an error response if we haven't sent headers yet
        try:
            await send({
                "type": "http.response.start",
                "status": 500,
                "headers": [
                    [b"content-type", b"text/plain"],
                ],
            })
            
            error_info = [
                "Internal Server Error",
                "=====================",
                f"Error: {str(e)}",
                "",
                "Traceback:",
                traceback.format_exc()
            ]
            
            await send({
                "type": "http.response.body",
                "body": ("\n".join(error_info)).encode(),
            })
        except Exception as send_error:
            print(f"Failed to send error response: {send_error}")

# Print that we've finished loading
print("Robust ASGI app loaded successfully")
print("=" * 50) 