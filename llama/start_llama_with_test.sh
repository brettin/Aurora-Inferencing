#!/bin/bash -l

# ============================================================================
# Command-line Arguments
# ============================================================================
DEVICE=${1:-0}
BATCH_SIZE=${2:-32}
REDIS_HOST=${3:-localhost}
REDIS_PORT=${4:-6379}

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
INFILE=${5:-"${SCRIPT_DIR}/../examples/TOM.COLI/1.txt"}

# ============================================================================
# Configuration Parameters (with environment variable overrides)
# ============================================================================

## Port Configuration
BASE_PORT=${LLAMA_BASE_PORT:-8888}
LLAMA_PORT=$((BASE_PORT + DEVICE))

## Performance & Threading
export OMP_NUM_THREADS=${LLAMA_OMP_THREADS:-64}
LLAMA_CONTEXT_SIZE=${LLAMA_CONTEXT_SIZE:-131072}
LLAMA_PARALLEL_SLOTS=${LLAMA_PARALLEL_SLOTS:-32}
LLAMA_THREADS=${LLAMA_THREADS:-32}
LLAMA_GPU_LAYERS=${LLAMA_GPU_LAYERS:-80}

## Timeout Configuration
CLEANUP_MARGIN=${LLAMA_CLEANUP_MARGIN:-300}           # 5 minutes
SERVER_STARTUP_TIMEOUT=${LLAMA_STARTUP_TIMEOUT:-600}  # 10 minutes
HEALTH_CHECK_INTERVAL=${LLAMA_HEALTH_INTERVAL:-2}     # 2 seconds
HEARTBEAT_INTERVAL=${LLAMA_HEARTBEAT_INTERVAL:-10}    # 10 seconds
MAX_HEALTH_FAILURES=${LLAMA_MAX_FAILURES:-3}
MIN_TEST_TIMEOUT=${LLAMA_MIN_TIMEOUT:-60}              # 1 minute
FILESYSTEM_FLUSH_DELAY=${LLAMA_FLUSH_DELAY:-2}        # 2 seconds

## Path Configuration
ONEAPI_SETVARS=${ONEAPI_SETVARS:-"/opt/intel/oneapi/setvars.sh"}
OUTPUT_BASE_DIR=${LLAMA_OUTPUT_DIR:-"/dev/shm"}
REDIS_ENV_DIR=${REDIS_ENV_DIR:-"/tmp/redis_env"}
LLAMA_BUILD_DIR=${LLAMA_BUILD_DIR:-"gpt-oss-120b-intel-max-gpu"}
MODEL_FILE=${LLAMA_MODEL_FILE:-"/tmp/hf_home/hub/models/gpt-oss-120b-Q4_K_M-00001-of-00002.gguf"}
MODEL_ALIAS=${LLAMA_MODEL_ALIAS:-"gpt-oss-120b"}

## Proxy Configuration
HTTP_PROXY_URL=${HTTP_PROXY_URL:-"http://proxy.alcf.anl.gov:3128"}
HTTPS_PROXY_URL=${HTTPS_PROXY_URL:-"http://proxy.alcf.anl.gov:3128"}

# ============================================================================
# Derived Variables
# ============================================================================
HOSTNAME=$(hostname)
LLAMA_HOST="$HOSTNAME"
OUTPUT_DIR="${OUTPUT_BASE_DIR}/llama_output_${HOSTNAME}_$$"

# Walltime calculation
SCRIPT_START_TIME=$(date +%s)
TOTAL_WALLTIME=${WALLTIME_SECONDS:-3600}  # 60 minutes
TIMEOUT_SECONDS=$((TOTAL_WALLTIME - CLEANUP_MARGIN))

# Model paths
REDIS_DIR="${SCRIPT_DIR}/../redis"
LLAMA_SERVER_BIN="${SCRIPT_DIR}/${LLAMA_BUILD_DIR}/scripts/llama.cpp/build/bin/llama-server"
MODEL_PATH="$MODEL_FILE"

# ============================================================================
# Display Configuration
# ============================================================================
echo "$(date) ${HOSTNAME} Redis Service Registry Configuration: REDIS_HOST=${REDIS_HOST}, REDIS_PORT=${REDIS_PORT}"

# optimization experiments
# export ZE_AFFINITY_MASK=1 
export KMP_AFFINITY=verbose,none

