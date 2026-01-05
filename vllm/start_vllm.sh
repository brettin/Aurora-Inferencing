#!/bin/bash -l

REDIS_HOST=${1:-localhost}
REDIS_PORT=${2:-6379}
echo "$(date) ${HOSTNAME} TSB Redis Service Registry Configuration: REDIS_HOST=${REDIS_HOST}, REDIS_PORT=${REDIS_PORT}"

SCRIPT_START_TIME=$(date +%s)
TOTAL_WALLTIME=${WALLTIME_SECONDS:-1200}  # Can be overridden by WALLTIME_SECONDS environment variable
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
HOSTNAME=$(hostname)
echo "$(date) ${HOSTNAME} TSB script directory is: $SCRIPT_DIR"
echo "$(date) ${HOSTNAME} TSB hostname: $HOSTNAME"
echo "$(date) ${HOSTNAME} TSB Total walltime: ${TOTAL_WALLTIME}s ($(($TOTAL_WALLTIME/60)) minutes)"

# This is needed incase vllm tries to download from huggingface.
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128

module load frameworks
export tiles=12
export ZE_FLAT_DEVICE_HIERARCHY=FLAT
export NUMEXPR_MAX_THREADS=208
export CCL_PROCESS_LAUNCHER=torchrun # Per Ken R.
export HF_HOME="/tmp/hf_home"
export TMPDIR=/tmp
export RAY_TMPDIR=/tmp
export VLLM_HOST_IP=$(getent hosts $(hostname).hsn.cm.aurora.alcf.anl.gov | awk '{ print $1 }' | tr ' ' '\n' | sort | head -n 1)
export RAY_ADDRESS=$VLLM_HOST_IP:6379
export VLLM_HOST_PORT=8000
export VLLM_MODEL="meta-llama/Llama-3.3-70B-Instruct"
export HF_HUB_OFFLINE=1
unset ONEAPI_DEVICE_SELECTOR
export NUMEXPR_MAX_THREADS=208
unset OMP_NUM_THREADS
export CCL_PROCESS_LAUNCHER=torchrun

# Done setting up environment and variables.

# Redis Service Registry: Cleanup function
# cleanup_service() {
#     local exit_code=$?
#     echo "$(date) ${HOSTNAME} TSB Redis: Shutting down..."
    
    # Update status to stopping if service was registered
#     if [ -n "$SERVICE_ID" ]; then
#         python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
#             update-health "$SERVICE_ID" --status stopping 2>/dev/null || true
#     fi
    
    # Kill heartbeat loop if running
#    if [ -n "$HEARTBEAT_PID" ] && kill -0 "$HEARTBEAT_PID" 2>/dev/null; then
#        echo "$(date) ${HOSTNAME} TSB Redis: Stopping heartbeat monitor..."
#        kill "$HEARTBEAT_PID" 2>/dev/null || true
#    fi
    
    # Kill vLLM server if still running
#    if [ -n "$vllm_pid" ] && kill -0 "$vllm_pid" 2>/dev/null; then
#        echo "$(date) ${HOSTNAME} TSB Stopping vLLM server..."
#        kill -SIGINT "$vllm_pid"
#        wait "$vllm_pid" 2>/dev/null || true
#    fi
    
    # Deregister service
#    if [ -n "$SERVICE_ID" ]; then
#        echo "$(date) ${HOSTNAME} TSB Redis: Deregistering service: $SERVICE_ID"
#        python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
#            deregister "$SERVICE_ID" 2>/dev/null || echo "$(date) ${HOSTNAME} TSB Redis: Failed to deregister service"
#    fi
    
#    echo "$(date) ${HOSTNAME} TSB Redis: Cleanup complete"
#    exit $exit_code
#}

# # Set up signal handlers for graceful shutdown
# trap cleanup_service EXIT INT TERM

# Setup local output directory on /dev/shm for fast I/O
OUTPUT_DIR="/dev/shm/vllm_output_${HOSTNAME}_$$"
mkdir -p "$OUTPUT_DIR"
echo "$(date) ${HOSTNAME} TSB Local output directory: $OUTPUT_DIR"

echo "$(date) ${HOSTNAME} TSB starting ray on $VLLM_HOST_IP"
ray --logging-level info  start --head --verbose --node-ip-address=$VLLM_HOST_IP --port=6379 --num-cpus=64 --num-gpus=$tiles
echo "$(date) ${HOSTNAME} TSB done starting ray on $VLLM_HOST_IP"

