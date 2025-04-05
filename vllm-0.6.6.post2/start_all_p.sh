#!/bin/bash

# Exit on any error
set -e

# Enable debug output
set -x

# Get the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HOSTFILE="$SCRIPT_DIR/hostfile"

echo "Script directory: $SCRIPT_DIR"
echo "Hostfile path: $HOSTFILE"

# Check if hostfile exists and has content
if [ ! -f "$HOSTFILE" ]; then
    echo "Error: hostfile not found at $HOSTFILE"
    exit 1
fi

if [ ! -s "$HOSTFILE" ]; then
    echo "Error: hostfile is empty at $HOSTFILE"
    exit 1
fi

echo "Contents of hostfile:"
cat "$HOSTFILE"
echo "-------------------"

# Check if start_vllm.sh exists and is executable
if [ ! -x "$SCRIPT_DIR/start_vllm.sh" ]; then
    echo "Error: start_vllm.sh not found or not executable in $SCRIPT_DIR"
    exit 1
fi

# Initialize counters
ERROR_COUNT=0
SUCCESS_COUNT=0
TOTAL_HOSTS=0

# Create a temporary directory for log files
TEMP_DIR=$(mktemp -d)
echo "Created temporary directory: $TEMP_DIR"
# trap 'rm -rf "$TEMP_DIR"' EXIT

# Function to start vLLM on a host
start_vllm() {
    echo "DEBUG: Entering start_vllm function"
    local host=$1
    echo "DEBUG: Host parameter: $host"
    local log_file="$TEMP_DIR/${host}.log"
    echo "DEBUG: Log file: $log_file"
    
    echo "Starting vLLM on host: $host"
    # Run SSH command and capture its output
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host" "cd $SCRIPT_DIR && source ./env.sh && ./start_vllm.sh" 2>&1 > "$log_file"; then
        echo "Successfully started vLLM on $host"
        return 0
    else
        echo "Failed to start vLLM on $host"
        return 1
    fi
}

# Initialize pids array
declare -a pids

echo "DEBUG: About to start reading hostfile"
# Launch all hosts in parallel
while IFS= read -r host || [ -n "$host" ]; do
    echo "DEBUG: Read host: '$host'"
    # Skip empty lines
    if [ -z "$host" ]; then
        echo "DEBUG: Skipping empty line"
        continue
    fi
    
    echo "DEBUG: Processing host: '$host'"
    TOTAL_HOSTS=$((TOTAL_HOSTS + 1))
    echo "DEBUG: Calling start_vllm with host: '$host'"
    start_vllm "$host" &
    pid=$!
    pids+=($pid)
    echo "DEBUG: Started process with PID: $pid"
done < "$HOSTFILE"

echo "DEBUG: Finished reading hostfile"
echo "Waiting for all processes to complete..."
echo "Number of processes to wait for: ${#pids[@]}"

# Wait for all background processes and count successes/failures
for pid in "${pids[@]}"; do
    echo "Waiting for PID: $pid"
    if wait $pid; then
        echo "Process $pid completed successfully"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "Process $pid failed"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
done

# Print summary
echo "----------------------------------------"
echo "Summary:"
echo "Total hosts attempted: $TOTAL_HOSTS"
echo "Successful starts: $SUCCESS_COUNT"
echo "Failed starts: $ERROR_COUNT"
echo "----------------------------------------"

# Exit with error if any failures occurred
if [ $ERROR_COUNT -gt 0 ]; then
    echo "Warning: Failed to start vLLM on $ERROR_COUNT host(s)"
    exit 1
fi

echo "All vLLM instances have been started successfully" 