echo "$(date) ${HOSTNAME} Llama script directory is: $SCRIPT_DIR"
echo "$(date) ${HOSTNAME} Llama infile is ${INFILE}"
echo "$(date) ${HOSTNAME} Llama hostname: $HOSTNAME"
echo "$(date) ${HOSTNAME} Llama port: ${LLAMA_PORT}"
echo "$(date) ${HOSTNAME} Llama Total walltime: ${TOTAL_WALLTIME}s ($(($TOTAL_WALLTIME/60)) minutes)"

# Set HTTP proxy for any potential downloads
export HTTP_PROXY="$HTTP_PROXY_URL"
export HTTPS_PROXY="$HTTPS_PROXY_URL"
export http_proxy="$HTTP_PROXY_URL"
export https_proxy="$HTTPS_PROXY_URL"

# Source Intel oneAPI environment
if [ -f "$ONEAPI_SETVARS" ]; then
    echo "$(date) ${HOSTNAME} Sourcing Intel oneAPI environment..."
    source "$ONEAPI_SETVARS" > /dev/null 2>&1
fi


# Set GPU device selector 0,2,4,6,8,10
export ZES_ENABLE_SYSMAN=1
export ONEAPI_DEVICE_SELECTOR="level_zero:${DEVICE}"
module load frameworks

# Setup local output directory for fast I/O
mkdir -p "$OUTPUT_DIR"
echo "$(date) ${HOSTNAME} Local output directory: $OUTPUT_DIR"

# Redis Service Registry Configuration
pip install --target "$REDIS_ENV_DIR" -r "${REDIS_DIR}/requirements.txt" > /dev/null 2>&1
export PYTHONPATH="$PYTHONPATH:$REDIS_ENV_DIR"

# Verify llama-server exists
if [ ! -f "$LLAMA_SERVER_BIN" ]; then
    echo "$(date) ${HOSTNAME} ERROR: llama-server not found at $LLAMA_SERVER_BIN"
    exit 1
fi

# Verify model exists
if [ ! -f "$MODEL_PATH" ]; then
    echo "$(date) ${HOSTNAME} ERROR: Model not found at $MODEL_PATH"
    exit 1
fi

# Set library path - derive from llama-server binary location
export LD_LIBRARY_PATH="$(dirname "$LLAMA_SERVER_BIN"):$LD_LIBRARY_PATH"

# Redis Service Registry: Register service before starting llama-server
SERVICE_ID="llama-${HOSTNAME}-${LLAMA_PORT}-$$"
echo "$(date) ${HOSTNAME} Redis: Registering service: $SERVICE_ID"

# Extract model name for cleaner metadata
MODEL_NAME=$(basename "$MODEL_PATH")

# Build metadata JSON
METADATA=$(cat <<EOF
{
  "model": "${MODEL_PATH}",
  "model_name": "${MODEL_NAME}",
  "device": ${DEVICE},
  "batch_size": ${BATCH_SIZE},
  "context_size": ${LLAMA_CONTEXT_SIZE},
  "parallel": ${LLAMA_PARALLEL_SLOTS},
  "threads": ${LLAMA_THREADS},
  "gpu_layers": ${LLAMA_GPU_LAYERS},
  "pid": $$,
  "script_start_time": ${SCRIPT_START_TIME},
  "output_dir": "${OUTPUT_DIR}"
}
EOF
)
echo "$(date) ${HOSTNAME} Metadata: $METADATA"

# Register service with "starting" status
if python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
    register "$SERVICE_ID" \
    --host "$LLAMA_HOST" \
    --port "$LLAMA_PORT" \
    --service-type "llama-inference" \
    --status starting \
    --metadata "$METADATA"; then
    echo "$(date) ${HOSTNAME} Redis: Service registered successfully"
else
    echo "$(date) ${HOSTNAME} Redis: WARNING - Failed to register service (continuing anyway)"
fi

echo "$(date) ${HOSTNAME} Starting llama-server with model: $MODEL_NAME"
echo "$(date) ${HOSTNAME} Writing log to: $OUTPUT_DIR/${HOSTNAME}.llama.log"

# Start llama-server in background
export LLAMA_SERVER_SLOTS_DEBUG=1  # Enable slot debugging

