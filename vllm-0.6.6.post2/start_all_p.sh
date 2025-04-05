#!/bin/bash

# Exit on any error
set -e

# Enable debug output
set -x

# Get the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HOSTFILE="$SCRIPT_DIR/hostfile"

echo "$(date) Script directory: $SCRIPT_DIR"
echo "$(date) Hostfile path: $HOSTFILE"

# Check if hostfile exists and has content
if [ ! -f "$HOSTFILE" ]; then
    echo "$(date) Error: hostfile not found at $HOSTFILE"
    exit 1
fi

if [ ! -s "$HOSTFILE" ]; then
    echo "$(date) Error: hostfile is empty at $HOSTFILE"
    exit 1
fi

echo "$(date) Contents of hostfile:"
cat "$HOSTFILE"
echo "$(date) -------------------"

# Check if start_vllm.sh exists and is executable
if [ ! -x "$SCRIPT_DIR/start_vllm.sh" ]; then
    echo "$(date) Error: start_vllm.sh not found or not executable in $SCRIPT_DIR"
    exit 1
fi

# Initialize counters
ERROR_COUNT=0
SUCCESS_COUNT=0
TOTAL_HOSTS=0

# Create a temporary directory for log files
TEMP_DIR=$(mktemp -d)
echo "$(date) Created temporary directory: $TEMP_DIR"
# trap 'rm -rf "$TEMP_DIR"' EXIT

# Function to start vLLM on a host
start_vllm() {
    echo "$(date) DEBUG: Entering start_vllm function"
    local host=$1
    echo "$(date) DEBUG: Host parameter: $host"
    local log_file="$TEMP_DIR/${host}.log"
    echo "$(date) DEBUG: Log file: $log_file"
    
    echo "$(date) Starting vLLM on host: $host"
    # Run SSH command and capture its output
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host" "cd $SCRIPT_DIR && source ./env.sh && ./start_vllm.sh" 2>&1 > "$log_file"; then
        echo "$(date) Successfully started vLLM on $host"
        return 0
    else
        echo "$(date) Failed to start vLLM on $host"
        return 1
    fi
}

# Initialize pids array
declare -a pids

echo "$(date) DEBUG: About to start reading hostfile"
# Launch all hosts in parallel
while IFS= read -r host || [ -n "$host" ]; do
    echo "$(date) DEBUG: Read host: '$host'"
    # Skip empty lines
    if [ -z "$host" ]; then
        echo "$(date) DEBUG: Skipping empty line"
        continue
    fi
    
    echo "$(date) DEBUG: Processing host: '$host'"
    TOTAL_HOSTS=$((TOTAL_HOSTS + 1))
    echo "$(date) DEBUG: Calling start_vllm with host: '$host'"
    start_vllm "$host" &
    pid=$!
    pids+=($pid)
    echo "$(date) DEBUG: Started process with PID: $pid"
done < "$HOSTFILE"

echo "$(date) DEBUG: Finished reading hostfile"
echo "$(date) Waiting for all processes to complete..."
echo "$(date) Number of processes to wait for: ${#pids[@]}"

# Wait for all background processes and count successes/failures
for pid in "${pids[@]}"; do
    echo "$(date) Waiting for PID: $pid"
    if wait $pid; then
        echo "$(date) Process $pid completed successfully"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "$(date) Process $pid failed"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
done

# Print summary
echo "$(date) ----------------------------------------"
echo "$(date) Summary:"
echo "$(date) Total hosts attempted: $TOTAL_HOSTS"
echo "$(date) Successful starts: $SUCCESS_COUNT"
echo "$(date) Failed starts: $ERROR_COUNT"
echo "$(date) ----------------------------------------"

# Exit with error if any failures occurred
if [ $ERROR_COUNT -gt 0 ]; then
    echo "$(date) Warning: Failed to start vLLM on $ERROR_COUNT host(s)"
    exit 1
fi

echo "$(date) All vLLM instances have been started successfully" 
