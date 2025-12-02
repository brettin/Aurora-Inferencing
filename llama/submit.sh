#!/bin/bash
#PBS -N llama_multi_node
#PBS -l walltime=01:00:00
#PBS -A candle_aesp_CNDA
#PBS -q debug-scaling
#PBS -o output.log
#PBS -e error.log
#PBS -l select=4
#PBS -l filesystems=flare:home
#PBS -l place=scatter

#####################################################
# Multi-node llama-server deployment script
# Starts llama-server on each allocated compute node
# Each node gets its own port (8080, 8081, 8082, ...)
#####################################################

SCRIPT_DIR="/lus/flare/projects/candle_aesp_CNDA/brettin/Aurora-Inferencing/llama"
cat "$PBS_NODEFILE" > $SCRIPT_DIR/hostfile


# Redis Service Registry Configuration
source $SCRIPT_DIR/../redis/set_redis_host.sh
REDIS_HOST=${REDIS_HOST:-localhost}
REDIS_PORT=${REDIS_PORT:-6379}
echo "$(date) TSB Redis Service Registry Configuration: REDIS_HOST=${REDIS_HOST}, REDIS_PORT=${REDIS_PORT}"


# Function to start llama-server on a host
start_llama_on_host() {
    local host=$1
    local device=$2
    local batch_size=${3:-32}
    
    echo "$(date) Launching llama-server with test on $host (device $device, batch_size $batch_size)"
    
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host" \
        "cd $SCRIPT_DIR && ./start_llama_with_test.sh $device $batch_size $REDIS_HOST $REDIS_PORT 2>&1"; then
        echo "$(date) Successfully launched llama-server with test on $host"
        return 0
    else
        echo "$(date) Failed to launch llama-server with test on $host"
        return 1
    fi
}

# Create array containing hostnames (without domain suffix)
mapfile -t hosts < <(cut -d'.' -f1 "$PBS_NODEFILE")
total_hosts=${#hosts[@]}


# Stage model weights to /tmp on each node for faster loading
mpicc -o cptotmp ${SCRIPT_DIR}/../cptotmp.c
time mpiexec -ppn 1 ./cptotmp /lus/flare/projects/candle_aesp_CNDA/brettin/Aurora-Inferencing/llama/gpt-oss-120b-intel-max-gpu/models


echo "$(date) ======================================================"
echo "$(date) Starting llama-server on $total_hosts nodes"
echo "$(date) ======================================================"
echo "$(date) Hosts: ${hosts[@]}"
echo ""

# Start llama-server on each host with unique device
declare -a pids
device_index=0
batch_size=32  # Can be adjusted as needed

for host in "${hosts[@]}"; do
    device=$device_index
    echo "$(date) Starting llama-server on host ${host} (device ${device})"
    start_llama_on_host "${host}" "${device}" "${batch_size}" &
    pid=$!
    pids+=($pid)
    device_index=$((device_index + 1))
    
    # Small delay between launches to avoid overwhelming the system
    sleep 2
done

echo ""
echo "$(date) All launches initiated, waiting for completion..."
echo ""

# Wait for all jobs to finish and collect status
success_count=0
failed_count=0

for i in "${!pids[@]}"; do
    pid=${pids[$i]}
    host=${hosts[$i]}
    device=$i
    port=$((8888 + device))
    
    echo "$(date) Waiting for $host (device $device, port $port) (PID: $pid)"
    if wait $pid; then
        echo "$(date) ✓ $host (device $device, port $port) completed successfully"
        ((success_count++))
    else
        exit_code=$?
        echo "$(date) ✗ $host (device $device, port $port) FAILED with exit code $exit_code"
        ((failed_count++))
    fi
done

echo ""
echo "$(date) ======================================================"
echo "$(date) Deployment Summary"
echo "$(date) ======================================================"
echo "$(date) Total nodes:      $total_hosts"
echo "$(date) Successful:       $success_count"
echo "$(date) Failed:           $failed_count"
echo ""

# Print access information for successful deployments
echo "$(date) Server Access URLs:"
for i in "${!hosts[@]}"; do
    host=${hosts[$i]}
    device=$i
    port=$((8888 + device))
    echo "  - http://${host}:${port}/health"
    echo "    http://${host}:${port}/v1/chat/completions"
done
echo ""

# Create summary file
SUMMARY_FILE="${SCRIPT_DIR}/deployment_summary_$(date +%Y%m%d_%H%M%S).txt"
{
    echo "Llama-server Multi-Node Deployment"
    echo "Timestamp: $(date)"
    echo "Total nodes: $total_hosts"
    echo "Successful: $success_count"
    echo "Failed: $failed_count"
    echo ""
    echo "Server URLs:"
    for i in "${!hosts[@]}"; do
        host=${hosts[$i]}
        device=$i
        port=$((8888 + device))
        echo "  $host:$port (device $device)"
    done
} > "$SUMMARY_FILE"

echo "$(date) Summary written to: $SUMMARY_FILE"
echo "$(date) Logs available in: ${SCRIPT_DIR}/logs/"
echo ""

if [ $failed_count -eq 0 ]; then
    echo "$(date) ✓ All deployments successful!"
    exit 0
else
    echo "$(date) ⚠ Some deployments failed"
    exit 1
fi

