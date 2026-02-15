#!/bin/bash
#PBS -N test_expert_parallel
#PBS -l walltime=00:15:00
#PBS -A AuroraGPT
#PBS -q debug
#PBS -o output_ep_test.log
#PBS -e error_ep_test.log
#PBS -l select=1
#PBS -l filesystems=flare:home
#PBS -l place=scatter

# ============================================================================
# Expert Parallelism Test Script
# ============================================================================
# This script:
# 1. Stages model weights and vLLM environment
# 2. Launches vLLM with expert parallelism enabled (TP=2, DP=6, EP enabled)
# 3. Validates that expert parallelism is properly active
# ============================================================================

set -e

# --- CONFIGURATION ---
if [ -n "$PBS_O_WORKDIR" ]; then
    cd "$PBS_O_WORKDIR" || exit 1
fi

SCRIPT_DIR=$(pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")  # cluster_scaling directory
JOB_ID_CLEAN=$(echo "$PBS_JOBID" | cut -d. -f1)
JOB_LOG_DIR="$SCRIPT_DIR/logs/${JOB_ID_CLEAN}_ep_test"
mkdir -p "$JOB_LOG_DIR"

# Redirect stdout/stderr to log
exec > >(tee -a "$JOB_LOG_DIR/master_run.log") 2>&1

# Paths
CPTOTMP_SRC="$ROOT_DIR/cptotmp.c"
CPTOTMP_BIN="$ROOT_DIR/cptotmp_bin"
MODEL_HUB_SOURCE="/flare/AuroraGPT/model-weights/optimized_model/hub"
MODEL_NAME="models--openai--gpt-oss-120b"
MODEL_SOURCE="$MODEL_HUB_SOURCE/$MODEL_NAME"
MODEL_DEST="/tmp/hub"
ENV_TAR="/flare/AuroraGPT/ngetty/envs/packed_envs/vllm_serve_env.tar.gz"
LOCAL_ENV="/tmp/vllm_env"

# --- PROXY SETTINGS ---
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128
export no_proxy=localhost,127.0.0.1

# --- TIMING START ---
JOB_START_TIME=$(date +%s)
echo "=============================================="
echo "Expert Parallelism Test"
echo "Job ID: $PBS_JOBID"
echo "Host: $(hostname)"
echo "Start Time: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================="

# --- 1. COMPILE COPY TOOL ---
if ! command -v mpicc &> /dev/null; then module load frameworks; fi
if [ ! -f "$CPTOTMP_BIN" ]; then
    echo "Compiling cptotmp..."
    mpicc -o "$CPTOTMP_BIN" "$CPTOTMP_SRC"
fi

# --- 2. STAGE FILES ---
echo "Staging Model Weights to $MODEL_DEST..."
export MPIR_CVAR_CH4_OFI_ENABLE_MULTI_NIC_STRIPING=1
export MPIR_CVAR_CH4_OFI_MAX_NICS=4

mkdir -p "$MODEL_DEST"
mpiexec -np 1 -ppn 1 --cpu-bind numa "$CPTOTMP_BIN" "$MODEL_SOURCE" "$MODEL_DEST"

echo "Staging Environment..."
mpiexec -ppn 1 --cpu-bind numa "$CPTOTMP_BIN" "$ENV_TAR" "/tmp"

# Verify staging
if ! ls $MODEL_DEST/$MODEL_NAME/snapshots/*/tokenizer.json > /dev/null 2>&1; then
    echo "ERROR: Model staging failed - tokenizer.json not found"
    exit 1
fi
echo "Model staging verified."

# --- 3. UNPACK ENV ---
TAR_NAME=$(basename "$ENV_TAR")
echo "Unpacking Environment..."
if [ ! -f "$LOCAL_ENV/bin/activate" ]; then
    mkdir -p "$LOCAL_ENV"
    tar -xf "/tmp/$TAR_NAME" -C "$LOCAL_ENV"
    source "$LOCAL_ENV/bin/activate"
    conda-unpack
else
    echo "Environment ready."
fi

source "$LOCAL_ENV/bin/activate"

# --- 4. ENVIRONMENT VARIABLES ---
export HF_HOME="/tmp"
export TMPDIR="/tmp"
export ZE_FLAT_DEVICE_HIERARCHY=FLAT
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export FI_MR_CACHE_MONITOR=userfaultfd
export TORCH_COMPILE_DISABLE=1
export OMP_NUM_THREADS=12
export TORCH_XPU_ALLOC_CONF=expandable_segments:True

# Enable verbose logging for EP detection
export VLLM_LOGGING_LEVEL=DEBUG

ulimit -c 0  # Disable core dumps

MODEL="openai/gpt-oss-120b"
PORT=8000

echo ""
echo "=============================================="
echo "Starting vLLM with Expert Parallelism"
echo "  TP=8, EP=enabled (8 GPUs in TP group)"
echo "=============================================="

# --- 5. START VLLM WITH EXPERT PARALLELISM ---
# Using 8 GPUs with TP=8 and EP enabled
# This distributes experts across the TP group without DP complexity
# NOTE: With TP=8 and 128 experts, each GPU handles 16 experts
nohup vllm serve "$MODEL" \
    --tensor-parallel-size 8 \
    --enable-expert-parallel \
    --port "$PORT" \
    --disable-custom-all-reduce \
    --enforce-eager \
    --distributed-executor-backend mp \
    --dtype bfloat16 \
    --gpu-memory-utilization 0.90 \
    > "$JOB_LOG_DIR/vllm.log" 2>&1 &

VLLM_PID=$!
echo "vLLM started (PID: $VLLM_PID)"

# --- 6. WAIT FOR VLLM TO BE READY ---
echo "Waiting for vLLM to initialize (checking /health endpoint)..."
MAX_WAIT=600
ELAPSED=0
INTERVAL=10

while [ $ELAPSED -lt $MAX_WAIT ]; do
    if curl -s "http://localhost:$PORT/health" > /dev/null 2>&1; then
        echo "vLLM is ready after ${ELAPSED}s"
        break
    fi
    
    # Check if process died
    if ! ps -p $VLLM_PID > /dev/null 2>&1; then
        echo "ERROR: vLLM process died. Check logs:"
        tail -100 "$JOB_LOG_DIR/vllm.log"
        exit 1
    fi
    
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    echo "  Still waiting... (${ELAPSED}s / ${MAX_WAIT}s)"
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "ERROR: vLLM failed to start within ${MAX_WAIT}s"
    tail -100 "$JOB_LOG_DIR/vllm.log"
    kill $VLLM_PID 2>/dev/null
    exit 1
fi

# --- 7. RUN VALIDATION ---
echo ""
echo "=============================================="
echo "Running Expert Parallelism Validation"
echo "=============================================="

python3 "$SCRIPT_DIR/validate_expert_parallel.py" \
    --log-file "$JOB_LOG_DIR/vllm.log" \
    --endpoint "http://localhost:$PORT" \
    --output "$JOB_LOG_DIR/validation_results.txt"

VALIDATION_EXIT_CODE=$?

# --- 8. CLEANUP ---
echo ""
echo "Cleaning up..."
kill $VLLM_PID 2>/dev/null || true
wait $VLLM_PID 2>/dev/null || true

# --- TIMING END ---
JOB_END_TIME=$(date +%s)
JOB_DURATION=$((JOB_END_TIME - JOB_START_TIME))

echo ""
echo "=============================================="
echo "Test Complete"
echo "Duration: ${JOB_DURATION}s"
echo "Logs: $JOB_LOG_DIR"
echo "=============================================="

# Copy key logs for easy access
cp "$JOB_LOG_DIR/validation_results.txt" "$SCRIPT_DIR/last_ep_test_results.txt" 2>/dev/null || true

exit $VALIDATION_EXIT_CODE
