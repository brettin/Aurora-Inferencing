#!/bin/bash
#PBS -N submit_with_test
#PBS -l walltime=02:00:00
#PBS -A candle_aesp_CNDA
#PBS -q prod
#PBS -o output.log
#PBS -e error.log
#PBS -l select=2048
#PBS -l filesystems=flare:home
#PBS -l place=scatter

#####################################################
# Set OFFSET if you want to resume processing files #
# from where you left off.                          #
#####################################################

SCRIPT_DIR="/lus/flare/projects/candle_aesp_CNDA/brettin/Aurora-Inferencing/vllm"
cat "$PBS_NODEFILE" > $SCRIPT_DIR/hostfile

# Redis Service Registry Configuration
source $SCRIPT_DIR/../redis/set_redis_host.sh
REDIS_HOST=${REDIS_HOST:-localhost}
REDIS_PORT=${REDIS_PORT:-6379}
echo "$(date) Redis Service Registry Configuration: REDIS_HOST=${REDIS_HOST}, REDIS_PORT=${REDIS_PORT}"

# Function to start vLLM on a host
start_vllm_on_host() {
    local host=$1
    local filename=$2
    local redis_host=$3
    local redis_port=$4
    
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host" "cd $SCRIPT_DIR && ./start_vllm_with_test.sh $redis_host $redis_port $filename" 2>&1 ; then
        return 0
    else
        echo "$(date) Failed to launch vLLM on $host"
        return 1
    fi
}


# Create arrays containing hostnames and filenames.
mapfile -t hosts < <(cut -d'.' -f1 "$PBS_NODEFILE")
filenames=(${SCRIPT_DIR}/../examples/TOM.COLI/batch_1/*)


# Loop over the smaller of hostnames or filenames with an OFFSET option for restarting.
OFFSET=3072 # number of files already processed
total_files=$(( ${#filenames[@]} - OFFSET ))
total_hosts=${#hosts[@]}

if (( ${total_hosts} < ${total_files} )); then
    min=${total_hosts}
else
    min=${total_files}
fi

# stage model weights to /tmp
mpicc -o cptotmp ${SCRIPT_DIR}/../cptotmp.c
export MPIR_CVAR_CH4_OFI_ENABLE_MULTI_NIC_STRIPING=1
export MPIR_CVAR_CH4_OFI_MAX_NICS=4
time mpiexec -ppn 1 --cpu-bind numa ./cptotmp /flare/datasets/model-weights/hub/models--meta-llama--Llama-3.3-70B-Instruct
time mpiexec -ppn 1 --cpu-bind numa ./cptotmp /home/brettin/candle_aesp_CNDA/brettin/Aurora-Inferencing/redis/wheelhouse

declare -a pids
for ((i = OFFSET; i < min + OFFSET; i++)); do
    index=$((i - OFFSET)) # for indexing the hosts
    file="${filenames[i]}"
    host="${hosts[index]}"

    echo "$(date) processing genes in ${file} on host ${host}"
    start_vllm_on_host ${host} ${file} ${REDIS_HOST} ${REDIS_PORT} &
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
