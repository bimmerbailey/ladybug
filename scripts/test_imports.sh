#!/bin/bash
# Script to test importing Python modules
set -e

echo "==== Python Import Tester ===="
echo "This script tests importing Python modules in different ways"
echo

# Get Python version and path
echo "Python information:"
python3 --version
echo "Python path: $(which python3)"
echo

# Test direct imports
echo "==== Testing direct imports ===="
echo "Testing import_helper.py:"
python3 import_helper.py tests.robust:app

echo
echo "Testing debug_asgi.py:" 
python3 debug_asgi.py

echo
echo "==== Testing imports via virtual environment ===="
if [ -d "venv" ]; then
    echo "Using existing venv"
else
    echo "Creating virtual environment"
    python3 -m venv venv
fi

echo "Activating virtual environment"
source venv/bin/activate

echo "Python in venv: $(which python)"
python --version

echo "Testing import in venv:"
python import_helper.py tests.robust:app

echo "Deactivating virtual environment"
deactivate

echo
echo "==== Testing with Zig application ===="
echo "Running with debug_asgi.py:"
./zig-out/bin/ladybug -app debug_asgi:app

echo "Running with import_helper.py:"
./zig-out/bin/ladybug -app import_helper:app

echo "Running with tests/robust.py:"
./zig-out/bin/ladybug -app tests.robust:app

echo
echo "==== Import testing complete ====" 