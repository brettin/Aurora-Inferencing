#!/bin/bash

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

# Check if test.coli.py exists and is executable
if [ ! -x "$SCRIPT_DIR/test.coli.py" ]; then
    echo "Error: test.coli.py not found or not executable in $SCRIPT_DIR"
    exit 1
fi

# Function to test if a vLLM server is running
test_server() {
    local host=$1
    echo "Testing vLLM server on host: $host"
    
    # Run curl command with timeout
    if curl -s -m 10 "http://${host}:8000/v1/models" > /dev/null; then
        echo "Server is UP on $host"
        return 0
    else
        echo "Server is DOWN on $host"
        return 1
    fi
}

# Find all running servers
declare -a RUNNING_SERVERS
echo "Finding running servers..."
while IFS= read -r host || [ -n "$host" ]; do
    # Skip empty lines
    if [ -z "$host" ]; then
        continue
    fi
    
    if test_server "$host"; then
        RUNNING_SERVERS+=("$host")
    fi
done < "$HOSTFILE"

# Check if we have any running servers
if [ ${#RUNNING_SERVERS[@]} -eq 0 ]; then
    echo "Error: No running servers found"
    exit 1
fi

echo "Found ${#RUNNING_SERVERS[@]} running servers:"
for server in "${RUNNING_SERVERS[@]}"; do
    echo "  - $server"
done

# Find all directories to process
declare -a DIRECTORIES
echo "Finding directories to process..."
for dir in "$SCRIPT_DIR"/[0-9]*; do
    if [ -d "$dir" ]; then
        dir_name=$(basename "$dir")
        if [[ "$dir_name" =~ ^[0-9]+$ ]]; then
            DIRECTORIES+=("$dir_name")
        fi
    fi
done

# Sort directories numerically
IFS=$'\n' sorted_dirs=($(sort -n <<<"${DIRECTORIES[*]}"))
unset IFS

echo "Found ${#sorted_dirs[@]} directories to process:"
for dir in "${sorted_dirs[@]}"; do
    echo "  - $dir"
done

# Process directories in batches
current_server_index=0
for dir in "${sorted_dirs[@]}"; do
    # Get the current server
    server="${RUNNING_SERVERS[$current_server_index]}"
    
    echo "Processing directory $dir on server $server"
    
    # Execute test.coli.py on the remote server
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$server" "cd $SCRIPT_DIR && ./test.coli.py $dir" &
    
    # Move to the next server
    current_server_index=$((current_server_index + 1))
    
    # If we've used all servers, wait for all background processes to complete
    if [ $current_server_index -eq ${#RUNNING_SERVERS[@]} ]; then
        echo "All servers are busy, waiting for processes to complete..."
        wait
        current_server_index=0
    fi
done

# Wait for any remaining background processes
wait

echo "All directories have been processed" 