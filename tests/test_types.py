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

class CustomCoroutine:
    def __init__(self, value=None):
        self._value = value
        self._is_coroutine = True  # Mark as coroutine
        
    def __await__(self):
        # The __await__ method must return an iterator
        async def _async_wrapper():
            await asyncio.sleep(1)  # Simulate some async work
            return self._value
            
        return _async_wrapper().__await__()
    
    async def __call__(self):
        # Make the object callable as a coroutine
        await asyncio.sleep(1)
        return self._value

    # Optional: Add methods that coroutines support
    def send(self, value):
        self._value = value
        return self._value
        
    def throw(self, typ, val=None, tb=None):
        raise typ(val).with_traceback(tb)
        
    def close(self):
        try:
            self.throw(GeneratorExit)
        except (GeneratorExit, StopIteration):
            pass

# Example usage:
async def test():
    coro = CustomCoroutine(42)
    result = await coro  # Will wait 1 second and return 42
    print(result)
    
    # Can also be called
    result2 = await coro()  # Will wait 1 second and return 42
    print(result2)

coro_tester = CustomCoroutine(32)

# Inspect test func for info
print(f"DEBUG: test_func type: {type(test_func)}")
print(f"DEBUG: test_func dir: {dir(test_func)}")
print(f"DEBUG: test_func is __call__: {getattr(test_func, '__call__', None)}")
print(f"DEBUG: test_func is coroutine: {asyncio.iscoroutinefunction(test_func)}")
print(f"DEBUG: test_func qualname: {getattr(test_func, "__qualname__")}")
print(f"DEBUG: test_func flags: {test_func.__code__.co_flags}")
print(f"DEBUG: test_func callable: {callable(test_func)}\n")

# Inspect callable for info
print(f"DEBUG: callable type: {type(coro_tester)}")
print(f"DEBUG: callable dir: {dir(coro_tester)}")
print(f"DEBUG: callable is coroutine: {asyncio.iscoroutinefunction(coro_tester)}")
    # print(f"DEBUG: callable flags: {coro_tester.__code__.co_flags}")