#!/bin/bash -l

# ============================================================================
# vLLM Server Startup Script with Testing
# ============================================================================
# This script starts a vLLM inference server with Ray, runs a test workload,
# and manages the service lifecycle including Redis service registry integration.
#
# USAGE:
#   ./start_vllm_with_test.sh [REDIS_HOST] [REDIS_PORT] [INFILE]
#
# COMMAND-LINE ARGUMENTS:
#   REDIS_HOST   - Redis server hostname (default: localhost)
#   REDIS_PORT   - Redis server port (default: 6379)
#   INFILE       - Input file for test script (default: ../examples/TOM.COLI/1.txt)
#
# ENVIRONMENT VARIABLES (all optional):
#
#   Timing Configuration:
#     WALLTIME_SECONDS          - Total walltime in seconds (default: 7200)
#     VLLM_HEARTBEAT_INTERVAL   - Health check interval in seconds (default: 10)
#     VLLM_MAX_FAILURES         - Max consecutive health failures (default: 3)
#     VLLM_CLEANUP_MARGIN       - Time reserved for cleanup in seconds (default: 300)
#     VLLM_FLUSH_DELAY          - Filesystem flush delay in seconds (default: 2)
#
#   Network Configuration:
#     HTTP_PROXY_URL            - HTTP proxy URL (default: http://proxy.alcf.anl.gov:3128)
#     HTTPS_PROXY_URL           - HTTPS proxy URL (default: http://proxy.alcf.anl.gov:3128)
#
#   Compute Resources:
#     VLLM_TILES                - Number of GPU tiles (default: 12)
#     NUMEXPR_THREADS           - NumExpr thread count (default: 208)
#     RAY_NUM_CPUS              - Ray CPU allocation (default: 64)
#
#   Directories:
#     HF_HOME_DIR               - Hugging Face cache directory (default: /tmp/hf_home)
#     TEMP_DIR                  - Temporary directory (default: /tmp)
#     OUTPUT_BASE_DIR           - Base directory for outputs (default: /dev/shm)
#     REDIS_ENV_DIR             - Redis Python environment directory (default: /tmp/redis_env)
#
#   Ray Configuration:
#     RAY_PORT                  - Ray head port (default: 6379)
#
#   vLLM Configuration:
#     VLLM_HOST_PORT            - vLLM server port (default: 8000)
#     VLLM_MODEL                - Model name (default: meta-llama/Llama-3.3-70B-Instruct)
#     VLLM_TENSOR_PARALLEL      - Tensor parallel size (default: 8)
#     VLLM_DTYPE                - Data type (default: bfloat16)
#     VLLM_MAX_MODEL_LEN        - Max model length (default: 32000)
#
#   Test Configuration:
#     TEST_BATCH_SIZE           - Batch size for test script (default: 32)
#
# EXAMPLES:
#   # Use all defaults
#   ./start_vllm_with_test.sh
#
#   # Specify Redis server
#   ./start_vllm_with_test.sh redis-server.example.com 6379
#
#   # Override model and batch size
#   VLLM_MODEL="meta-llama/Llama-2-70b-hf" TEST_BATCH_SIZE=64 ./start_vllm_with_test.sh
#
# ============================================================================

# ============================================================================
# Command-line Arguments
# ============================================================================

REDIS_HOST=${1:-localhost}
REDIS_PORT=${2:-6379}

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
INFILE=${3:-"${SCRIPT_DIR}/../examples/TOM.COLI/1.txt"}

# ============================================================================
# Configuration Parameters (can be overridden via environment variables)
# ============================================================================

# Timing Configuration
SCRIPT_START_TIME=$(date +%s)
TOTAL_WALLTIME=${WALLTIME_SECONDS:-7200}                  # Total walltime in seconds (default: 2 hours)
HEARTBEAT_INTERVAL=${VLLM_HEARTBEAT_INTERVAL:-10}         # Health check interval in seconds
MAX_HEALTH_FAILURES=${VLLM_MAX_FAILURES:-3}               # Max consecutive health check failures
CLEANUP_MARGIN=${VLLM_CLEANUP_MARGIN:-300}                # Time reserved for cleanup in seconds (5 minutes)
FILESYSTEM_FLUSH_DELAY=${VLLM_FLUSH_DELAY:-2}             # Delay for filesystem flush in seconds

