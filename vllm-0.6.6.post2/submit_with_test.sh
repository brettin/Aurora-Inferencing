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

SCRIPT_DIR="/lus/flare/projects/candle_aesp_CNDA/brettin/Aurora-Inferencing/vllm-0.6.6.post2"
cat "$PBS_NODEFILE" > $SCRIPT_DIR/hostfile


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


# Create arrays containing hostnames and filenames.
mapfile -t hosts < <(cut -d'.' -f1 "$PBS_NODEFILE")
filenames=(${SCRIPT_DIR}/../examples/TOM.COLI/batch_1/genes/*)


# Loop over the smaller of hostnames or filenames with an OFFSET option for restarting.
OFFSET=0 # number of files already processed
total_files=$(( ${#filenames[@]} - OFFSET ))
total_hosts=${#hosts[@]}

if (( ${total_hosts} < ${total_files} )); then
    min=${total_hosts}
else
    min=${total_files}
fi

# stage model weights to /tmp
mpicc -o cptotmp ${SCRIPT_DIR}/../cptotmp.c
time mpiexec -ppn 1 ./cptotmp /flare/datasets/model-weights/hub/models--meta-llama--Llama-3.3-70B-Instruct

declare -a pids
for ((i = OFFSET; i < min + OFFSET; i++)); do
    index=$((i - OFFSET)) # for indexing the hosts
    file="${filenames[i]}"
    host="${hosts[index]}"

    echo "$(date) processing genes in ${file} on host ${host}"
    start_vllm_on_host ${host} ${file} &
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
