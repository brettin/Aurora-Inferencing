#!/bin/bash
#PBS -N gpt_oss_120b_vllm
#PBS -l walltime=3:00:00
#PBS -A candle_aesp_CNDA
#PBS -q prod
#PBS -o output.log
#PBS -e error.log
#PBS -l select=128
#PBS -l filesystems=flare:home
#PBS -l place=scatter

# Input/Output configuration
SCRIPT_DIR="/lus/flare/projects/candle_aesp_CNDA/brettin/Aurora-Inferencing/vllm-gpt-oss120b/extra"
INPUT_DIR="${SCRIPT_DIR}/../../examples/TOM.COLI/batch_1"
MODEL_PATH="/lus/flare/projects/datasets/model-weights/hub/models--openai--gpt-oss-120b"
CONDA_ENV_PATH="$SCRIPT_DIR/../vllm_env.tar.gz"    # this is the tar.gz file that contains the conda environment on the lustre filesystem

# Operation settings
OFFSET=${OFFSET:-384}                  # Starting offset for batch processing (resume capability)
STAGE_WEIGHTS=${STAGE_WEIGHTS:-1}     # 1=stage model weights to /tmp, 0=skip staging
STAGE_CONDA=${STAGE_CONDA:-1}         # 1=stage conda environment to /tmp, 0=skip staging

# vLLM server settings
SERVERS_PER_NODE=${SERVERS_PER_NODE:-6}  # Number of vLLM servers to launch per node
GPUS_PER_NODE=12  # Aurora nodes have 12 GPUs
TENSOR_PARALLEL_SIZE=$((GPUS_PER_NODE / SERVERS_PER_NODE))
BASE_PORT=6739                           # Starting port number for vLLM servers

# SSH and timing settings
SSH_TIMEOUT=10                        # SSH connection timeout in seconds
# LAUNCH_DELAY=2                        # Delay between launches in seconds

