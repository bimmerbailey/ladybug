"""
Simple ASGI application for testing the Python integration in Zig.
"""

async def application(scope, receive, send):
    """
    A simple ASGI application that echoes back the request data.
    """
    if scope["type"] == "http":
        await handle_http(scope, receive, send)
    elif scope["type"] == "websocket":
        await handle_websocket(scope, receive, send)
    else:
        await send({
            "type": "error",
            "message": f"Unsupported scope type: {scope['type']}"
        })

async def handle_http(scope, receive, send):
    """
    Handle an HTTP request and return a simple response.
    """
    # Wait for the http.request message
    request = await receive()
    
    # Send the HTTP response
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [
            [b"content-type", b"text/plain"],
        ],
    })
    
    # Send the response body
    await send({
        "type": "http.response.body",
        "body": f"Request path: {scope['path']}".encode(),
    })

async def handle_websocket(scope, receive, send):
    """
    Handle a WebSocket connection, echoing back any messages.
    """
    # Wait for connection request
    event = await receive()
    if event["type"] == "websocket.connect":
        # Accept the connection
        await send({"type": "websocket.accept"})
        
        # Echo back messages until disconnect
        while True:
            message = await receive()
            if message["type"] == "websocket.disconnect":
                break
            elif message["type"] == "websocket.receive":
                if "text" in message:
                    await send({
                        "type": "websocket.send",
                        "text": f"Echo: {message['text']}"
                    })
                elif "bytes" in message:
                    await send({
                        "type": "websocket.send",
                        "bytes": message["bytes"]
                    }) 