"""
Simple ASGI application for testing the Python integration in Zig.
This file implements a basic ASGI application with HTTP and WebSocket support.
"""
import sys
import os

# When running from Zig, ensure the root directory is in Python's path
# current_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# if current_dir not in sys.path:
#     sys.path.insert(0, current_dir)
#     print(f"Added {current_dir} to Python path")

# print(f"Python import path: {sys.path}")

async def app(scope, receive, send):
    """
    Main ASGI application entrypoint.
    
    Parameters:
        scope: The connection scope (dict)
        receive: The receive callable for getting messages
        send: The send callable for sending messages
    """
    print(f"Received request with scope: {scope['type']}")
    
    if scope["type"] == "http":
        await handle_http(scope, receive, send)
    elif scope["type"] == "websocket":
        await handle_websocket(scope, receive, send)
    elif scope["type"] == "lifespan":
        await handle_lifespan(scope, receive, send)
    else:
        await send({
            "type": "error",
            "message": f"Unsupported scope type: {scope['type']}"
        })

async def handle_http(scope, receive, send):
    """
    Handle an HTTP request and return a response with request details.
    """
    # Get the request details
    request = await receive()
    print(f"Received HTTP request: {request}")
    
    # Prepare response headers
    headers = [
        [b"content-type", b"text/html; charset=utf-8"],
        [b"server", b"ladybug-asgi-server"],
    ]
    
    # Create a simple HTML response with request details
    path = scope.get("path", "")
    method = scope.get("method", "")
    query_string = scope.get("query_string", b"").decode("utf-8")
    
    body = f"""
    <!DOCTYPE html>
    <html>
    <head>
        <title>Ladybug ASGI Test</title>
        <style>
            body {{ font-family: Arial, sans-serif; margin: 40px; line-height: 1.6; }}
            h1 {{ color: #333; }}
            pre {{ background: #f4f4f4; padding: 10px; border-radius: 5px; }}
            .info {{ color: #0066cc; }}
        </style>
    </head>
    <body>
        <h1>Ladybug ASGI Test</h1>
        <p class="info">Your request was successfully processed by the Zig ASGI server!</p>
        
        <h2>Request Details:</h2>
        <ul>
            <li><strong>Path:</strong> {path}</li>
            <li><strong>Method:</strong> {method}</li>
            <li><strong>Query String:</strong> {query_string}</li>
        </ul>
        
        <h2>Full Scope:</h2>
        <pre>{scope}</pre>
    </body>
    </html>
    """.encode("utf-8")
    
    # Send response headers
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": headers,
    })
    
    # Send response body
    await send({
        "type": "http.response.body",
        "body": body,
        "more_body": False,
    })

async def handle_websocket(scope, receive, send):
    """
    Handle WebSocket connections with echo functionality.
    """
    # Accept connection
    event = await receive()
    if event["type"] == "websocket.connect":
        await send({"type": "websocket.accept"})
        print("WebSocket connection accepted")
        
        # Echo loop
        try:
            while True:
                message = await receive()
                print(f"WebSocket message received: {message}")
                
                if message["type"] == "websocket.disconnect":
                    print("WebSocket disconnected")
                    break
                    
                elif message["type"] == "websocket.receive":
                    if "text" in message:
                        await send({
                            "type": "websocket.send",
                            "text": f"You said: {message['text']}"
                        })
                    elif "bytes" in message:
                        await send({
                            "type": "websocket.send",
                            "bytes": message["bytes"]
                        })
        except Exception as e:
            print(f"WebSocket error: {e}")
            # Try to send close message if possible
            try:
                await send({"type": "websocket.close", "code": 1011})
            except:
                pass

async def handle_lifespan(scope, receive, send):
    """
    Handle server lifespan events.
    """
    while True:
        message = await receive()
        if message["type"] == "lifespan.startup":
            print("IN PYTHON: Server is starting up")
            await send({"type": "lifespan.startup.complete"})
        elif message["type"] == "lifespan.shutdown":
            print("Server is shutting down")
            await send({"type": "lifespan.shutdown.complete"})
            break 