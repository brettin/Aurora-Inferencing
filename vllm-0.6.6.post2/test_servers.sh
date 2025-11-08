#!/bin/bash

# Enable debug output
# set -x

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

#echo "Contents of hostfile:"
#cat "$HOSTFILE"
#echo "-------------------"

# Initialize counters
ERROR_COUNT=0
SUCCESS_COUNT=0
TOTAL_HOSTS=0

# Initialize arrays to track servers
declare -a UP_SERVERS
declare -a DOWN_SERVERS

# Function to test a vLLM server
test_server() {
    local host=$1
    # echo "Testing vLLM server on host: $host"
    
    # Run curl command with timeout
    if curl -s -m 10 "http://${host}:8000/v1/models" > /dev/null; then
        #echo "Server is UP on $host"
        UP_SERVERS+=("$host")
        return 0
    else
        echo "Server is DOWN on $host"
        DOWN_SERVERS+=("$host")
        return 1
    fi
}

echo "Starting server tests..."
# Test all hosts
while IFS= read -r host || [ -n "$host" ]; do
    # Skip empty lines
    if [ -z "$host" ]; then
        continue
    fi
    
    TOTAL_HOSTS=$((TOTAL_HOSTS + 1))
    name=$(echo $host | cut -f1 -d'.')
    if test_server "$name"; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
done < "$HOSTFILE"

# Print summary
echo "----------------------------------------"
echo "Summary:"
echo "Total hosts tested: $TOTAL_HOSTS"
echo "Servers UP: $SUCCESS_COUNT"
echo "Servers DOWN: $ERROR_COUNT"
echo "----------------------------------------"

# Print DOWN servers if any
if [ $ERROR_COUNT -gt 0 ]; then
    echo ""
    echo "DOWN_SERVERS:"
    for server in "${DOWN_SERVERS[@]}"; do
        echo "$server"
    done
    echo ""
    echo "Warning: $ERROR_COUNT server(s) are down"
    exit 1
fi

echo "All vLLM servers are up and running" 
