#!/bin/bash
#PBS -N gpt_oss_120b_vllm
#PBS -l walltime=02:00:00
#PBS -A candle_aesp_CNDA
#PBS -q debug-scaling
#PBS -o output.log
#PBS -e error.log
#PBS -l select=2
#PBS -l filesystems=flare:home
#PBS -l place=scatter

SCRIPT_DIR="/lus/flare/projects/candle_aesp_CNDA/brettin/Aurora-Inferencing/for_tom"
cat "$PBS_NODEFILE" > $SCRIPT_DIR/hostfile

echo "$(date) GPT-OSS-120B vLLM Multi-Node Deployment"
echo "$(date) Script directory: $SCRIPT_DIR"
echo "$(date) PBS Job ID: $PBS_JOBID"
echo "$(date) PBS Job Name: $PBS_JOBNAME"
echo "$(date) Nodes allocated: $(wc -l < $PBS_NODEFILE)"

# Operation Mode Configuration
SKIP_TEST=${SKIP_TEST:-0}  # 0=batch mode with tests, 1=server mode without tests
OFFSET=${OFFSET:-0}        # Starting offset for batch processing (resume capability)
BATCH_SIZE=${BATCH_SIZE:-32}
STAGE_WEIGHTS=${STAGE_WEIGHTS:-1}  # 1=stage model weights to /tmp, 0=skip staging

# Function to start vLLM on a host
start_vllm_on_host() {
    local host=$1
    local filename=$2
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host" "cd $SCRIPT_DIR && ./start_oss120b_with_test.sh $filename" 2>&1 ; then
        return 0
    else
        echo "$(date) Failed to launch vLLM on $host"
        return 1
    fi
}

# Create array containing hostnames (without domain suffix)
mapfile -t hosts < <(cut -d'.' -f1 "$PBS_NODEFILE")
total_hosts=${#hosts[@]}

echo "$(date) Hosts: ${hosts[@]}"

# Stage Model Weights to /tmp (Optional)
if [ "$STAGE_WEIGHTS" -eq 1 ]; then
    echo "$(date) Staging model weights to /tmp on all nodes"
    
    mpicc -o ${SCRIPT_DIR}/../cptotmp ${SCRIPT_DIR}/../cptotmp.c
    
    # Set MPI environment for better performance
    export MPIR_CVAR_CH4_OFI_ENABLE_MULTI_NIC_STRIPING=1
    export MPIR_CVAR_CH4_OFI_MAX_NICS=4
    
    # Stage model weights
    echo "$(date) Staging GPT-OSS-120B model weights..."
    time mpiexec -ppn 1 --cpu-bind numa ${SCRIPT_DIR}/../cptotmp /lus/flare/projects/datasets/model-weights/hub/models--openai--gpt-oss-120b 2>&1 || \
        echo "$(date) WARNING: Model staging failed or directory not found, will use shared filesystem"
    echo "$(date) Model staging complete"
fi

# Determine Input Files for Batch Mode
if [ "$SKIP_TEST" -eq 0 ]; then
    # Batch mode: process input files
    INPUT_DIR="${SCRIPT_DIR}/../examples/TOM.COLI/batch_1"
    
    if [ -d "$INPUT_DIR" ]; then
        filenames=("$INPUT_DIR"/*)
        total_files=${#filenames[@]}
        
        echo "$(date) Input directory: $INPUT_DIR"
        echo "$(date) Total input files: $total_files"
        echo "$(date) Offset: $OFFSET"
        
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
    else
        echo "$(date) WARNING: Input directory not found: $INPUT_DIR"
        echo "$(date) Using default test file for all hosts"
        files_to_process=$total_hosts
    fi
else
    # Server mode: no input files needed
    files_to_process=$total_hosts
fi

echo "$(date) Starting vLLM on $files_to_process nodes"

# Launch vLLM on Each Host
declare -a pids
declare -a launch_hosts

for ((i = 0; i < files_to_process; i++)); do
    host="${hosts[$i]}"
    
    # Determine input file for this host
    if [ "$SKIP_TEST" -eq 0 ] && [ -d "$INPUT_DIR" ]; then
        file_index=$((OFFSET + i))
        infile="${filenames[$file_index]}"
    else
        infile=""
    fi
    
    # Launch vLLM on this host
    start_vllm_on_host "$host" "$infile" &
    pid=$!
    pids+=($pid)
    launch_hosts+=("$host")
    
    # Small delay between launches to avoid overwhelming the system
    sleep 2
done

echo "$(date) All launches initiated, waiting for completion..."

# Wait for Completion and Collect Status
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
        exit_code=$?
        echo "$(date) $host FAILED with exit code $exit_code"
        ((failed_count++))
    fi
done

echo "$(date) Deployment Summary"
echo "$(date) Total nodes:      $files_to_process"
echo "$(date) Successful:       $success_count"
echo "$(date) Failed:           $failed_count"
echo ""

# ============================================================================
# Create Summary File
# ============================================================================

SUMMARY_FILE="${SCRIPT_DIR}/deployment_summary_$(date +%Y%m%d_%H%M%S).txt"
{
    echo "GPT-OSS-120B vLLM Multi-Node Deployment"
    echo "========================================"
    echo "Timestamp: $(date)"
    echo "PBS Job ID: $PBS_JOBID"
    echo "PBS Job Name: $PBS_JOBNAME"
    echo ""
    echo "Configuration:"
    echo "  Mode: $([ "$SKIP_TEST" -eq 1 ] && echo "Server Mode" || echo "Batch Mode")"
    echo "  Batch Size: $BATCH_SIZE"
    echo "  Offset: $OFFSET"
    echo "  Redis: ${REDIS_HOST}:${REDIS_PORT}"
    echo ""
    echo "Results:"
    echo "  Total nodes: $files_to_process"
    echo "  Successful: $success_count"
    echo "  Failed: $failed_count"
    echo ""
    echo "Hosts:"
    for i in "${!launch_hosts[@]}"; do
        host=${launch_hosts[$i]}
        status="UNKNOWN"
        # Check if this host succeeded or failed
        if [ $i -lt $success_count ]; then
            status="SUCCESS"
        else
            status="FAILED"
        fi
        echo "  - $host (port 6739)"
    done
    echo ""
    echo "Server Access:"
    for host in "${launch_hosts[@]}"; do
        echo "  http://${host}:6739/health"
        echo "  http://${host}:6739/v1/chat/completions"
    done
    echo ""
    echo "Results Archives:"
    echo "  Location: ${SCRIPT_DIR}/"
    echo "  Pattern: *_gpt_oss_120b_results_*.tar.gz"
} > "$SUMMARY_FILE"

echo "$(date) Summary written to: $SUMMARY_FILE"
echo ""

# ============================================================================
# Query Redis for Active Services
# ============================================================================

echo "$(date) Querying Redis for active vLLM services..."
python3 "${SCRIPT_DIR}/../redis/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" list --service-type vllm-inference 2>/dev/null || \
    echo "$(date) Could not query Redis service registry"

echo ""
echo "$(date) ============================================================"

if [ $failed_count -eq 0 ]; then
    echo "$(date) ✓ All deployments successful!"
    echo "$(date) ============================================================"
    exit 0
else
    echo "$(date) ⚠ Some deployments failed ($failed_count/$files_to_process)"
    echo "$(date) ============================================================"
    exit 1
fi

