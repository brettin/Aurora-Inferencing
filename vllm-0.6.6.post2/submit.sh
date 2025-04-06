#!/bin/bash
#PBS -N submit_all_p
#PBS -l walltime=00:60:00
#PBS -A candle_aesp_CNDA
#PBS -q debug-scaling
#PBS -o output.log
#PBS -e error.log
#PBS -l select=20
#PBS -l filesystems=flare:home
#PBS -l place=scatter

# Exit on any error and enable debug output
set -e
set -x

echo "$(date) Script directory: $PBS_O_WORKDIR"
echo "$(date) Hostfile path: $PBS_NODEFILE"
cd $PBS_O_WORKDIR

# Check if hostfile exists and has content
if [ ! -f "$PBS_NODEFILE" ]; then
    echo "$(date) Error: hostfile not found at $PBS_NODEFILE"
    exit 1
fi

if [ ! -s "$PBS_NODEFILE" ]; then
    echo "$(date) Error: hostfile is empty at $PBS_NODEFILE"
    exit 1
fi

echo "$(date) Contents of hostfile:"
cat "$PBS_NODEFILE"
echo "$(date) -------------------"
cat "$PBS_NODEFILE" > $PBS_O_WORKDIR/hostfile

# Check if start_vllm.sh exists and is executable
if [ ! -x "$PBS_O_WORKDIR/start_vllm.sh" ]; then
    echo "$(date) Error: start_vllm.sh not found or not executable in $PBS_O_WORKDIR"
    exit 1
fi

# Initialize counters
ERROR_COUNT=0
SUCCESS_COUNT=0
TOTAL_HOSTS=0

# Create a temporary directory for log files
TEMP_DIR=$(mktemp -d -p $PBS_O_WORKDIR)
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
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host" "cd $PBS_O_WORKDIR && source ./env.sh && ./start_vllm.sh" 2>&1 > "$log_file"; then
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
done < "$PBS_NODEFILE"

echo "$(date) DEBUG: Finished reading hostfile"
echo "$(date) Waiting for all processes to complete..."
echo "$(date) Number of processes to wait for: ${#pids[@]}"

# When all servers have launched
# Create new host file that contains running servers
# launch test.coli.async.sh

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
