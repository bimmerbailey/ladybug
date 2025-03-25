"""
Minimal ASGI application with no dependencies.
"""

async def app(scope, receive, send):
    """
    Minimal ASGI application.
    """
    print("\nIn python app")
    print("DEBUG: Python app called")
    print(f"DEBUG:  scope: {scope}, receive: {receive}, send: {send}")
    print(f"DEBUG:  scope type: {type(scope)}, receive type: {type(receive)}, send type: {type(send)}")
    if scope["type"] == "http":
        print("About to receive")
        # Get request
        await receive()
        print("\nDEBUG: Received request\n")
        # Send response
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [
                [b"content-type", b"text/plain"],
            ],
        })
        print("\nDEBUG: Sent response start\n") 
        
        await send({
            "type": "http.response.body",
            "body": b"Hello from minimal ASGI app!",
        })
    elif scope["type"] == "lifespan":
        while True:
            print("About to receive from lifespan message")
            message = await receive()
            print(f"DEBUG: Received lifespan message: {message}")
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                break 
    print("DEBUG: Python app finished\n\n")