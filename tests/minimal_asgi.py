"""
Minimal ASGI application with no dependencies.
"""
import inspect
import asyncio
import sys
from typing import Callable, Any, Dict, List, Tuple, Optional, Awaitable
import json
import random



async def test_func():
    print("DEBUG: In test_func")
    await asyncio.sleep(1)
    print("DEBUG: Exiting test_func")
    return {"type": "http.response.body", "body": "Hello, world!"}


async def app(scope: Dict[str, Any], receive: Callable[[], Awaitable[Dict[str, Any]]], send: Callable[[Dict[str, Any]], Awaitable[None]]) -> None:
    """
    Minimal ASGI application.
    """
    print("\n\nIn python app")
    print("DEBUG: Python app called")
    print(f"DEBUG: Python version: {sys.version}")
    print(f"DEBUG: scope: {scope}, receive: {receive}, send: {send}")
    print(f"DEBUG: scope type: {type(scope)}, receive type: {type(receive)}, send type: {type(send)}\n")

    # Inspect test func for info
    print(f"DEBUG: test_func type: {type(test_func)}")
    print(f"DEBUG: test_func dir: {dir(test_func)}")
    print(f"DEBUG: test_func is __call__: {getattr(test_func, '__call__', None)}")
    print(f"DEBUG: test_func is coroutine: {asyncio.iscoroutinefunction(test_func)}")
    print(f"DEBUG: test_func qualname: {getattr(test_func, "__qualname__")}")
    print(f"DEBUG: test_func flags: {test_func.__code__.co_flags}")
    print(f"DEBUG: test_func callable: {callable(test_func)}\n")

    # Inspect the receive and send objects
    print(f"DEBUG: receive dir: {dir(receive)}")
    print(f"DEBUG: receive is coroutine: {asyncio.iscoroutinefunction(receive)}")
    print(f"DEBUG: receive callable: {callable(receive)}\n")
    # print(f"DEBUG: receive flags: {receive.__code__.co_flags}")
    
    # Inspect the send object
    print(f"DEBUG: send dir: {dir(send)}")
    print(f"DEBUG: send is coroutine: {asyncio.iscoroutinefunction(send)}")
    print(f"DEBUG: send callable: {callable(send)}\n")
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
            "body": json.dumps({
                random.choice(
                    ["Hello", "World", "Zig", "Python"]
                    ): random.choice(
                        ["Something", "Nothing", "Everything", "Nothing"]
                        )}),
        })
    elif scope["type"] == "lifespan":
        while True:
            print("About to receive from lifespan message")
            try:
                message = await receive()
                message_str = json.dumps(message)
                msg = f"Test error: {message_str}"
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