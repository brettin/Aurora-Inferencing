#!/bin/bash

# Enable debug output
set -x

# Get the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HOSTFILE="$SCRIPT_DIR/../../vllm-0.6.6.post2/hostfile"

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
if [ ! -f "$SCRIPT_DIR/test.coli.py" ]; then
    echo "Error: test.coli.py not found or not executable in $SCRIPT_DIR"
    exit 1
fi

# Get the number of directories to process
read -p "Enter the number of directories to process (0 to N-1): " NUM_DIRS
if ! [[ "$NUM_DIRS" =~ ^[0-9]+$ ]]; then
    echo "Error: Please enter a valid number"
    exit 1
fi

echo "Will process directories from 0 to $((NUM_DIRS-1))"

# Read all hosts into an array
mapfile -t HOSTS < "$HOSTFILE"
NUM_HOSTS=${#HOSTS[@]}

if [ $NUM_HOSTS -eq 0 ]; then
    echo "Error: No hosts found in hostfile"
    exit 1
fi

echo "Found $NUM_HOSTS hosts"

# Process directories in batches of NUM_HOSTS
for ((d=0; d<NUM_DIRS; d+=NUM_HOSTS)); do
    echo "Processing batch starting at directory $d"
    
    # Process up to NUM_HOSTS directories in this batch
    for ((i=0; i<NUM_HOSTS && d+i<NUM_DIRS; i++)); do
        dir=$((d+i))
        host=${HOSTS[$i]}
        
        echo "Running test.coli.py with directory $dir and host $host"
        python "$SCRIPT_DIR/test.coli.py" "$dir" "$host" 2>&1 > test.coli.py.log &
    done
    
    # Wait for all processes in this batch to complete
    echo "Waiting for batch to complete..."
    wait
done

echo "All directories have been processed"