"$LLAMA_SERVER_BIN" \
    -m "$MODEL_PATH" \
    --alias "$MODEL_ALIAS" \
    --host "$LLAMA_HOST" \
    --port "$LLAMA_PORT" \
    -ngl "$LLAMA_GPU_LAYERS" \
    -c "$LLAMA_CONTEXT_SIZE" \
    --parallel "$LLAMA_PARALLEL_SLOTS" \
    -t "$LLAMA_THREADS" \
    --cont-batching \
    --kv-unified \
    --log-timestamps \
    --log-prefix \
    --metrics \
    > "$OUTPUT_DIR/${HOSTNAME}.llama.log" 2>&1 &
# --device SYCL${DEVICE} \
# --main-gpu ${DEVICE} \
# --cpu-range 105-136 \


llama_pid=$!
echo "$(date) ${HOSTNAME} llama-server PID: $llama_pid"

# Clear proxy after starting (in case it interferes with local connections)
unset HTTP_PROXY
unset HTTPS_PROXY
unset http_proxy
unset https_proxy

# Wait for llama-server to be ready
echo "$(date) ${HOSTNAME} Waiting for llama-server to be ready..."
WAIT_COUNT=0
until curl -sf "http://${HOSTNAME}:${LLAMA_PORT}/health" > /dev/null 2>&1; do
    echo "$(date) ${HOSTNAME} Waiting for llama-server to be ready... ${WAIT_COUNT} seconds"
    sleep "$HEALTH_CHECK_INTERVAL"
    WAIT_COUNT=$((WAIT_COUNT + HEALTH_CHECK_INTERVAL))
    if [ $WAIT_COUNT -ge $SERVER_STARTUP_TIMEOUT ]; then
        echo "$(date) ${HOSTNAME} ERROR: llama-server did not become ready after ${SERVER_STARTUP_TIMEOUT} seconds"
        kill -9 $llama_pid 2>/dev/null
        exit 1
    fi
done
echo "$(date) ${HOSTNAME} llama-server is ready!"
echo "$(date) ${HOSTNAME} Access at: http://${HOSTNAME}:${LLAMA_PORT}"

# Redis Service Registry: Update status to healthy
echo "$(date) ${HOSTNAME} Redis: Updating service status to healthy"
python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
    update-health "$SERVICE_ID" --status healthy || \
    echo "$(date) ${HOSTNAME} Redis: WARNING - Failed to update health status"

# Redis Service Registry: Start heartbeat and health monitoring loop
echo "$(date) ${HOSTNAME} Redis: Starting heartbeat monitor (interval: ${HEARTBEAT_INTERVAL}s)"
(
    HEALTH_CHECK_FAILURES=0
    
    while true; do
        # Check if llama-server process is still running
        if ! kill -0 "$llama_pid" 2>/dev/null; then
            echo "$(date) ${HOSTNAME} Redis: llama-server process no longer running, stopping heartbeat"
            break
        fi
        
        # Perform HTTP health check
        if ! curl -sf "http://${LLAMA_HOST}:${LLAMA_PORT}/health" > /dev/null 2>&1; then
            HEALTH_CHECK_FAILURES=$((HEALTH_CHECK_FAILURES + 1))
            echo "$(date) ${HOSTNAME} Redis: Health check failed (failures: $HEALTH_CHECK_FAILURES/$MAX_HEALTH_FAILURES)"
            
            # Update status to unhealthy if we've reached max failures
            if [ $HEALTH_CHECK_FAILURES -ge $MAX_HEALTH_FAILURES ]; then
                echo "$(date) ${HOSTNAME} Redis: Service unhealthy after $MAX_HEALTH_FAILURES failures"
                python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
                    update-health "$SERVICE_ID" --status unhealthy 2>/dev/null || true
            fi
        else
            # Health check passed - send heartbeat to update last_seen timestamp
            python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
                heartbeat "$SERVICE_ID" --quiet 2>/dev/null || true
            
            # If we recovered from failures, update status back to healthy
            if [ $HEALTH_CHECK_FAILURES -gt 0 ]; then
                echo "$(date) ${HOSTNAME} Redis: Service recovered, updating to healthy"
                python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
                    update-health "$SERVICE_ID" --status healthy 2>/dev/null || true
                HEALTH_CHECK_FAILURES=0
            fi
        fi
        
        sleep "$HEARTBEAT_INTERVAL"
    done
) &
HEARTBEAT_PID=$!
echo "$(date) ${HOSTNAME} Redis: Heartbeat monitor started (PID: $HEARTBEAT_PID)"

# Calculate remaining time for timeout
CURRENT_TIME=$(date +%s)
ELAPSED_TIME=$((CURRENT_TIME - SCRIPT_START_TIME))
TIMEOUT_SECONDS=$((TIMEOUT_SECONDS - ELAPSED_TIME))

