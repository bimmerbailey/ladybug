#!/usr/bin/env python3
"""
Standalone ASGI application that fixes Python's import paths.
This file can be loaded directly by the Zig ASGI server.
"""
import os
import sys
import inspect
import traceback

# Fix Python's import path at the module level (runs when imported)
def _fix_import_paths():
    # First, print diagnostic info
    print(f"[standalone_asgi] Python version: {sys.version}")
    print(f"[standalone_asgi] Loading from: {__file__}")
    print(f"[standalone_asgi] Current directory: {os.getcwd()}")
    
    # Get the absolute path to this file's directory
    base_dir = os.path.dirname(os.path.abspath(__file__))
    print(f"[standalone_asgi] Base directory: {base_dir}")
    
    # Add the base directory to sys.path if not already present
    if base_dir not in sys.path:
        sys.path.insert(0, base_dir)
        print(f"[standalone_asgi] Added {base_dir} to sys.path")
    
    # Print the current Python path
    print(f"[standalone_asgi] Python path: {sys.path}")
    
    # Return the root directory for reference
    return base_dir

# Fix paths immediately when imported
ROOT_DIR = _fix_import_paths()

# Define the ASGI application
async def app(scope, receive, send):
    """
    Standalone ASGI application that's guaranteed to load.
    """
    try:
        print(f"[standalone_asgi] Request received: {scope['type']}")
        
        if scope["type"] == "http":
            # Get the request
            request = await receive()
            print(f"[standalone_asgi] Request data: {request}")
            
            # Process the request path
            path = scope.get("path", "")
            query_string = scope.get("query_string", b"").decode("utf-8", "replace")
            print(f"[standalone_asgi] Path: {path}")
            print(f"[standalone_asgi] Query: {query_string}")
            
            # Send response headers
            await send({
                "type": "http.response.start",
                "status": 200,
                "headers": [
                    [b"content-type", b"text/html; charset=utf-8"],
                ],
            })
            
            # Build HTML response
            response_html = f"""
            <!DOCTYPE html>
            <html>
            <head>
                <title>Standalone ASGI App</title>
                <style>
                    body {{ font-family: Arial, sans-serif; line-height: 1.6; margin: 40px; }}
                    h1 {{ color: #2c3e50; }}
                    .success {{ color: #27ae60; font-weight: bold; }}
                    pre {{ background-color: #f8f9fa; padding: 15px; border-radius: 5px; overflow-x: auto; }}
                    .section {{ margin-bottom: 30px; }}
                </style>
            </head>
            <body>
                <h1>Standalone ASGI App</h1>
                <p class="success">✓ The ASGI application is working correctly!</p>
                
                <div class="section">
                    <h2>Python Environment</h2>
                    <ul>
                        <li><strong>Python Version:</strong> {sys.version}</li>
                        <li><strong>Python Executable:</strong> {sys.executable}</li>
                        <li><strong>Application Location:</strong> {__file__}</li>
                        <li><strong>Current Directory:</strong> {os.getcwd()}</li>
                    </ul>
                </div>
                
                <div class="section">
                    <h2>Python Path</h2>
                    <pre>{chr(10).join(sys.path)}</pre>
                </div>
                
                <div class="section">
                    <h2>Request Details</h2>
                    <ul>
                        <li><strong>Method:</strong> {scope.get('method', 'N/A')}</li>
                        <li><strong>Path:</strong> {path}</li>
                        <li><strong>Query String:</strong> {query_string}</li>
                    </ul>
                </div>
                
                <div class="section">
                    <h2>Request Headers</h2>
                    <pre>
                    {chr(10).join(f"{name.decode('utf-8', 'replace')}: {value.decode('utf-8', 'replace')}" for name, value in scope.get('headers', []))}
                    </pre>
                </div>
                
                <div class="section">
                    <h2>Imported Modules</h2>
                    <pre>{chr(10).join(sorted(sys.modules.keys()))}</pre>
                </div>
            </body>
            </html>
            """
            
            # Send the response body
            await send({
                "type": "http.response.body",
                "body": response_html.encode("utf-8"),
            })
            
        elif scope["type"] == "lifespan":
            # Handle lifespan protocol
            while True:
                message = await receive()
                if message["type"] == "lifespan.startup":
                    print("[standalone_asgi] Lifespan startup")
                    await send({"type": "lifespan.startup.complete"})
                elif message["type"] == "lifespan.shutdown":
                    print("[standalone_asgi] Lifespan shutdown")
                    await send({"type": "lifespan.shutdown.complete"})
                    break
                else:
                    print(f"[standalone_asgi] Unknown lifespan message: {message['type']}")
        
        else:
            print(f"[standalone_asgi] Unsupported scope type: {scope['type']}")
            await send({
                "type": "error",
                "message": f"Unsupported scope type: {scope['type']}"
            })
            
    except Exception as e:
        print(f"[standalone_asgi] Error in app: {e}")
        traceback.print_exc()
        
        # Try to send an error response if possible
        try:
            await send({
                "type": "http.response.start",
                "status": 500,
                "headers": [
                    [b"content-type", b"text/plain"],
                ],
            })
            
            error_message = f"""
            Error in Standalone ASGI App
            
            {str(e)}
            
            {traceback.format_exc()}
            """
            
            await send({
                "type": "http.response.body",
                "body": error_message.encode("utf-8"),
            })
        except Exception as send_err:
            print(f"[standalone_asgi] Failed to send error response: {send_err}")

# If run directly as a script, print diagnostic information
if __name__ == "__main__":
    print("\n" + "=" * 50)
    print("STANDALONE ASGI APP - DIAGNOSTICS")
    print("=" * 50)
    print(f"Python version: {sys.version}")
    print(f"Python executable: {sys.executable}")
    print(f"Script location: {__file__}")
    print(f"Absolute path: {os.path.abspath(__file__)}")
    print(f"Working directory: {os.getcwd()}")
    print(f"sys.path: {sys.path}")
    print("\nModule is ready for use with the Zig ASGI server:")
    print("  ./zig-out/bin/ladybug -app standalone_asgi:app")
    print("=" * 50) 