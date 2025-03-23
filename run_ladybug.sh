#!/bin/bash
# Wrapper script for running Ladybug with proper Python path settings

# Get the absolute path to the current directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Print diagnostic information
echo "====== Ladybug Wrapper ======"
echo "Working directory: $SCRIPT_DIR"
echo "Current PYTHONPATH: $PYTHONPATH"

# Add current directory to PYTHONPATH
export PYTHONPATH="$SCRIPT_DIR:$PYTHONPATH"
echo "New PYTHONPATH: $PYTHONPATH"

# Run the Ladybug server with the provided arguments
echo "Running: ./zig-out/bin/ladybug $@"
echo "============================="
./zig-out/bin/ladybug "$@"


# Store exit code
EXIT_CODE=$?

echo "============================="
echo "Ladybug exited with code: $EXIT_CODE"
exit $EXIT_CODE 