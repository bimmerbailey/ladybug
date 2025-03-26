"""
Minimal ASGI application with no dependencies.
"""
import inspect
import asyncio
import sys
from typing import Callable, Any, Dict, List, Tuple, Optional, Awaitable

async def app(scope: Dict[str, Any], receive: Callable[[], Awaitable[Dict[str, Any]]], send: Callable[[Dict[str, Any]], Awaitable[None]]) -> None:
    """
    Minimal ASGI application.
    """
    print("\nIn python app")
    print("DEBUG: Python app called")
    print(f"DEBUG: Python version: {sys.version}")
    print(f"DEBUG: scope: {scope}, receive: {receive}, send: {send}")
    print(f"DEBUG: scope type: {type(scope)}, receive type: {type(receive)}, send type: {type(send)}")
    
    # Inspect the receive and send objects
    print(f"DEBUG: receive dir: {dir(receive)}")
    print(f"DEBUG: receive is coroutine: {asyncio.iscoroutinefunction(receive)}")
    print(f"DEBUG: receive callable: {callable(receive)}")
    # print(f"DEBUG: receive doc: {receive.__doc__ if hasattr(receive, '__doc__') else 'No docstring'}")
    
    # Inspect the send object
    print(f"DEBUG: send dir: {dir(send)}")
    print(f"DEBUG: send is coroutine: {asyncio.iscoroutinefunction(send)}")
    print(f"DEBUG: send callable: {callable(send)}")
    # print(f"DEBUG: send doc: {send.__doc__ if hasattr(send, '__doc__') else 'No docstring'}")
    
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
            try:
                message = receive()
                raise Exception("Test error")
            except Exception as e:
                print(f"DEBUG: Error receiving from lifespan: {e}")
                raise
            
            print(f"DEBUG: Received lifespan message: {message}")
            if message["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
                print("Sent startup complete")
                break
            elif message["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                print("Sent shutdown complete")
                break 
            break
    print("DEBUG: Python app finished\n\n")