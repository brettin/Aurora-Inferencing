#!/bin/bash
#PBS -N gpt_oss_120b_vllm
#PBS -l walltime=01:00:00
#PBS -A candle_aesp_CNDA
#PBS -q prod
#PBS -o output.log
#PBS -e error.log
#PBS -l select=64
#PBS -l filesystems=flare:home
#PBS -l place=scatter

# Input/Output configuration
SCRIPT_DIR="/lus/flare/projects/candle_aesp_CNDA/brettin/Aurora-Inferencing/vllm-gpt-oss120b"
INPUT_DIR="${SCRIPT_DIR}/../examples/TOM.COLI/batch_1"
MODEL_PATH="/lus/flare/projects/datasets/model-weights/hub/models--openai--gpt-oss-120b"
CONDA_ENV_PATH="$SCRIPT_DIR/vllm_env.tar.gz"    # this is the tar.gz file that contains the conda environment on the lustre filesystem

# Operation settings
OFFSET=${OFFSET:-0}                    # Starting offset for batch processing (resume capability)
STAGE_WEIGHTS=${STAGE_WEIGHTS:-1}      # 1=stage model weights to /tmp, 0=skip staging
STAGE_CONDA=${STAGE_CONDA:-1}         # 1=stage conda environment to /tmp, 0=skip staging

# SSH and timing settings
SSH_TIMEOUT=10                          # SSH connection timeout in seconds
LAUNCH_DELAY=2                          # Delay between launches in seconds

# Functions
start_vllm_on_host() {
    local host=$1
    local filename=$2
    if ! ssh -o ConnectTimeout="${SSH_TIMEOUT}" -o StrictHostKeyChecking=no "$host" "bash -l -c 'cd $SCRIPT_DIR && ./start_oss120b_with_test.sh $filename'" 2>&1; then
        echo "$(date) Failed to launch vLLM on $host"
        return 1
    fi
}

# Main Execution

cat "$PBS_NODEFILE" > "$SCRIPT_DIR/hostfile"

echo "$(date) GPT-OSS-120B vLLM Multi-Node Deployment"
echo "$(date) Script directory: $SCRIPT_DIR"
echo "$(date) PBS Job ID: $PBS_JOBID"
echo "$(date) PBS Job Name: $PBS_JOBNAME"
echo "$(date) Nodes allocated: $(wc -l < $PBS_NODEFILE)"

# Validate input directory
if [ ! -d "$INPUT_DIR" ]; then
    echo "$(date) ERROR: Input directory not found: $INPUT_DIR"
    exit 1
fi

# Create array containing hostnames (without domain suffix)
mapfile -t hosts < <(cut -d'.' -f1 "$PBS_NODEFILE")
total_hosts=${#hosts[@]}

echo "$(date) Hosts: ${hosts[@]}"

# Stage Model Weights
if [ "$STAGE_WEIGHTS" -eq 1 ]; then
    echo "$(date) Staging model weights to /tmp on all nodes"
    mpicc -o "${SCRIPT_DIR}/../cptotmp" "${SCRIPT_DIR}/../cptotmp.c"
    export MPIR_CVAR_CH4_OFI_ENABLE_MULTI_NIC_STRIPING=1
    export MPIR_CVAR_CH4_OFI_MAX_NICS=4
    time mpiexec -ppn 1 --cpu-bind numa "${SCRIPT_DIR}/../cptotmp" "$MODEL_PATH" 2>&1 || \
        echo "$(date) WARNING: Model staging failed or directory not found, will use shared filesystem"
    echo "$(date) Model staging complete"
fi

# Stage Conda Environment - right now, it uses the cptotmp default location of /tmp/hf_home/hub
if [ "$STAGE_CONDA" -eq 1 ]; then
    echo "$(date) Staging conda environment to /tmp on all nodes"
    if [ ! -f "${SCRIPT_DIR}/../cptotmp" ]; then
        mpicc -o "${SCRIPT_DIR}/../cptotmp" "${SCRIPT_DIR}/../cptotmp.c"
    fi
    export MPIR_CVAR_CH4_OFI_ENABLE_MULTI_NIC_STRIPING=1
    export MPIR_CVAR_CH4_OFI_MAX_NICS=4
    time mpiexec -ppn 1 --cpu-bind numa "${SCRIPT_DIR}/../cptotmp" "$CONDA_ENV_PATH" 2>&1 || \
        echo "$(date) WARNING: Conda environment staging failed or directory not found, will use shared filesystem"
    echo "$(date) Conda environment staging complete"
fi

# Process Input Files
filenames=("$INPUT_DIR"/*)
total_files=${#filenames[@]}

echo "$(date) Input directory: $INPUT_DIR"
echo "$(date) Total input files: $total_files"

# Calculate how many files to process
remaining_files=$((total_files - OFFSET))

if [ $remaining_files -le 0 ]; then
    echo "$(date) ERROR: OFFSET=$OFFSET is >= total files ($total_files)"
    echo "$(date) No files to process!"
    exit 1
fi

# Process min(remaining_files, total_hosts)
if [ $total_hosts -lt $remaining_files ]; then
    files_to_process=$total_hosts
else
    files_to_process=$remaining_files
fi
echo "$(date) Files to process: $files_to_process (from offset $OFFSET)"

# Launch vLLM on Each Host
declare -a pids
declare -a launch_hosts

for ((i = 0; i < files_to_process; i++)); do
    host="${hosts[$i]}"

    # Calculate the input file for this host
    file_index=$((OFFSET + i))
    infile="${filenames[$file_index]}"

    # Launch vLLM on this host
    start_vllm_on_host "$host" "$infile" &
    pid=$!
    pids+=($pid)
    launch_hosts+=("$host")

    # Small delay between launches to avoid overwhelming the system
    sleep "$LAUNCH_DELAY"
done

# Wait for Completion
echo "$(date) All launches initiated, waiting for completion..."
success_count=0
failed_count=0

for i in "${!pids[@]}"; do
    pid=${pids[$i]}
    host=${launch_hosts[$i]}

    echo "$(date) Waiting for $host (PID: $pid)"
    if wait $pid; then
        echo "$(date) $host completed successfully"
        ((success_count++))
    else
        echo "$(date) $host FAILED with exit code $?"
        ((failed_count++))
    fi
done

echo "$(date) Deployment Summary"
echo "$(date) Total nodes:      $files_to_process"
echo "$(date) Successful:       $success_count"
echo "$(date) Failed:           $failed_count"
echo ""

exit 0