echo "$(date) ${HOSTNAME} TSB starting vllm with ${VLLM_MODEL} on host ${HOSTNAME}"
echo "$(date) ${HOSTNAME} TSB writing log to $OUTPUT_DIR/${HOSTNAME}.vllm.log"

# Redis Service Registry Configuration
REDIS_DIR="${SCRIPT_DIR}/../redis"
pip install --target "/tmp/redis_env" -r "${REDIS_DIR}/requirements.txt"
export PYTHONPATH="$PYTHONPATH:/tmp/redis_env"

# Redis Service Registry: Register service before starting vLLM
SERVICE_ID="vllm-${HOSTNAME}-${VLLM_HOST_PORT}-$$"
echo "$(date) ${HOSTNAME} TSB Redis: Registering service: $SERVICE_ID"

# Extract model name from path for cleaner metadata
MODEL_NAME=$(basename "$VLLM_MODEL")

# Build metadata JSON
METADATA=$(cat <<EOF
{
  "model": "${VLLM_MODEL}",
  "model_name": "${MODEL_NAME}",
  "tensor_parallel_size": 8,
  "dtype": "bfloat16",
  "max_model_len": 32000,
  "ray_address": "${RAY_ADDRESS}",
  "pid": $$,
  "script_start_time": ${SCRIPT_START_TIME},
  "output_dir": "${OUTPUT_DIR}"
}
EOF
)
echo "$(date) ${HOSTNAME} TSB Metadata: $METADATA"

# Register service with "starting" status
if python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
    register "$SERVICE_ID" \
    --host "$VLLM_HOST_IP" \
    --port "$VLLM_HOST_PORT" \
    --service-type "vllm-inference" \
    --status starting \
    --metadata "$METADATA"; then
    echo "$(date) ${HOSTNAME} TSB Redis: Service registered successfully"
else
    echo "$(date) ${HOSTNAME} TSB Redis: WARNING - Failed to register service (continuing anyway)"
fi

# Start vLLM server in background, redirecting output to log file
PYTHONUNBUFFERED=1 vllm serve ${VLLM_MODEL} --port ${VLLM_HOST_PORT} --tensor-parallel-size 8 --dtype bfloat16 --trust-remote-code --max-model-len 32000 > $OUTPUT_DIR/${HOSTNAME}.vllm.log 2>&1 &
vllm_pid=$!
echo "$(date) ${HOSTNAME} TSB vLLM PID: $vllm_pid"

unset HTTP_PROXY
unset HTTPS_PROXY
unset http_proxy
unset https_proxy

echo "$(date) ${HOSTNAME} TSB Waiting for vLLM..."
until curl -sf "http://${HOSTNAME}:${VLLM_HOST_PORT}/health" ; do
  sleep 2
done
echo "$(date) ${HOSTNAME} TSB vLLM ready!"

# Redis Service Registry: Update status to healthy
echo "$(date) ${HOSTNAME} TSB Redis: Updating service status to healthy"
python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
    update-health "$SERVICE_ID" --status healthy || \
    echo "$(date) ${HOSTNAME} TSB Redis: WARNING - Failed to update health status"

# Redis Service Registry: Start heartbeat and health monitoring loop
echo "$(date) ${HOSTNAME} TSB Redis: Starting heartbeat monitor (interval: 10s)"
(
    HEARTBEAT_INTERVAL=10
    HEALTH_CHECK_FAILURES=0
    MAX_FAILURES=3
    
    while true; do
        # Check if vLLM process is still running
        if ! kill -0 "$vllm_pid" 2>/dev/null; then
            echo "$(date) ${HOSTNAME} TSB Redis: vLLM process no longer running, stopping heartbeat"
            break
        fi
        
        # Check vLLM health endpoint
        if curl -sf "http://${HOSTNAME}:${VLLM_HOST_PORT}/health" > /dev/null 2>&1; then
            # Health check passed - send heartbeat to update last_seen timestamp
            python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
                heartbeat "$SERVICE_ID" --quiet 2>/dev/null || true
            
            # If we recovered from failures, update status back to healthy
            if [ $HEALTH_CHECK_FAILURES -gt 0 ]; then
                echo "$(date) ${HOSTNAME} TSB Redis: Service recovered, updating to healthy"
                python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
                    update-health "$SERVICE_ID" --status healthy 2>/dev/null || true
                HEALTH_CHECK_FAILURES=0
            fi
        else
            # Health check failed
            HEALTH_CHECK_FAILURES=$((HEALTH_CHECK_FAILURES + 1))
            echo "$(date) ${HOSTNAME} TSB Redis: Health check failed (${HEALTH_CHECK_FAILURES}/${MAX_FAILURES})"
            
            # Update status to unhealthy after MAX_FAILURES
            if [ $HEALTH_CHECK_FAILURES -ge $MAX_FAILURES ]; then
                echo "$(date) ${HOSTNAME} TSB Redis: Updating service status to unhealthy"
                python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
                    update-health "$SERVICE_ID" --status unhealthy 2>/dev/null || true
            fi
        fi
        
        sleep "$HEARTBEAT_INTERVAL"
    done
) &
HEARTBEAT_PID=$!
echo "$(date) ${HOSTNAME} TSB Redis: Heartbeat monitor started (PID: $HEARTBEAT_PID)"

