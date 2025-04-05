#!/bin/bash

# Get the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HOSTFILE="$SCRIPT_DIR/hostfile"

# Check if hostfile exists
if [ ! -f "$HOSTFILE" ]; then
    echo "Error: hostfile not found at $HOSTFILE"
    exit 1
fi

# Check if start_vllm.sh exists and is executable
if [ ! -x "$SCRIPT_DIR/start_vllm.sh" ]; then
    echo "Error: start_vllm.sh not found or not executable in $SCRIPT_DIR"
    exit 1
fi

# Loop through each host in the hostfile
while read -r host; do
    # Skip empty lines
    [ -z "$host" ] && continue
    
    echo "Starting vLLM on host: $host"
    if ! ssh "$host" "cd $SCRIPT_DIR && ./start_vllm.sh > $host.log &"; then
        echo "Error: Failed to start vLLM on host $host"
        exit 1
    fi
done < "$HOSTFILE"

echo "All vLLM instances have been started" 