# Functions
start_vllm_on_host() {
    local host=$1
    local filename=$2
    local port=$3
    if ! ssh -o ConnectTimeout="${SSH_TIMEOUT}" -o StrictHostKeyChecking=no "$host" "bash -l -c 'cd $SCRIPT_DIR && ./start_oss120b_with_test.sh $filename $port $TENSOR_PARALLEL_SIZE'" 2>&1; then
        echo "$(date) Failed to launch vLLM on $host (port $port, tensor parallel size $TENSOR_PARALLEL_SIZE)"
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
echo "$(date) OFFSET $OFFSET"
echo "$(date) TENSOR_PARALLEL_SIZE $TENSOR_PARALLEL_SIZE"
echo "$(date) SERVERS_PER_NODE $SERVERS_PER_NODE"

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
    mpicc -o "${SCRIPT_DIR}/../../cptotmp" "${SCRIPT_DIR}/../../cptotmp.c"
    export MPIR_CVAR_CH4_OFI_ENABLE_MULTI_NIC_STRIPING=1
    export MPIR_CVAR_CH4_OFI_MAX_NICS=4
    time mpiexec -ppn 1 --cpu-bind numa "${SCRIPT_DIR}/../../cptotmp" "$MODEL_PATH" 2>&1 || \
        echo "$(date) WARNING: Model staging failed or directory not found, will use shared filesystem"
    echo "$(date) Model staging complete"
fi

# Stage Conda Environment - right now, it uses the cptotmp default location of /tmp/hf_home/hub
if [ "$STAGE_CONDA" -eq 1 ]; then
    echo "$(date) Staging conda environment to /tmp on all nodes"
    if [ ! -f "${SCRIPT_DIR}/../../cptotmp" ]; then
        mpicc -o "${SCRIPT_DIR}/../../cptotmp" "${SCRIPT_DIR}/../../cptotmp.c"
    fi
    export MPIR_CVAR_CH4_OFI_ENABLE_MULTI_NIC_STRIPING=1
    export MPIR_CVAR_CH4_OFI_MAX_NICS=4
    time mpiexec -ppn 1 --cpu-bind numa "${SCRIPT_DIR}/../../cptotmp" "$CONDA_ENV_PATH" 2>&1 || \
        echo "$(date) WARNING: Conda environment staging failed or directory not found, will use shared filesystem"
    echo "$(date) Conda environment staging complete"

    # Unpack Conda Environment in parallel on all nodes
    echo "$(date) Unpacking conda environment on all nodes in parallel"
    time mpiexec -ppn 1 --cpu-bind numa bash -c 'mkdir -p /tmp/hf_home/hub/vllm_env && tar -xzf /tmp/hf_home/hub/vllm_env.tar.gz -C /tmp/hf_home/hub/vllm_env' 2>&1 || \
        echo "$(date) WARNING: Conda environment unpacking failed"
    echo "$(date) Conda environment unpacking complete"
fi


# Process Input Files
filenames=("$INPUT_DIR"/*)
total_files=${#filenames[@]}

echo "$(date) Input directory: $INPUT_DIR"
echo "$(date) Total input files: $total_files"

# Calculate how many files to process
remaining_files=$((total_files - OFFSET))

if [ $remaining_files -le 0 ]; then
    echo "$(date) ERROR: OFFSET=$OFFSET is >= total files=$total_files"
    echo "$(date) No files to process!"
    exit 1
fi

# Calculate total server instances (nodes * servers_per_node)
total_server_instances=$((total_hosts * SERVERS_PER_NODE))

# Process min(remaining_files, total_server_instances)
if [ $total_server_instances -lt $remaining_files ]; then
    files_to_process=$total_server_instances
else
    files_to_process=$remaining_files
fi

nodes_to_use=$(( (files_to_process + SERVERS_PER_NODE - 1) / SERVERS_PER_NODE ))  # Round up

echo "$(date) Files to process: $files_to_process (from offset $OFFSET)"
echo "$(date) Nodes to use: $nodes_to_use"
echo "$(date) Servers per node: $SERVERS_PER_NODE"

# Launch vLLM on Each Host
declare -a pids
declare -a launch_hosts
declare -a launch_ports

file_idx=$OFFSET
for ((node_idx = 0; node_idx < nodes_to_use; node_idx++)); do
    host="${hosts[$node_idx]}"
    
    # Launch SERVERS_PER_NODE instances on this host
    for ((server_idx = 0; server_idx < SERVERS_PER_NODE; server_idx++)); do
        # Check if we have more files to process
        if [ $file_idx -ge $((OFFSET + files_to_process)) ]; then
            break
        fi
        
        infile="${filenames[$file_idx]}"
        port=$((BASE_PORT + server_idx))
        
        echo "$(date) Launching on $host:$port with file $(basename $infile)"
        
        # Launch vLLM on this host with specific port
        start_vllm_on_host "$host" "$infile" "$port" &
        pid=$!
        pids+=($pid)
        launch_hosts+=("$host")
        launch_ports+=($port)
        
        file_idx=$((file_idx + 1))
        
        # Small delay between launches to avoid overwhelming the system
        # sleep "$LAUNCH_DELAY"
    done
done

# Wait for Completion
echo "$(date) All launches initiated, waiting for completion..."
success_count=0
failed_count=0

for i in "${!pids[@]}"; do
    pid=${pids[$i]}
    host=${launch_hosts[$i]}
    port=${launch_ports[$i]}

    echo "$(date) Waiting for $host:$port (PID: $pid)"
    if wait $pid; then
        echo "$(date) $host:$port completed successfully"
        ((success_count++))
    else
        echo "$(date) $host:$port FAILED with exit code $?"
        ((failed_count++))
    fi
done

echo "$(date) Deployment Summary"
echo "$(date) Total server instances: $files_to_process"
echo "$(date) Nodes used:             $nodes_to_use"
echo "$(date) Servers per node:       $SERVERS_PER_NODE"
echo "$(date) Successful:             $success_count"
echo "$(date) Failed:                 $failed_count"
echo ""

exit 0
