"""
Minimal ASGI application with no dependencies.
"""

async def app(scope, receive, send):
    """
    Minimal ASGI application.
    """
    print("\nDEBUG: App called\n")
    if scope["type"] == "http":
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
            message = await receive()
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                break 