#!/usr/bin/env python3
import sys
print("Python path:", sys.path)
try:
    import tests.app
    print("Successfully imported tests.app!")
except ImportError as e:
    print(f"Import error: {e}") 