# Redis Configuration
REDIS_ENV_DIR=${REDIS_ENV_DIR:-"/tmp/redis_env"}
REDIS_DIR="${SCRIPT_DIR}/../redis"

# HTTP Proxy Configuration
HTTP_PROXY_URL=${HTTP_PROXY_URL:-"http://proxy.alcf.anl.gov:3128"}
HTTPS_PROXY_URL=${HTTPS_PROXY_URL:-"http://proxy.alcf.anl.gov:3128"}

# Compute Resources
VLLM_TILES=${VLLM_TILES:-12}                              # Number of GPU tiles
NUMEXPR_THREADS=${NUMEXPR_THREADS:-208}                   # NumExpr thread count
RAY_NUM_CPUS=${RAY_NUM_CPUS:-64}                          # Ray CPU allocation

# Directory Configuration
HF_HOME_DIR=${HF_HOME_DIR:-"/tmp/hf_home"}                # Hugging Face cache directory
TEMP_DIR=${TEMP_DIR:-"/tmp"}                              # Temporary directory
OUTPUT_BASE_DIR=${OUTPUT_BASE_DIR:-"/dev/shm"}            # Base directory for outputs

# Ray Configuration
RAY_PORT=${RAY_PORT:-6379}                                # Ray head port

# vLLM Configuration
VLLM_HOST_PORT=${VLLM_HOST_PORT:-8000}                    # vLLM server port
VLLM_MODEL=${VLLM_MODEL:-"meta-llama/Llama-3.3-70B-Instruct"}
VLLM_TENSOR_PARALLEL=${VLLM_TENSOR_PARALLEL:-8}           # Tensor parallel size
VLLM_DTYPE=${VLLM_DTYPE:-"bfloat16"}                      # Data type
VLLM_MAX_MODEL_LEN=${VLLM_MAX_MODEL_LEN:-32000}           # Max model length

# Test Script Configuration
TEST_BATCH_SIZE=${TEST_BATCH_SIZE:-32}                    # Batch size for test script

HOSTNAME=$(hostname)
echo "$(date) ${HOSTNAME} TSB script directory is: $SCRIPT_DIR"
echo "$(date) ${HOSTNAME} TSB infile is ${INFILE}"
echo "$(date) ${HOSTNAME} TSB hostname: $HOSTNAME"
echo "$(date) ${HOSTNAME} TSB Total walltime: ${TOTAL_WALLTIME}s ($(($TOTAL_WALLTIME/60)) minutes)"
echo "$(date) ${HOSTNAME} TSB Redis Service Registry Configuration: REDIS_HOST=${REDIS_HOST}, REDIS_PORT=${REDIS_PORT}"

# This is needed incase vllm tries to download from huggingface.
export HTTP_PROXY="$HTTP_PROXY_URL"
export HTTPS_PROXY="$HTTPS_PROXY_URL"
export http_proxy="$HTTP_PROXY_URL"
export https_proxy="$HTTPS_PROXY_URL"

module load frameworks

# Redis Service Registry Configuration
pip install --target "$REDIS_ENV_DIR" -r "${REDIS_DIR}/requirements.txt" > /dev/null 2>&1
export PYTHONPATH="$PYTHONPATH:$REDIS_ENV_DIR"

export tiles="$VLLM_TILES"
export ZE_FLAT_DEVICE_HIERARCHY=FLAT
export NUMEXPR_MAX_THREADS="$NUMEXPR_THREADS"
export CCL_PROCESS_LAUNCHER=torchrun # Per Ken R.

export HF_HOME="$HF_HOME_DIR"
export TMPDIR="$TEMP_DIR"
export RAY_TMPDIR="$TEMP_DIR"
export VLLM_HOST_IP=$(getent hosts ${HOSTNAME}.hsn.cm.aurora.alcf.anl.gov | awk '{ print $1 }' | tr ' ' '\n' | sort | head -n 1)
export RAY_ADDRESS="${VLLM_HOST_IP}:${RAY_PORT}"
export HF_HUB_OFFLINE=1

unset ONEAPI_DEVICE_SELECTOR
unset OMP_NUM_THREADS

# export CCL_PROCESS_LAUNCHER=torchrun

# Done setting up environment and variables.

