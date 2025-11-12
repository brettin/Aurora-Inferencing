#!/bin/bash

# pbcast_simple.sh - Simplified PBS broadcast script
# Usage: pbcast_simple.sh <source_directory> <num_parallel_cps>

set -e

# Check arguments
if [ $# -ne 2 ]; then
    echo "Usage: $0 <source_directory> <num_parallel_cps>"
    exit 1
fi

SOURCE_DIR="$1"
NUM_PARALLEL="$2"
DIR_BASENAME=$(basename "$SOURCE_DIR")
DEST_DIR="/dev/shm/$DIR_BASENAME"

# Validate
[ ! -d "$SOURCE_DIR" ] && { echo "Error: Source directory not found"; exit 1; }
[ -z "$PBS_NODEFILE" ] && { echo "Error: PBS_NODEFILE not set"; exit 1; }

# Get unique nodes
mapfile -t ALL_NODES < <(sort -u "$PBS_NODEFILE")
TOTAL_NODES=${#ALL_NODES[@]}

echo "Broadcasting $SOURCE_DIR to $TOTAL_NODES nodes..."
echo "Destination: $DEST_DIR"
echo ""

# Adjust parallel if needed
[ "$NUM_PARALLEL" -gt "$TOTAL_NODES" ] && NUM_PARALLEL=$TOTAL_NODES

# Wave 1: Copy from shared FS to first NUM_PARALLEL nodes
echo "Wave 1: Copying to $NUM_PARALLEL nodes from shared filesystem..."
WAVE1_NODES=("${ALL_NODES[@]:0:$NUM_PARALLEL}")

for node in "${WAVE1_NODES[@]}"; do
    {
        echo "  Copying to $node..."
        ssh "$node" "mkdir -p /dev/shm && rm -rf $DEST_DIR" 2>/dev/null
        rsync -az --quiet "$SOURCE_DIR/" "$node:$DEST_DIR/"
        echo "  ✓ $node"
    } &
done
wait

SUCCESSFUL_NODES=("${WAVE1_NODES[@]}")
echo "Wave 1 complete: ${#SUCCESSFUL_NODES[@]} nodes"
echo ""

# Wave 2+: Tree distribution
REMAINING_NODES=("${ALL_NODES[@]:$NUM_PARALLEL}")
WAVE=2

while [ ${#REMAINING_NODES[@]} -gt 0 ]; do
    echo "Wave $WAVE: Distributing to ${#REMAINING_NODES[@]} remaining nodes..."
    
    NUM_SOURCES=${#SUCCESSFUL_NODES[@]}
    NODES_PER_SOURCE=$(( (${#REMAINING_NODES[@]} + NUM_SOURCES - 1) / NUM_SOURCES ))
    
    NEW_SUCCESSFUL=()
    idx=0
    
    for source_node in "${SUCCESSFUL_NODES[@]}"; do
        for ((i=0; i<NODES_PER_SOURCE && idx<${#REMAINING_NODES[@]}; i++)); do
            target_node="${REMAINING_NODES[$idx]}"
            {
                echo "  $source_node -> $target_node"
                ssh "$target_node" "mkdir -p /dev/shm && rm -rf $DEST_DIR" 2>/dev/null
                ssh "$source_node" "rsync -az --quiet $DEST_DIR/ $target_node:$DEST_DIR/" 2>/dev/null
                echo "  ✓ $target_node"
                echo "$target_node" >> /tmp/pbcast_success_$$
            } &
            ((idx++))
        done
    done
    wait
    
    # Read successful nodes from temp file
    if [ -f /tmp/pbcast_success_$$ ]; then
        mapfile -t NEW_SUCCESSFUL < /tmp/pbcast_success_$$
        rm /tmp/pbcast_success_$$
    fi
    
    echo "Wave $WAVE complete: ${#NEW_SUCCESSFUL[@]} nodes"
    echo ""
    
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