# Ensure timeout is positive
if [ $TIMEOUT_SECONDS -le 0 ]; then
    echo "$(date) ${HOSTNAME} WARNING: No time remaining for test (elapsed: ${ELAPSED_TIME}s)"
    TIMEOUT_SECONDS=$MIN_TEST_TIMEOUT  # Give it at least minimum timeout
fi

echo "$(date) ${HOSTNAME} Elapsed time: ${ELAPSED_TIME}s, Timeout set to: ${TIMEOUT_SECONDS}s"

infile_base=$(basename "$INFILE")
echo "$(date) ${HOSTNAME} Calling test.coli_v2.py on ${infile_base} using llama-server"

# Run python with timeout, output to /dev/shm
timeout "${TIMEOUT_SECONDS}" python -u "${SCRIPT_DIR}/../examples/TOM.COLI/test.coli_v2.py" "${INFILE}" "${HOSTNAME}" \
	--batch-size "${BATCH_SIZE}" \
	--model "${MODEL_ALIAS}" \
	--port "${LLAMA_PORT}" \
	> "${OUTPUT_DIR}/${infile_base}.${HOSTNAME}.test.coli_v2.txt" 2>&1

# Get exit code from timeout command
test_exit_code=$?

# Check if timeout occurred (exit code 124)
if [ $test_exit_code -eq 124 ]; then
    echo "$(date) ${HOSTNAME} test.coli TIMED OUT after ${TIMEOUT_SECONDS} seconds"
elif [ $test_exit_code -eq 137 ]; then
    echo "$(date) ${HOSTNAME} test.coli was KILLED (SIGKILL)"
else
    echo "$(date) ${HOSTNAME} test.coli returned ${test_exit_code}"
fi

# Kill the llama-server when the python script is done
echo "$(date) ${HOSTNAME} Stopping llama-server..."

# Redis Service Registry: Update status to stopping
echo "$(date) ${HOSTNAME} Redis: Updating service status to stopping"
python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
    update-health "$SERVICE_ID" --status stopping 2>/dev/null || true

# Stop heartbeat monitor
if [ -n "$HEARTBEAT_PID" ] && kill -0 "$HEARTBEAT_PID" 2>/dev/null; then
    echo "$(date) ${HOSTNAME} Redis: Stopping heartbeat monitor..."
    kill "$HEARTBEAT_PID" 2>/dev/null || true
fi

kill -SIGINT "$llama_pid"
wait "$llama_pid" 2>/dev/null

# Redis Service Registry: Deregister service
echo "$(date) ${HOSTNAME} Redis: Deregistering service: $SERVICE_ID"
python3 "${REDIS_DIR}/cli.py" --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
    deregister "$SERVICE_ID" 2>/dev/null || echo "$(date) ${HOSTNAME} Redis: Failed to deregister service"

# Give filesystem time to flush any buffered output
sleep "$FILESYSTEM_FLUSH_DELAY"
echo "$(date) ${HOSTNAME} llama-server log size: $(du -h "$OUTPUT_DIR/${HOSTNAME}.llama.log" 2>/dev/null | cut -f1 || echo '0')"

# Archive and transfer results from /dev/shm to shared filesystem
echo "$(date) ${HOSTNAME} Archiving results from $OUTPUT_DIR"
ARCHIVE_NAME="${HOSTNAME}_results_$(date +%Y%m%d_%H%M%S).tar.gz"
ARCHIVE_PATH="${SCRIPT_DIR}/${ARCHIVE_NAME}"

# Create tar archive of all output files
cd "$(dirname "$OUTPUT_DIR")"
if tar -czf "$ARCHIVE_PATH" "$(basename "$OUTPUT_DIR")/" 2>&1; then
    echo "$(date) ${HOSTNAME} Results archived to: $ARCHIVE_PATH"
    
    # Show archive size
    ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
    echo "$(date) ${HOSTNAME} Archive size: $ARCHIVE_SIZE"
    
    # Cleanup /dev/shm
    echo "$(date) ${HOSTNAME} Cleaning up $OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR"
    echo "$(date) ${HOSTNAME} Cleanup complete"
else
    echo "$(date) ${HOSTNAME} ERROR: Failed to create archive"
    echo "$(date) ${HOSTNAME} Output files remain in: $OUTPUT_DIR"
fi

echo "$(date) ${HOSTNAME} Script complete"
