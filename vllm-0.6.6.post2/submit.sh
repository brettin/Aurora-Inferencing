#!/bin/bash
#PBS -N submit_all_p
#PBS -l walltime=00:10:00
#PBS -A candle_aesp_CNDA
#PBS -q debug
#PBS -o output.log
#PBS -e error.log
#PBS -l select=2
#PBS -l filesystems=flare:home:daos_user
#PBS -l place=scatter

NUM_NODES=$(cat $PBS_NODEFILE | wc -l)
set -e
set -x

SCRIPT_DIR="/lus/flare/projects/candle_aesp_CNDA/brettin/Aurora-Inferencing/vllm-0.6.6.post2"
cat "$PBS_NODEFILE" > $SCRIPT_DIR/hostfile

# Check if hostfile exists and has content
if [ ! -f "$PBS_NODEFILE" ]; then
    echo "$(date) Error: hostfile not found at $PBS_NODEFILE"
    exit 1
fi
# Check if start_vllm.sh exists and is executable
if [ ! -x "$SCRIPT_DIR/start_vllm.sh" ]; then
    echo "$(date) Error: start_vllm.sh not found or not executable in $SCRIPT_DIR"
    exit 1
fi

# DAOS
# module use /soft/modulefiles
# module load daos/base
# export DAOS_POOL=candle_aesp_CNDA
# export DAOS_CONT=brettin_posix
# echo "$(date) TSB available containers $(daos cont list ${DAOS_POOL})"
# echo "$(date) TSB mounting ${DAOS_POOL}:${DAOS_CONT} on ${NUM_NODES} nodes"
# launch-dfuse.sh ${DAOS_POOL}:${DAOS_CONT}
# mpiexec -n $NUM_NODES -ppn 1 ls -l /tmp/$DAOS_POOL/$DAOS_CONT
# END DAOS

# COPPER
module load copper
launch_copper.sh
# END COOPER

# Initialize counters
ERROR_COUNT=0
SUCCESS_COUNT=0
TOTAL_HOSTS=0

# Create a temporary directory for log files
TEMP_DIR=$(mktemp -d -p $SCRIPT_DIR)

# Function to start vLLM on a host
start_vllm_on_host() {
    local host=$1
    local log_file="$TEMP_DIR/${host}.log"
    
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host" "cd $SCRIPT_DIR && ./start_vllm.sh" 2>&1 > "$log_file"; then
        echo "$(date) Successfully started vLLM on $host"
        return 0
    else
        echo "$(date) Failed to start vLLM on $host"
        return 1
    fi
}

# Initialize pids array
declare -a pids

# Launch all hosts in parallel
while IFS= read -r host || [ -n "$host" ]; do
    if [ -z "$host" ]; then
        continue
    fi
    TOTAL_HOSTS=$((TOTAL_HOSTS + 1))
    
    echo "$(date) DEBUG: Calling start_vllm_on_host: HOST: $host"
    start_vllm_on_host "$host" &
    pid=$!
    pids+=($pid)
done < "$PBS_NODEFILE"

echo "$(date) DEBUG: Finished reading hostfile"
echo "$(date) Waiting for all processes to complete..."
echo "$(date) Number of processes to wait for: ${#pids[@]}"

# When all servers have launched create new host file that
# contains running servers

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
