#!/bin/bash
#PBS -N submit_with_test
#PBS -l walltime=01:00:00
#PBS -A candle_aesp_CNDA
#PBS -q debug
#PBS -o output.log
#PBS -e error.log
#PBS -l select=10
#PBS -l filesystems=flare:home:daos_user
#PBS -l place=scatter

SCRIPT_DIR="/lus/flare/projects/candle_aesp_CNDA/brettin/Aurora-Inferencing/vllm-0.6.6.post2"
cat "$PBS_NODEFILE" > $SCRIPT_DIR/hostfile

# module load copper
# launch_copper.sh

# Function to start vLLM on a host
start_vllm_on_host() {
    local host=$1
    local filename=$2
    
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host" "cd $SCRIPT_DIR && ./start_vllm_with_test.sh $filename" 2>&1 ; then
        echo "$(date) Successfully launch vLLM on $host"
        return 0
    else
        echo "$(date) Failed to launch vLLM on $host"
        return 1
    fi
}

# Create an array containing hostnames.
mapfile -t hosts < <(cut -d'.' -f1 "$PBS_NODEFILE")

# Create an array containing gene filenames.
filenames=(${SCRIPT_DIR}/../examples/TOM.COLI/batch_1/genes/*)

# TODO:
OFFSET=0 # number of files processed

if (( ${#hosts[@]} < ${#filenames[@]} )); then
    min=${#hosts[@]}
    echo "min = ${min}"
else
    min=${#filenames[@]}
    echo "min = ${min}"
fi

declare -a pids
for ((i = 0; i < ${min}; i++)); do
    echo "starting vllm on host ${hosts[i]}"
    echo "processing genes in ${filenames[i]}"
    start_vllm_on_host ${hosts[i]} ${filenames[i]} &
    pid=$!
    pids+=($pid)
done

for pid in "${pids[@]}"; do
    echo "$(date) Waiting for PID: $pid"
    if wait $pid; then
        echo "$(date) Process $pid completed successfully"
    fi
done
