#!/bin/bash

# pbcast_simple.sh - Simplified PBS broadcast script
# Usage: pbcast_simple.sh <source_directory> <num_parallel_cps>
#
# IMPORTANT: This script must be located on a shared filesystem accessible by all nodes
#            (temp files are created in the script's directory)

# Note: Don't use 'set -e' because background jobs may fail without stopping the script
set -o pipefail

# Check arguments
if [ $# -ne 2 ]; then
    echo "Usage: $0 <source_directory> <num_parallel_cps>"
    exit 1
fi

SOURCE_DIR="$1"
NUM_PARALLEL="$2"
DIR_BASENAME=$(basename "$SOURCE_DIR")
DEST_DIR="/dev/shm/$DIR_BASENAME"

# Get script directory for temp files (on shared filesystem)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Validate
[ ! -d "$SOURCE_DIR" ] && { echo "Error: Source directory not found"; exit 1; }
[ -z "$PBS_NODEFILE" ] && { echo "Error: PBS_NODEFILE not set"; exit 1; }

# Write the contents of the node file to a file in SCRIPT_DIR
cp "$PBS_NODEFILE" "$SCRIPT_DIR/hostfile"
# Get unique nodes
mapfile -t ALL_NODES < <(sort -u "$PBS_NODEFILE")
TOTAL_NODES=${#ALL_NODES[@]}

echo "Broadcasting $SOURCE_DIR to $TOTAL_NODES nodes..."
echo "Destination: $DEST_DIR"
echo ""

# Adjust parallel if needed
[ "$NUM_PARALLEL" -gt "$TOTAL_NODES" ] && NUM_PARALLEL=$TOTAL_NODES

# Wave 1: Copy from shared FS to first NUM_PARALLEL nodes
echo $(date)": Wave 1: Copying to $NUM_PARALLEL nodes from shared filesystem..."
WAVE1_NODES=("${ALL_NODES[@]:0:$NUM_PARALLEL}")

TEMP_SUCCESS_FILE="$SCRIPT_DIR/.pbcast_wave1_$$"
rm -f "$TEMP_SUCCESS_FILE"

for node in "${WAVE1_NODES[@]}"; do
    echo "running optimized rsync"
    {
        echo "  Copying to $node..."
        if ssh "$node" "mkdir -p /dev/shm && rm -rf $DEST_DIR" 2>/dev/null && \
           rsync -a --quiet --inplace --no-compress --whole-file "$SOURCE_DIR/" "$node:$DEST_DIR/" 2>/dev/null; then
            echo "  ✓ $node"
            echo "$node" >> "$TEMP_SUCCESS_FILE"
        else
            echo "  ✗ $node (failed)"
        fi
    } &
done
echo "waiting"
wait

# Read successful nodes
SUCCESSFUL_NODES=()
if [ -f "$TEMP_SUCCESS_FILE" ]; then
    mapfile -t SUCCESSFUL_NODES < "$TEMP_SUCCESS_FILE"
    rm -f "$TEMP_SUCCESS_FILE"
fi
echo $(date)": Wave 1 complete: ${#SUCCESSFUL_NODES[@]} nodes"
echo ""

# Check if Wave 1 had any success
if [ ${#SUCCESSFUL_NODES[@]} -eq 0 ]; then
    echo "ERROR: All Wave 1 copies failed. Aborting."
    exit 1
fi

# Wave 2+: Tree distribution
REMAINING_NODES=("${ALL_NODES[@]:$NUM_PARALLEL}")
WAVE=2

while [ ${#REMAINING_NODES[@]} -gt 0 ]; do
	echo $(date)": Wave $WAVE: Distributing to ${#REMAINING_NODES[@]} remaining nodes..."
    
    NUM_SOURCES=${#SUCCESSFUL_NODES[@]}
    NODES_PER_SOURCE=$(( (${#REMAINING_NODES[@]} + NUM_SOURCES - 1) / NUM_SOURCES ))
    
    TEMP_WAVE_FILE="$SCRIPT_DIR/.pbcast_wave${WAVE}_$$"
    rm -f "$TEMP_WAVE_FILE"
    
    idx=0
    
    for source_node in "${SUCCESSFUL_NODES[@]}"; do
        for ((i=0; i<NODES_PER_SOURCE && idx<${#REMAINING_NODES[@]}; i++)); do
            target_node="${REMAINING_NODES[$idx]}"
            {
                echo "  $source_node -> $target_node"
                if ssh "$target_node" "mkdir -p /dev/shm && rm -rf $DEST_DIR" 2>/dev/null && \
                   ssh "$source_node" "rsync -a --quiet --inplace --no-compress --whole-file $DEST_DIR/ $target_node:$DEST_DIR/" 2>/dev/null; then
                    echo "  ✓ $target_node"
                    echo "$target_node" >> "$TEMP_WAVE_FILE"
                else
                    echo "  ✗ $target_node (failed)"
                fi
            } &
            ((idx++))
        done
    done
    wait
    
    # Read successful nodes from temp file
    NEW_SUCCESSFUL=()
    if [ -f "$TEMP_WAVE_FILE" ]; then
        mapfile -t NEW_SUCCESSFUL < "$TEMP_WAVE_FILE"
        rm -f "$TEMP_WAVE_FILE"
    fi
    
    echo $(date)": Wave $WAVE complete: ${#NEW_SUCCESSFUL[@]} nodes"
    echo ""
    
    # Check if we made any progress
    if [ ${#NEW_SUCCESSFUL[@]} -eq 0 ]; then
        echo "WARNING: No progress in Wave $WAVE. Stopping."
        break
    fi
    
    # Update for next wave
    SUCCESSFUL_NODES+=("${NEW_SUCCESSFUL[@]}")
    
    # Remove successful nodes from remaining
    TEMP_REMAINING=()
    for node in "${REMAINING_NODES[@]}"; do
        if ! [[ " ${NEW_SUCCESSFUL[*]} " =~ " ${node} " ]]; then
            TEMP_REMAINING+=("$node")
        fi
    done
    REMAINING_NODES=("${TEMP_REMAINING[@]}")
    
    ((WAVE++))
    [ "$WAVE" -gt 20 ] && break
done

echo "=========================================="
echo "Broadcast complete!"
echo "Total nodes: $TOTAL_NODES"
echo "Successful: ${#SUCCESSFUL_NODES[@]}"
echo "Location: $DEST_DIR on all nodes"
echo "=========================================="

# Cleanup temp files
rm -f "$SCRIPT_DIR/.pbcast_wave"*_$$

