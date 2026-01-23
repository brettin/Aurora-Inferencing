#!/bin/bash
#PBS -N gpt_oss_120b_vllm
#PBS -l walltime=02:00:00
#PBS -A datascience
#PBS -q prod
#PBS -o 1024.output.log
#PBS -e 1024.error.log
#PBS -l select=1024
#PBS -l filesystems=flare:home
#PBS -l place=scatter
#PBS -j oe
#

NNODES=$(wc -l < $PBS_NODEFILE)
RANKS_PER_NODE=12
NRANKS=$(( NNODES * RANKS_PER_NODE ))

echo "N_RANKS = ${NRANKS}"

# Input/Output configuration
SCRIPT_DIR="/lus/flare/projects/ModCon/brettin/Aurora-Inferencing/vllm-gpt-oss120b"
INPUT_DIR="${SCRIPT_DIR}/../examples/TOM.COLI/batch_1"
MODEL_PATH="/lus/flare/projects/datasets/model-weights/hub/models--openai--gpt-oss-120b"
MODEL_WEIGHTS="${MODEL_PATH##*/}"

echo "MODEL WEIGHTS = ${MODEL_WEIGHTS}"

CONDA_FILE="vllm_oss_conda_pack_01082026.tar.gz"
CONDA_ENV_PATH="$SCRIPT_DIR/vllm_oss_conda_pack_01082026.tar.gz"

# Extract model name from MODEL_PATH (converts models--org--name to org/name)
MODEL_NAME=$(basename "$MODEL_PATH" | sed 's/^models--//' | sed 's/--/\//')

# Operation settings
OFFSET=${OFFSET:-0 }                  # Starting offset for batch processing (resume capability)
STAGE_WEIGHTS=${STAGE_WEIGHTS:-1}     # 1=stage model weights to /tmp, 0=skip staging
STAGE_CONDA=${STAGE_CONDA:-1}         # 1=stage conda environment to /tmp, 0=skip staging
USE_FRAMEWORKS=${USE_FRAMEWORKS:-0}   # 1=use frameworks module, 0=use conda environment

# SSH and timing settings
SSH_TIMEOUT=10                        # SSH connection timeout in seconds

# Functions
start_vllm_on_host() {
    local host=$1
    local filename=$2
    local model=$3
    if ! ssh -o ConnectTimeout="${SSH_TIMEOUT}" -o StrictHostKeyChecking=no "$host" "bash -l -c 'cd $SCRIPT_DIR && USE_FRAMEWORKS=${USE_FRAMEWORKS} ./start_oss120b_with_test.sh $filename $model'" 2>&1; then
        echo "$(date) Failed to launch vLLM on $host (model: $model)"
        return 1
    fi
}

# Main Execution

cat "$PBS_NODEFILE" > "$SCRIPT_DIR/hostfile"

echo "$(date) vLLM Multi-Node Deployment"
echo "$(date) Script directory: $SCRIPT_DIR"
echo "$(date) PBS Job ID: $PBS_JOBID"
echo "$(date) PBS Job Name: $PBS_JOBNAME"
echo "$(date) Nodes allocated: $(wc -l < $PBS_NODEFILE)"
echo "$(date) Model: $MODEL_NAME"
echo "$(date) Model path: $MODEL_PATH"
echo "$(date) OFFSET $OFFSET"
echo "$(date) STAGE_WEIGHTS: $STAGE_WEIGHTS"
echo "$(date) STAGE_CONDA: $STAGE_CONDA"
echo "$(date) USE_FRAMEWORKS: $USE_FRAMEWORKS"

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
    time mpiexec -ppn 1 --cpu-bind numa "${SCRIPT_DIR}/../cptotmp" "$MODEL_PATH" /tmp/hf_home/hub 2>&1 || \
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

    # Unpack Conda Environment in parallel on all nodes
    echo "$(date) Unpacking conda environment on all nodes in parallel"
    time mpiexec -ppn 1 --cpu-bind numa bash -c 'mkdir -p /tmp/hf_home/hub/vllm_env && tar -xzf /tmp/vllm_oss_conda_pack_01082026.tar.gz -C /tmp/hf_home/hub/vllm_env' 2>&1 || \
        echo "$(date) WARNING: Conda environment unpacking failed"
    echo "$(date) Conda environment unpacking complete"
fi


#exit

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
    start_vllm_on_host "$host" "$infile" "$MODEL_NAME" &
    pid=$!
    pids+=($pid)
    launch_hosts+=("$host")

    # Small delay between launches to avoid overwhelming the system
    # sleep "$LAUNCH_DELAY"
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
