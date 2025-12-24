#!/bin/bash

# pbcast.sh - PBS broadcast script (similar to Slurm's sbcast)
# Efficiently copies large directories to compute nodes using tree-based parallel distribution
#
# Usage: pbcast.sh <source_directory> <num_parallel_cps>
#
# Example: pbcast.sh /lus/flare/projects/model_weights 8
#
# The script will:
# 1. Copy from shared filesystem to /dev/shm/ on num_parallel_cps nodes (wave 1)
# 2. Use those nodes to copy to remaining nodes in parallel (wave 2+)

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Usage function
usage() {
    cat << EOF
Usage: $0 <source_directory> <num_parallel_cps>

Arguments:
  source_directory   - Directory on shared filesystem to broadcast
  num_parallel_cps   - Number of parallel copies in first wave

Environment:
  PBS_NODEFILE       - File containing list of compute nodes (set by PBS)

Example:
  $0 /lus/flare/projects/model_weights 8

The directory will be copied to /dev/shm/\$(basename source_directory) on all compute nodes.

EOF
    exit 1
}

# Check arguments
if [ $# -ne 2 ]; then
    log_error "Invalid number of arguments"
    usage
fi

SOURCE_DIR="$1"
NUM_PARALLEL="$2"

# Validate source directory
if [ ! -d "$SOURCE_DIR" ]; then
    log_error "Source directory does not exist: $SOURCE_DIR"
    exit 1
fi

# Validate PBS_NODEFILE
if [ -z "$PBS_NODEFILE" ]; then
    log_error "PBS_NODEFILE not set. Are you running inside a PBS job?"
    exit 1
fi

if [ ! -f "$PBS_NODEFILE" ]; then
    log_error "PBS_NODEFILE not found: $PBS_NODEFILE"
    exit 1
fi

# Validate num_parallel
if ! [[ "$NUM_PARALLEL" =~ ^[0-9]+$ ]] || [ "$NUM_PARALLEL" -lt 1 ]; then
    log_error "num_parallel_cps must be a positive integer"
    exit 1
fi

# Get unique list of nodes
mapfile -t ALL_NODES < <(sort -u "$PBS_NODEFILE")
TOTAL_NODES=${#ALL_NODES[@]}

if [ "$TOTAL_NODES" -eq 0 ]; then
    log_error "No nodes found in PBS_NODEFILE"
    exit 1
fi

# Get basename for destination
DIR_BASENAME=$(basename "$SOURCE_DIR")
DEST_DIR="/dev/shm/$DIR_BASENAME"

# Calculate source size
SOURCE_SIZE=$(du -sh "$SOURCE_DIR" | awk '{print $1}')

# Print configuration
log_info "=========================================="
log_info "PBS Broadcast Configuration"
log_info "=========================================="
log_info "Source:        $SOURCE_DIR"
log_info "Destination:   $DEST_DIR (on all nodes)"
log_info "Size:          $SOURCE_SIZE"
log_info "Total nodes:   $TOTAL_NODES"
log_info "Parallel wave: $NUM_PARALLEL"
log_info "=========================================="
echo ""

# Adjust NUM_PARALLEL if greater than total nodes
if [ "$NUM_PARALLEL" -gt "$TOTAL_NODES" ]; then
    log_warn "num_parallel_cps ($NUM_PARALLEL) > total nodes ($TOTAL_NODES), adjusting to $TOTAL_NODES"
    NUM_PARALLEL=$TOTAL_NODES
fi

# Function to copy directory to a node
copy_to_node() {
    local source=$1
    local dest_node=$2
    local dest_path=$3
    local log_prefix=$4
    
    log_info "$log_prefix Copying to $dest_node..."
    
    # Use rsync for efficient copying
    if ssh "$dest_node" "mkdir -p /dev/shm && rm -rf $dest_path" 2>/dev/null; then
        if rsync -az --delete "$source/" "$dest_node:$dest_path/" 2>&1 | grep -v "^$"; then
            log_success "$log_prefix Completed: $dest_node"
            return 0
        else
            log_error "$log_prefix Failed: $dest_node (rsync error)"
            return 1
        fi
    else
        log_error "$log_prefix Failed: $dest_node (ssh error)"
        return 1
    fi
}

# Export function for parallel execution
export -f copy_to_node
export -f log_info
export -f log_success
export -f log_error
export RED GREEN YELLOW BLUE NC

# Track successful and failed nodes
declare -a SUCCESSFUL_NODES
declare -a FAILED_NODES

# Wave 1: Copy from shared filesystem to first NUM_PARALLEL nodes
log_info "=========================================="
log_info "Wave 1: Copying from shared filesystem to $NUM_PARALLEL nodes"
log_info "=========================================="

WAVE1_NODES=("${ALL_NODES[@]:0:$NUM_PARALLEL}")
WAVE1_PIDS=()

for node in "${WAVE1_NODES[@]}"; do
    copy_to_node "$SOURCE_DIR" "$node" "$DEST_DIR" "[Wave1]" &
    WAVE1_PIDS+=($!)
done

# Wait for wave 1 to complete
WAVE1_SUCCESS=0
for i in "${!WAVE1_PIDS[@]}"; do
    if wait "${WAVE1_PIDS[$i]}"; then
        SUCCESSFUL_NODES+=("${WAVE1_NODES[$i]}")
        ((WAVE1_SUCCESS++))
    else
        FAILED_NODES+=("${WAVE1_NODES[$i]}")
    fi
done

log_info "Wave 1 complete: $WAVE1_SUCCESS/$NUM_PARALLEL successful"
echo ""

if [ "$WAVE1_SUCCESS" -eq 0 ]; then
    log_error "All Wave 1 copies failed. Aborting."
    exit 1
fi

# Check if all nodes are done
REMAINING_NODES=("${ALL_NODES[@]:$NUM_PARALLEL}")
if [ ${#REMAINING_NODES[@]} -eq 0 ]; then
    log_success "All nodes copied in Wave 1!"
    log_info "=========================================="
    log_info "Summary: ${#SUCCESSFUL_NODES[@]}/$TOTAL_NODES successful"
    if [ ${#FAILED_NODES[@]} -gt 0 ]; then
        log_warn "Failed nodes: ${FAILED_NODES[*]}"
    fi
    exit 0
fi

# Wave 2+: Tree-based distribution from successful wave 1 nodes
log_info "=========================================="
log_info "Wave 2+: Tree-based distribution to remaining ${#REMAINING_NODES[@]} nodes"
log_info "=========================================="

# Use successful wave 1 nodes as sources
SOURCE_NODES=("${SUCCESSFUL_NODES[@]}")
NUM_SOURCES=${#SOURCE_NODES[@]}
WAVE_NUM=2

while [ ${#REMAINING_NODES[@]} -gt 0 ]; do
    log_info "Wave $WAVE_NUM: Distributing to ${#REMAINING_NODES[@]} remaining nodes using $NUM_SOURCES sources"
    
    # Calculate how many nodes each source should copy to
    NODES_PER_SOURCE=$(( (${#REMAINING_NODES[@]} + NUM_SOURCES - 1) / NUM_SOURCES ))
    
    WAVE_PIDS=()
    WAVE_TARGETS=()
    idx=0
    
    for source_node in "${SOURCE_NODES[@]}"; do
        # Assign nodes to this source
        for ((i=0; i<NODES_PER_SOURCE && idx<${#REMAINING_NODES[@]}; i++)); do
            target_node="${REMAINING_NODES[$idx]}"
            WAVE_TARGETS+=("$target_node")
            
            # Copy from source_node to target_node
            (
                log_info "[Wave$WAVE_NUM] $source_node -> $target_node"
                if ssh "$target_node" "mkdir -p /dev/shm && rm -rf $DEST_DIR" 2>/dev/null; then
                    if ssh "$source_node" "rsync -az --delete $DEST_DIR/ $target_node:$DEST_DIR/" 2>&1 | grep -v "^$"; then
                        log_success "[Wave$WAVE_NUM] Completed: $source_node -> $target_node"
                        exit 0
                    else
                        log_error "[Wave$WAVE_NUM] Failed: $source_node -> $target_node (rsync)"
                        exit 1
                    fi
                else
                    log_error "[Wave$WAVE_NUM] Failed: $source_node -> $target_node (ssh)"
                    exit 1
                fi
            ) &
            WAVE_PIDS+=($!)
            
            ((idx++))
        done
    done
    
    # Wait for this wave to complete
    NEW_SUCCESSFUL=()
    for i in "${!WAVE_PIDS[@]}"; do
        if wait "${WAVE_PIDS[$i]}"; then
            SUCCESSFUL_NODES+=("${WAVE_TARGETS[$i]}")
            NEW_SUCCESSFUL+=("${WAVE_TARGETS[$i]}")
        else
            FAILED_NODES+=("${WAVE_TARGETS[$i]}")
        fi
    done
    
    log_info "Wave $WAVE_NUM complete: ${#NEW_SUCCESSFUL[@]}/${#WAVE_TARGETS[@]} successful"
    echo ""
    
    # Update remaining nodes (remove successful ones)
    TEMP_REMAINING=()
    for node in "${REMAINING_NODES[@]}"; do
        if ! [[ " ${NEW_SUCCESSFUL[*]} " =~ " ${node} " ]]; then
            TEMP_REMAINING+=("$node")
        fi
    done
    REMAINING_NODES=("${TEMP_REMAINING[@]}")
    
    # Add newly successful nodes as sources for next wave
    SOURCE_NODES+=("${NEW_SUCCESSFUL[@]}")
    NUM_SOURCES=${#SOURCE_NODES[@]}
    
    ((WAVE_NUM++))
    
    # Safety check: prevent infinite loop
    if [ "$WAVE_NUM" -gt 20 ]; then
        log_error "Too many waves (>20), aborting to prevent infinite loop"
        break
    fi
done

# Final summary
echo ""
log_info "=========================================="
log_info "Broadcast Complete!"
log_info "=========================================="
log_success "Successful: ${#SUCCESSFUL_NODES[@]}/$TOTAL_NODES nodes"

if [ ${#FAILED_NODES[@]} -gt 0 ]; then
    log_warn "Failed: ${#FAILED_NODES[@]} nodes"
    log_warn "Failed nodes:"
    for node in "${FAILED_NODES[@]}"; do
        echo "  - $node"
    done
    exit 1
else
    log_success "All nodes successfully copied!"
    log_info "Directory available at: $DEST_DIR on all nodes"
    exit 0
fi

