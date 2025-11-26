#!/bin/bash
#PBS -N submit_with_test
#PBS -l walltime=01:00:00
#PBS -A candle_aesp_CNDA
#PBS -q debug-scaling
#PBS -o output.log
#PBS -e error.log
#PBS -l select=8
#PBS -l filesystems=flare:home
#PBS -l place=scatter

#####################################################
# Set OFFSET if you want to resume processing files #
# from where you left off.                          #
#####################################################

SCRIPT_DIR="/lus/flare/projects/candle_aesp_CNDA/brettin/Aurora-Inferencing/vllm"
cat "$PBS_NODEFILE" > $SCRIPT_DIR/hostfile

# Redis Service Registry Configuration
REDIS_HOST=${REDIS_HOST:-localhost}
REDIS_PORT=${REDIS_PORT:-6379}
echo "$(date) TSB Redis Service Registry Configuration: REDIS_HOST=${REDIS_HOST}, REDIS_PORT=${REDIS_PORT}"

# Function to start vLLM on a host
start_vllm_on_host() {
    local host=$1
    local filename=$2
    
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host" "cd $SCRIPT_DIR && ./start_vllm.sh $REDIS_HOST $REDIS_PORT" 2>&1 ; then
        return 0
    else
        echo "$(date) Failed to launch vLLM on $host"
        return 1
    fi
}


# Create arrays containing hostnames and filenames.
mapfile -t hosts < <(cut -d'.' -f1 "$PBS_NODEFILE")
#


# stage model weights to /tmp
#mpicc -o cptotmp ${SCRIPT_DIR}/../cptotmp.c
#time mpiexec -ppn 1 ./cptotmp /flare/datasets/model-weights/hub/models--meta-llama--Llama-3.3-70B-Instruct

declare -a pids
for host in "${hosts[@]}"; do
    echo "$(date) launching vLLM on host ${host}"
    start_vllm_on_host "${host}" &
    pid=$!
    pids+=($pid)
done


# Wait for the jobs to finish.
for pid in "${pids[@]}"; do
    echo "$(date) Waiting for PID: $pid"
    if wait $pid; then
        echo "$(date) Process $pid completed successfully"
    else
        echo "$(date) Process $pid FAILED with exit code $?"
    fi
done

echo "$(date) All vLLM tasks completed"
