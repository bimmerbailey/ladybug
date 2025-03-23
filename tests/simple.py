"""
Ultra-simple ASGI application for testing.
"""

async def app(scope, receive, send):
    """
    Minimalist ASGI application.
    """
    print(f"Received request: {scope['type']}")
    
    if scope["type"] == "http":
        # Wait for the request
        await receive()
        
        # Send response headers
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [
                [b"content-type", b"text/plain"],
            ],
        })
        
        # Send response body
        await send({
            "type": "http.response.body",
            "body": b"Hello from simple ASGI app!",
        })
    elif scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                break 