# Setup local output directory for fast I/O
OUTPUT_DIR="${OUTPUT_BASE_DIR}/vllm_output_${HOSTNAME}_$$"
mkdir -p "$OUTPUT_DIR"
echo "$(date) ${HOSTNAME} TSB Local output directory: $OUTPUT_DIR"

echo "$(date) ${HOSTNAME} TSB starting ray on $VLLM_HOST_IP"
ray --logging-level info start --head --verbose --node-ip-address="$VLLM_HOST_IP" --port="$RAY_PORT" --num-cpus="$RAY_NUM_CPUS" --num-gpus="$VLLM_TILES"
echo "$(date) ${HOSTNAME} TSB done starting ray on $VLLM_HOST_IP"

echo "$(date) ${HOSTNAME} TSB starting vllm with ${VLLM_MODEL} on host ${HOSTNAME}"
echo "$(date) ${HOSTNAME} TSB writing log to $OUTPUT_DIR/${HOSTNAME}.vllm.log"

# Redis Service Registry: Register service before starting vLLM
SERVICE_ID="vllm-${HOSTNAME}-${VLLM_HOST_PORT}-$$"
echo "$(date) ${HOSTNAME} TSB Redis: Registering service: $SERVICE_ID"

# Build metadata JSON
METADATA=$(cat <<EOF
{
  "model": "${VLLM_MODEL}",
  "port": ${VLLM_HOST_PORT},
  "tensor_parallel_size": ${VLLM_TENSOR_PARALLEL},
  "dtype": "${VLLM_DTYPE}",
  "max_model_len": ${VLLM_MAX_MODEL_LEN},
  "ray_address": "${RAY_ADDRESS}",
  "tiles": ${VLLM_TILES},
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
    --host "$HOSTNAME" \
    --port "$VLLM_HOST_PORT" \
    --service-type "vllm-inference" \
    --status starting \
    --metadata "$METADATA"; then
    echo "$(date) ${HOSTNAME} TSB Redis: Service registered successfully"
else
    echo "$(date) ${HOSTNAME} TSB Redis: WARNING - Failed to register service (continuing anyway)"
fi

# Start vLLM server in background, redirecting output to log file
# Use PYTHONUNBUFFERED to ensure output is written immediately
PYTHONUNBUFFERED=1 vllm serve "${VLLM_MODEL}" --port "${VLLM_HOST_PORT}" --tensor-parallel-size "${VLLM_TENSOR_PARALLEL}" --dtype "${VLLM_DTYPE}" --trust-remote-code --max-model-len "${VLLM_MAX_MODEL_LEN}" > "$OUTPUT_DIR/${HOSTNAME}.vllm.log" 2>&1 &
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
echo "$(date) ${HOSTNAME} TSB Redis: Starting heartbeat monitor (interval: ${HEARTBEAT_INTERVAL}s)"
(
    HEALTH_CHECK_FAILURES=0
    
    while true; do
        # Check if vllm process is still running
        if ! kill -0 "$vllm_pid" 2>/dev/null; then
            echo "$(date) ${HOSTNAME} TSB Redis: vLLM process no longer running, stopping heartbeat"
            break
        fi
        
        # Perform HTTP health check
        if ! curl -sf "http://${HOSTNAME}:${VLLM_HOST_PORT}/health" > /dev/null 2>&1; then
            HEALTH_CHECK_FAILURES=$((HEALTH_CHECK_FAILURES + 1))
            echo "$(date) ${HOSTNAME} TSB Redis: Health check failed (failures: $HEALTH_CHECK_FAILURES/$MAX_HEALTH_FAILURES)"
            
            # Update status to unhealthy if we've reached max failures
            if [ $HEALTH_CHECK_FAILURES -ge $MAX_HEALTH_FAILURES ]; then
                echo "$(date) ${HOSTNAME} TSB Redis: Service unhealthy after $MAX_HEALTH_FAILURES failures"
                python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
                    update-health "$SERVICE_ID" --status unhealthy 2>/dev/null || true
            fi
        else
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

# Add safety margin (reserve CLEANUP_MARGIN seconds for cleanup)
TIMEOUT_SECONDS=$((TIMEOUT_SECONDS - CLEANUP_MARGIN))

# Ensure timeout is positive
if [ $TIMEOUT_SECONDS -le 0 ]; then
    echo "$(date) ${HOSTNAME} TSB WARNING: No time remaining for test (elapsed: ${ELAPSED_TIME}s)"
    TIMEOUT_SECONDS=60  # Give it at least 1 minute
fi

echo "$(date) ${HOSTNAME} TSB Elapsed time: ${ELAPSED_TIME}s, Timeout set to: ${TIMEOUT_SECONDS}s"


infile_base=$(basename "$INFILE")
echo "$(date) ${HOSTNAME} TSB calling test.coli_v2.py on ${infile_base} using ${VLLM_MODEL}"

# Run python with timeout, output to local directory
timeout "${TIMEOUT_SECONDS}" python -u "${SCRIPT_DIR}/../examples/TOM.COLI/test.coli_v2.py" "$INFILE" "$HOSTNAME" \
	--batch-size "${TEST_BATCH_SIZE}" \
	--model "${VLLM_MODEL}" \
	--port "${VLLM_HOST_PORT}" \
	> "${OUTPUT_DIR}/${infile_base}.${HOSTNAME}.test.coli_v2.txt" 2>&1

# Get exit code from timeout command
test_exit_code=$?

# Check if timeout occurred (exit code 124)
if [ $test_exit_code -eq 124 ]; then
    echo "$(date) ${HOSTNAME} TSB test.coli TIMED OUT after ${TIMEOUT_SECONDS} seconds"
elif [ $test_exit_code -eq 137 ]; then
    echo "$(date) ${HOSTNAME} TSB test.coli was KILLED (SIGKILL)"
else
    echo "$(date) ${HOSTNAME} TSB test.coli returned ${test_exit_code}"
fi

# Kill the vllm server when the python script is done
echo "$(date) ${HOSTNAME} TSB Stopping vLLM server..."

# Redis Service Registry: Update status to stopping
echo "$(date) ${HOSTNAME} TSB Redis: Updating service status to stopping"
python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
    update-health "$SERVICE_ID" --status stopping 2>/dev/null || true

# Stop heartbeat monitor
if [ -n "$HEARTBEAT_PID" ] && kill -0 "$HEARTBEAT_PID" 2>/dev/null; then
    echo "$(date) ${HOSTNAME} TSB Redis: Stopping heartbeat monitor..."
    kill "$HEARTBEAT_PID" 2>/dev/null || true
fi

kill -SIGINT "$vllm_pid"
wait "$vllm_pid" 2>/dev/null

# Redis Service Registry: Deregister service
echo "$(date) ${HOSTNAME} TSB Redis: Deregistering service: $SERVICE_ID"
python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
    deregister "$SERVICE_ID" 2>/dev/null || echo "$(date) ${HOSTNAME} TSB Redis: Failed to deregister service"

# Give filesystem time to flush any buffered output
sleep "$FILESYSTEM_FLUSH_DELAY"
echo "$(date) ${HOSTNAME} TSB vLLM log size: $(du -h "$OUTPUT_DIR/${HOSTNAME}.vllm.log" 2>/dev/null | cut -f1 || echo '0')"

# Archive and transfer results from local directory to shared filesystem
echo "$(date) ${HOSTNAME} TSB Archiving results from $OUTPUT_DIR"
ARCHIVE_NAME="${HOSTNAME}_results_$(date +%Y%m%d_%H%M%S).tar.gz"
ARCHIVE_PATH="${SCRIPT_DIR}/${ARCHIVE_NAME}"

# Create tar archive of all output files
cd "$OUTPUT_BASE_DIR"
tar -czf "$ARCHIVE_PATH" "vllm_output_${HOSTNAME}_$$/" 2>&1

if [ $? -eq 0 ]; then
    echo "$(date) ${HOSTNAME} TSB Results archived to: $ARCHIVE_PATH"
    
    # Show archive size
    ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
    echo "$(date) ${HOSTNAME} TSB Archive size: $ARCHIVE_SIZE"
    
    # Cleanup output directory
    echo "$(date) ${HOSTNAME} TSB Cleaning up $OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR"
    echo "$(date) ${HOSTNAME} TSB Cleanup complete"
else
    echo "$(date) ${HOSTNAME} TSB ERROR: Failed to create archive"
    echo "$(date) ${HOSTNAME} TSB Output files remain in: $OUTPUT_DIR"
fi

echo "$(date) ${HOSTNAME} TSB Script complete"
