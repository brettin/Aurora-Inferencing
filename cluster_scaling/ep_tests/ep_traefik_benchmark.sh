#!/bin/bash
#PBS -N ep_traefik_bench
#PBS -l walltime=00:30:00
#PBS -A AuroraGPT
#PBS -q debug
#PBS -o output_ep_traefik.log
#PBS -e error_ep_traefik.log
#PBS -l select=1
#PBS -l filesystems=flare:home
#PBS -l place=scatter

# ============================================================================
# Expert Parallelism + Traefik Load Balancing Benchmark
# ============================================================================
# Configuration: 3 vLLM instances with TP=4 + EP enabled, behind Traefik
# - Each instance uses 4 GPUs (GPUs 0-3, 4-7, 8-11)
# - EP divides 128 experts across 4 EP ranks = 32 experts/GPU
# - Traefik load balances requests across 3 instances
# ============================================================================

set -e

# --- CONFIGURATION ---
if [ -n "$PBS_O_WORKDIR" ]; then
    cd "$PBS_O_WORKDIR" || exit 1
fi

SCRIPT_DIR=$(pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")  # cluster_scaling directory
JOB_ID_CLEAN=$(echo "$PBS_JOBID" | cut -d. -f1)
JOB_LOG_DIR="$SCRIPT_DIR/logs/${JOB_ID_CLEAN}_ep_traefik"
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

# vLLM instance configuration
declare -A GPU_AFFINITY=(
    [1]="0,1,2,3"
    [2]="4,5,6,7"
    [3]="8,9,10,11"
)

declare -A PORTS=(
    [1]="8001"
    [2]="8002"
    [3]="8003"
)

TRAEFIK_PORT=8000
MODEL="openai/gpt-oss-120b"

# --- PROXY SETTINGS ---
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128
export no_proxy=localhost,127.0.0.1

# --- TIMING START ---
JOB_START_TIME=$(date +%s)
echo "=============================================="
echo "EP + Traefik Benchmark"
echo "  Config: 3 instances × TP=4 × EP"
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

# --- 5. GENERATE TRAEFIK CONFIG ---
echo "Generating Traefik configuration..."

# Static config
cat > "$JOB_LOG_DIR/traefik_static.yaml" << EOF
entryPoints:
  web:
    address: ":${TRAEFIK_PORT}"

providers:
  file:
    filename: "$JOB_LOG_DIR/traefik_dynamic.yaml"
    watch: false

log:
  level: INFO
EOF

# Dynamic config (separate file)
cat > "$JOB_LOG_DIR/traefik_dynamic.yaml" << EOF
http:
  routers:
    vllm-router:
      rule: "PathPrefix(\`/\`)"
      service: vllm-service
      entryPoints:
        - web

  services:
    vllm-service:
      loadBalancer:
        healthCheck:
          path: /health
          interval: "10s"
          timeout: "5s"
        servers:
          - url: "http://localhost:8001"
          - url: "http://localhost:8002"
          - url: "http://localhost:8003"
EOF

# --- 6. START VLLM INSTANCES WITH EP ---
echo ""
echo "=============================================="
echo "Starting 3 vLLM Instances (TP=4 + EP each)"
echo "=============================================="

VLLM_PIDS=()

for i in 1 2 3; do
    GPU_MASK="${GPU_AFFINITY[$i]}"
    PORT="${PORTS[$i]}"
    
    echo "Starting Instance $i: Port $PORT, GPUs $GPU_MASK..."
    
    ZE_AFFINITY_MASK="$GPU_MASK" nohup vllm serve "$MODEL" \
        --tensor-parallel-size 4 \
        --enable-expert-parallel \
        --port "$PORT" \
        --disable-custom-all-reduce \
        --enforce-eager \
        --distributed-executor-backend mp \
        --dtype bfloat16 \
        --gpu-memory-utilization 0.90 \
        > "$JOB_LOG_DIR/vllm_${i}.log" 2>&1 &
    
    VLLM_PIDS+=($!)
    echo "  PID: ${VLLM_PIDS[-1]}"
    
    # Stagger startup
    sleep 5
done

# --- 7. WAIT FOR ALL INSTANCES ---
echo ""
echo "Waiting for all instances to be ready..."
MAX_WAIT=600
ELAPSED=0
INTERVAL=10

while [ $ELAPSED -lt $MAX_WAIT ]; do
    READY_COUNT=0
    for i in 1 2 3; do
        PORT="${PORTS[$i]}"
        if curl -s "http://localhost:$PORT/health" > /dev/null 2>&1; then
            READY_COUNT=$((READY_COUNT + 1))
        fi
    done
    
    if [ $READY_COUNT -eq 3 ]; then
        echo "All 3 instances ready after ${ELAPSED}s"
        break
    fi
    
    # Check for dead processes
    for idx in "${!VLLM_PIDS[@]}"; do
        if ! ps -p ${VLLM_PIDS[$idx]} > /dev/null 2>&1; then
            echo "ERROR: Instance $((idx+1)) died. Check logs."
            tail -50 "$JOB_LOG_DIR/vllm_$((idx+1)).log"
            exit 1
        fi
    done
    
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    echo "  Ready: $READY_COUNT/3 (${ELAPSED}s / ${MAX_WAIT}s)"
done

if [ $READY_COUNT -lt 3 ]; then
    echo "ERROR: Not all instances started. Ready: $READY_COUNT/3"
    exit 1
fi

# --- 8. START TRAEFIK ---
echo ""
echo "Starting Traefik load balancer on port $TRAEFIK_PORT..."

# Check if traefik is available, if not download
TRAEFIK_BIN="/tmp/traefik"
if [ ! -f "$TRAEFIK_BIN" ]; then
    echo "Downloading Traefik..."
    curl -sL https://github.com/traefik/traefik/releases/download/v3.0.0/traefik_v3.0.0_linux_amd64.tar.gz \
        | tar -xz -C /tmp traefik
fi

nohup "$TRAEFIK_BIN" --configFile="$JOB_LOG_DIR/traefik_static.yaml" \
    > "$JOB_LOG_DIR/traefik.log" 2>&1 &
TRAEFIK_PID=$!
echo "Traefik started (PID: $TRAEFIK_PID)"

sleep 5

# Verify Traefik
if ! curl -s "http://localhost:$TRAEFIK_PORT/health" > /dev/null 2>&1; then
    echo "WARNING: Traefik health check not passing, but continuing..."
fi

# --- 9. RUN BENCHMARK ---
echo ""
echo "=============================================="
echo "Running Throughput Benchmark"
echo "=============================================="

# Warmup
echo "Warmup request..."
curl -s -X POST "http://localhost:$TRAEFIK_PORT/v1/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"$MODEL\", \"prompt\": \"Hello\", \"max_tokens\": 10}" \
    --max-time 120 > /dev/null 2>&1
sleep 5

# Benchmark configuration
NUM_PROMPTS=1000
INPUT_LEN=3000
OUTPUT_LEN=1000

BENCH_START=$(date +%s)
echo "Running: $NUM_PROMPTS prompts, input=$INPUT_LEN, output=$OUTPUT_LEN"

vllm bench serve \
    --model "$MODEL" \
    --backend openai \
    --base-url "http://localhost:$TRAEFIK_PORT" \
    --dataset-name random \
    --seed 12345 \
    --num-prompts "$NUM_PROMPTS" \
    --random-input-len "$INPUT_LEN" \
    --random-output-len "$OUTPUT_LEN" \
    > "$JOB_LOG_DIR/benchmark.log" 2>&1

BENCH_END=$(date +%s)
BENCH_DURATION=$((BENCH_END - BENCH_START))

# --- 10. RESULTS ---
echo ""
echo "=============================================="
echo "BENCHMARK RESULTS"
echo "=============================================="

OUTPUT_THROUGHPUT=$(grep "Output token throughput" "$JOB_LOG_DIR/benchmark.log" | awk '{print $5}')
TOTAL_THROUGHPUT=$(grep "Total Token throughput" "$JOB_LOG_DIR/benchmark.log" | awk '{print $5}')
TTFT=$(grep "Mean TTFT" "$JOB_LOG_DIR/benchmark.log" | awk '{print $4}')

echo "Configuration: 3 × TP=4 × EP + Traefik"
echo "  Output Throughput: $OUTPUT_THROUGHPUT tok/s"
echo "  Total Throughput:  $TOTAL_THROUGHPUT tok/s"
echo "  Mean TTFT:         $TTFT ms"
echo "  Benchmark Duration: ${BENCH_DURATION}s"

# Save results
cat > "$JOB_LOG_DIR/results.txt" << EOF
Configuration: 3 instances × TP=4 × EP + Traefik
Output Throughput: $OUTPUT_THROUGHPUT tok/s
Total Throughput: $TOTAL_THROUGHPUT tok/s
Mean TTFT: $TTFT ms
Duration: ${BENCH_DURATION}s
EOF

# --- 11. CLEANUP ---
echo ""
echo "Cleaning up..."
kill $TRAEFIK_PID 2>/dev/null || true
for pid in "${VLLM_PIDS[@]}"; do
    kill $pid 2>/dev/null || true
done
wait 2>/dev/null || true

JOB_END_TIME=$(date +%s)
JOB_DURATION=$((JOB_END_TIME - JOB_START_TIME))

echo ""
echo "=============================================="
echo "Benchmark Complete"
echo "Total Duration: ${JOB_DURATION}s"
echo "Results: $JOB_LOG_DIR/results.txt"
echo "=============================================="
