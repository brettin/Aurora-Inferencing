#!/bin/bash

# Shell script to run test.coli_v3.py across multiple nodes in parallel
# This version works with the split chunk files that have genome_id as first column

# Enable debug output
set -x

# Get the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HOSTFILE="$SCRIPT_DIR/../../vllm/hostfile"

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

# Check if test.coli_v3.py exists
if [ ! -f "$SCRIPT_DIR/test.coli_v3.py" ]; then
    echo "Error: test.coli_v3.py not found in $SCRIPT_DIR"
    exit 1
fi

# Get the data directory containing chunk files
read -p "Enter the data directory path (containing chunk_*.txt files): " DATA_DIR
if [ ! -d "$DATA_DIR" ]; then
    echo "Error: Data directory $DATA_DIR not found"
    exit 1
fi

# Get list of chunk files
CHUNK_FILES=("$DATA_DIR"/chunk_*.txt)
NUM_CHUNKS=${#CHUNK_FILES[@]}

if [ $NUM_CHUNKS -eq 0 ]; then
    echo "Error: No chunk_*.txt files found in $DATA_DIR"
    exit 1
fi

echo "Found $NUM_CHUNKS chunk files to process"

# Get output directory
read -p "Enter the output directory path (default: ./output_v3): " OUTPUT_DIR
OUTPUT_DIR="${OUTPUT_DIR:-./output_v3}"
mkdir -p "$OUTPUT_DIR"

echo "Output will be written to: $OUTPUT_DIR"

# Get output format
read -p "Enter output format (text/tsv/json, default: tsv): " OUTPUT_FORMAT
OUTPUT_FORMAT="${OUTPUT_FORMAT:-tsv}"

echo "Using output format: $OUTPUT_FORMAT"

# Read all hosts into an array
mapfile -t HOSTS < "$HOSTFILE"
NUM_HOSTS=${#HOSTS[@]}

if [ $NUM_HOSTS -eq 0 ]; then
    echo "Error: No hosts found in hostfile"
    exit 1
fi

echo "Found $NUM_HOSTS hosts"

# Process chunks in batches of NUM_HOSTS
chunk_idx=0
for chunk_file in "${CHUNK_FILES[@]}"; do
    # Determine which host to use (round-robin)
    host_idx=$((chunk_idx % NUM_HOSTS))
    host=${HOSTS[$host_idx]}
    
    # Extract chunk name for output file
    chunk_name=$(basename "$chunk_file" .txt)
    output_file="$OUTPUT_DIR/${chunk_name}_output.${OUTPUT_FORMAT}"
    log_file="$OUTPUT_DIR/${chunk_name}.log"
    
    echo "Processing $chunk_name on host $host"
    
    # Run test.coli_v3.py with the chunk file
    python "$SCRIPT_DIR/test.coli_v3.py" \
        "$chunk_file" \
        "$host" \
        --output "$output_file" \
        --output-format "$OUTPUT_FORMAT" \
        2>&1 > "$log_file" &
    
    chunk_idx=$((chunk_idx + 1))
    
    # If we've launched NUM_HOSTS processes, wait for them to complete
    if [ $((chunk_idx % NUM_HOSTS)) -eq 0 ]; then
        echo "Waiting for batch to complete..."
        wait
    fi
done

# Wait for any remaining processes
echo "Waiting for final batch to complete..."
wait

echo "All chunks have been processed"
echo "Results are in: $OUTPUT_DIR"

