#!/usr/bin/env python3
"""
Import helper for the Zig ASGI server.
This module attempts different import strategies to load ASGI applications.
"""
import os
import sys
import importlib
import importlib.util
import traceback

def setup_paths():
    """Add current directory and parent directories to sys.path."""
    cwd = os.getcwd()
    if cwd not in sys.path:
        sys.path.insert(0, cwd)
        print(f"Added current directory to sys.path: {cwd}")
    
    # Add parent directory
    parent = os.path.dirname(cwd)
    if parent not in sys.path:
        sys.path.insert(0, parent)
        print(f"Added parent directory to sys.path: {parent}")
    
    print(f"Python path: {sys.path}")

def import_module_direct(module_path):
    """Import a module using Python's import mechanism."""
    try:
        print(f"Attempting direct import of {module_path}")
        module = importlib.import_module(module_path)
        print(f"Successfully imported {module_path}: {getattr(module, '__file__', 'unknown location')}")
        return module
    except ImportError as e:
        print(f"Direct import failed for {module_path}: {e}")
        traceback.print_exc()
        return None

def import_by_path(file_path, module_name=None):
    """Import a module from a file path."""
    try:
        if not os.path.exists(file_path):
            print(f"File not found: {file_path}")
            return None
        
        if module_name is None:
            module_name = os.path.splitext(os.path.basename(file_path))[0]
        
        print(f"Attempting to import {module_name} from {file_path}")
        spec = importlib.util.spec_from_file_location(module_name, file_path)
        if spec is None:
            print(f"Could not create spec for {file_path}")
            return None
        
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        spec.loader.exec_module(module)
        print(f"Successfully imported {module_name} from {file_path}")
        return module
    except Exception as e:
        print(f"Path-based import failed for {file_path}: {e}")
        traceback.print_exc()
        return None

def load_asgi_app(app_spec):
    """
    Load an ASGI application from a specification string.
    
    Format: module:app_name where module can be:
      - A module name (tests.app)
      - A file path (tests/app.py)
    """
    if ":" not in app_spec:
        print(f"Invalid app specification: {app_spec}, must be in format 'module:app_name'")
        return None
    
    module_path, app_name = app_spec.split(":", 1)
    module = None
    
    # Setup paths to improve import chances
    setup_paths()
    
    # First try direct import
    module = import_module_direct(module_path)
    
    # If direct import fails, try file-based import
    if module is None and (module_path.endswith(".py") or "/" in module_path or "\\" in module_path):
        # Strip .py if present
        file_path = module_path
        if not file_path.endswith(".py"):
            file_path += ".py"
        
        # Use absolute path if not already
        if not os.path.isabs(file_path):
            file_path = os.path.abspath(file_path)
        
        # Try to import from file path
        module_name = os.path.splitext(os.path.basename(file_path))[0]
        module = import_by_path(file_path, module_name)
    
    # If we still don't have a module, try a more aggressive approach
    if module is None:
        print("Attempting fallback import strategies...")
        
        # Try to convert module path to file path
        converted_path = module_path.replace(".", "/")
        file_paths_to_try = [
            f"{converted_path}.py",
            os.path.join(converted_path, "__init__.py"),
        ]
        
        for path in file_paths_to_try:
            if os.path.exists(path):
                print(f"Found file at {path}")
                module = import_by_path(path, module_path)
                if module is not None:
                    break
    
    if module is None:
        print(f"Failed to import module {module_path} after trying all strategies")
        return None
    
    # Get the application from the module
    try:
        if not hasattr(module, app_name):
            print(f"Module {module_path} has no attribute {app_name}")
            print(f"Available attributes: {dir(module)}")
            return None
        
        app = getattr(module, app_name)
        print(f"Successfully loaded ASGI app {app_name} from {module_path}")
        return app
    except Exception as e:
        print(f"Error getting app {app_name} from module: {e}")
        traceback.print_exc()
        return None

# Import function to expose asynchronously
async def import_asgi(scope, receive, send):
    """ASGI application that attempts to import another ASGI application."""
    try:
        path = scope.get("path", "")
        query_string = scope.get("query_string", b"").decode("utf-8", "replace")
        print(f"Received request to import_asgi: {path}?{query_string}")
        
        # Extract app spec from query string
        app_spec = None
        for param in query_string.split("&"):
            if "=" in param:
                key, value = param.split("=", 1)
                if key == "app":
                    app_spec = value
        
        if not app_spec:
            # Return error response
            await send({
                "type": "http.response.start",
                "status": 400,
                "headers": [
                    [b"content-type", b"text/plain"],
                ],
            })
            await send({
                "type": "http.response.body",
                "body": b"Error: Missing 'app' parameter in query string",
            })
            return
        
        # Try to load the app
        print(f"Attempting to load app: {app_spec}")
        app = load_asgi_app(app_spec)
        
        if app is None:
            # Return error response
            await send({
                "type": "http.response.start",
                "status": 500,
                "headers": [
                    [b"content-type", b"text/plain"],
                ],
            })
            await send({
                "type": "http.response.body",
                "body": f"Error: Failed to load ASGI app '{app_spec}'".encode(),
            })
            return
        
        # If we got here, we successfully loaded the app
        # Return success response
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [
                [b"content-type", b"text/plain"],
            ],
        })
        await send({
            "type": "http.response.body",
            "body": f"Successfully loaded ASGI app: {app_spec}".encode(),
        })
        
    except Exception as e:
        print(f"Error in import_asgi: {e}")
        traceback.print_exc()
        
        # Try to send error response
        try:
            await send({
                "type": "http.response.start",
                "status": 500,
                "headers": [
                    [b"content-type", b"text/plain"],
                ],
            })
            await send({
                "type": "http.response.body",
                "body": f"Internal error: {str(e)}".encode(),
            })
        except:
            pass

# Create an app that can be loaded by the Zig server
app = import_asgi

# For testing purposes
if __name__ == "__main__":
    if len(sys.argv) > 1:
        app_spec = sys.argv[1]
        print(f"Testing import of {app_spec}")
        app = load_asgi_app(app_spec)
        if app:
            print(f"Successfully loaded {app_spec}: {app}")
        else:
            print(f"Failed to load {app_spec}")
    else:
        print("Usage: python import_helper.py module:app_name")
        print("Example: python import_helper.py tests.robust:app") 