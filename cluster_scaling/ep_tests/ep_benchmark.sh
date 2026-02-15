#!/bin/bash
#PBS -N ep_benchmark
#PBS -l walltime=00:30:00
#PBS -A AuroraGPT
#PBS -q debug
#PBS -o output_ep_benchmark.log
#PBS -e error_ep_benchmark.log
#PBS -l select=1
#PBS -l filesystems=flare:home
#PBS -l place=scatter

# ============================================================================
# Expert Parallelism Throughput Benchmark
# ============================================================================
# This script compares throughput between:
# 1. TP=8 WITHOUT expert parallelism (baseline)
# 2. TP=8 WITH expert parallelism enabled
# ============================================================================

set -e

# --- CONFIGURATION ---
if [ -n "$PBS_O_WORKDIR" ]; then
    cd "$PBS_O_WORKDIR" || exit 1
fi

SCRIPT_DIR=$(pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")  # cluster_scaling directory
JOB_ID_CLEAN=$(echo "$PBS_JOBID" | cut -d. -f1)
JOB_LOG_DIR="$SCRIPT_DIR/logs/${JOB_ID_CLEAN}"
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
echo "Expert Parallelism Throughput Benchmark"
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
    echo "ERROR: Model staging failed"
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
ulimit -c 0

MODEL="openai/gpt-oss-120b"
PORT=8000

# Benchmark configuration
NUM_PROMPTS=1000
INPUT_LEN=3000
OUTPUT_LEN=1000

# Function to run benchmark
run_benchmark() {
    local CONFIG_NAME=$1
    local EP_FLAG=$2
    local LOG_PREFIX="$JOB_LOG_DIR/${CONFIG_NAME}"
    
    echo ""
    echo "=============================================="
    echo "Running: $CONFIG_NAME"
    echo "=============================================="
    
    # Start vLLM server
    echo "Starting vLLM server..."
    nohup vllm serve "$MODEL" \
        --tensor-parallel-size 8 \
        $EP_FLAG \
        --port "$PORT" \
        --disable-custom-all-reduce \
        --enforce-eager \
        --distributed-executor-backend mp \
        --dtype bfloat16 \
        --gpu-memory-utilization 0.90 \
        > "${LOG_PREFIX}_server.log" 2>&1 &
    
    VLLM_PID=$!
    echo "vLLM started (PID: $VLLM_PID)"
    
    # Wait for server to be ready
    echo "Waiting for server to initialize..."
    MAX_WAIT=300
    ELAPSED=0
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        if curl -s "http://localhost:$PORT/health" > /dev/null 2>&1; then
            echo "Server ready after ${ELAPSED}s"
            break
        fi
        if ! ps -p $VLLM_PID > /dev/null 2>&1; then
            echo "ERROR: Server died during startup"
            tail -50 "${LOG_PREFIX}_server.log"
            return 1
        fi
        sleep 10
        ELAPSED=$((ELAPSED + 10))
    done
    
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo "ERROR: Server failed to start in ${MAX_WAIT}s"
        kill $VLLM_PID 2>/dev/null
        return 1
    fi
    
    # Warmup request
    echo "Sending warmup request..."
    curl -s -X POST "http://localhost:$PORT/v1/completions" \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"$MODEL\", \"prompt\": \"Hello\", \"max_tokens\": 10}" \
        --max-time 120 > /dev/null 2>&1
    sleep 5
    
    # Run benchmark
    BENCH_START=$(date +%s)
    echo "Running benchmark: $NUM_PROMPTS prompts, input=$INPUT_LEN, output=$OUTPUT_LEN"
    
    vllm bench serve \
        --model "$MODEL" \
        --backend openai \
        --base-url "http://localhost:$PORT" \
        --dataset-name random \
        --seed 12345 \
        --num-prompts "$NUM_PROMPTS" \
        --random-input-len "$INPUT_LEN" \
        --random-output-len "$OUTPUT_LEN" \
        > "${LOG_PREFIX}_bench.log" 2>&1
    
    BENCH_END=$(date +%s)
    BENCH_DURATION=$((BENCH_END - BENCH_START))
    
    # Extract results
    OUTPUT_THROUGHPUT=$(grep "Output token throughput" "${LOG_PREFIX}_bench.log" | awk '{print $5}')
    TOTAL_THROUGHPUT=$(grep "Total Token throughput" "${LOG_PREFIX}_bench.log" | awk '{print $5}')
    TTFT=$(grep "Mean TTFT" "${LOG_PREFIX}_bench.log" | awk '{print $4}')
    
    echo "  Output Throughput: $OUTPUT_THROUGHPUT tok/s"
    echo "  Total Throughput:  $TOTAL_THROUGHPUT tok/s"
    echo "  Mean TTFT:         $TTFT ms"
    echo "  Benchmark Duration: ${BENCH_DURATION}s"
    
    # Save results
    echo "$CONFIG_NAME,$OUTPUT_THROUGHPUT,$TOTAL_THROUGHPUT,$TTFT,$BENCH_DURATION" >> "$JOB_LOG_DIR/results.csv"
    
    # Stop server
    echo "Stopping server..."
    kill $VLLM_PID 2>/dev/null
    wait $VLLM_PID 2>/dev/null || true
    sleep 10
    
    return 0
}

# --- 5. RUN BENCHMARKS ---
echo "config,output_throughput,total_throughput,mean_ttft,duration" > "$JOB_LOG_DIR/results.csv"

# Run baseline (no EP)
run_benchmark "baseline_tp8" ""

# Run with EP enabled
run_benchmark "ep_enabled_tp8" "--enable-expert-parallel"

# --- 6. SUMMARY ---
echo ""
echo "=============================================="
echo "BENCHMARK COMPARISON RESULTS"
echo "=============================================="
echo ""
column -t -s',' "$JOB_LOG_DIR/results.csv"
echo ""

# Calculate speedup
BASELINE_THROUGHPUT=$(grep "baseline" "$JOB_LOG_DIR/results.csv" | cut -d',' -f2)
EP_THROUGHPUT=$(grep "ep_enabled" "$JOB_LOG_DIR/results.csv" | cut -d',' -f2)

if [ -n "$BASELINE_THROUGHPUT" ] && [ -n "$EP_THROUGHPUT" ]; then
    SPEEDUP=$(echo "scale=2; $EP_THROUGHPUT / $BASELINE_THROUGHPUT" | bc)
    echo "EP Speedup: ${SPEEDUP}x vs baseline"
fi

JOB_END_TIME=$(date +%s)
JOB_DURATION=$((JOB_END_TIME - JOB_START_TIME))

echo ""
echo "=============================================="
echo "Benchmark Complete"
echo "Total Duration: ${JOB_DURATION}s"
echo "Results: $JOB_LOG_DIR/results.csv"
echo "=============================================="