# Calculate remaining time for timeout
CURRENT_TIME=$(date +%s)
ELAPSED_TIME=$((CURRENT_TIME - SCRIPT_START_TIME))
TIMEOUT_SECONDS=$((TOTAL_WALLTIME - ELAPSED_TIME))

# Add safety margin (reserve 60 seconds for cleanup)
TIMEOUT_SECONDS=$((TIMEOUT_SECONDS - 60))

# Ensure timeout is positive
if [ $TIMEOUT_SECONDS -le 0 ]; then
    echo "$(date) ${HOSTNAME} TSB WARNING: No time remaining for test (elapsed: ${ELAPSED_TIME}s)"
    TIMEOUT_SECONDS=60  # Give it at least 1 minute
fi

echo "$(date) ${HOSTNAME} TSB Elapsed time: ${ELAPSED_TIME}s, Timeout set to: ${TIMEOUT_SECONDS}s"

# HERE is where you would add the test.coli_v2.py script, and when it returned successfully, you would kill the vLLM server.
# WHEN THE TEST.COLI_V2.PY SCRIPT RETURNS SUCCESSFULLY, YOU WOULD KILL THE VLLM SERVER.
# sleep $TIMEOUT_SECONDS
sleep 120
test_exit_code=$?

# Kill the vllm server when the python script is done
echo "$(date) ${HOSTNAME} TSB Stopping vLLM server..."
kill -SIGINT "$vllm_pid"
wait "$vllm_pid" 2>/dev/null

# Give filesystem time to flush any buffered output
sleep 2
echo "$(date) ${HOSTNAME} TSB vLLM log size: $(du -h $OUTPUT_DIR/${HOSTNAME}.vllm.log 2>/dev/null | cut -f1 || echo '0')"
echo "$(date) ${HOSTNAME} TSB vLLM process exited with code: $vllm_exit_code"

# Archive and transfer results from /dev/shm to shared filesystem
#echo "$(date) ${HOSTNAME} TSB Archiving results from $OUTPUT_DIR"
#ARCHIVE_NAME="${HOSTNAME}_results_$(date +%Y%m%d_%H%M%S).tar.gz"
#ARCHIVE_PATH="${SCRIPT_DIR}/${ARCHIVE_NAME}"

# Create tar archive of all output files
#cd /dev/shm
#tar -czf "$ARCHIVE_PATH" "vllm_output_${HOSTNAME}_$$/" 2>&1
#
#if [ $? -eq 0 ]; then
#    echo "$(date) ${HOSTNAME} TSB Results archived to: $ARCHIVE_PATH"
#    
#    # Show archive size
#    ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
#    echo "$(date) ${HOSTNAME} TSB Archive size: $ARCHIVE_SIZE"
#    
#    # Cleanup /dev/shm
#    echo "$(date) ${HOSTNAME} TSB Cleaning up $OUTPUT_DIR"
#    rm -rf "$OUTPUT_DIR"
#    echo "$(date) ${HOSTNAME} TSB Cleanup complete"
#else
#    echo "$(date) ${HOSTNAME} TSB ERROR: Failed to create archive"
#    echo "$(date) ${HOSTNAME} TSB Output files remain in: $OUTPUT_DIR"
#fi

echo "$(date) ${HOSTNAME} TSB Script complete"
