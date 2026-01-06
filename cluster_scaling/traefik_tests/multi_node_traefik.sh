#!/bin/bash
#PBS -N vllm_traefik_bench
#PBS -l walltime=00:25:00
#PBS -A candle_aesp_CNDA
#PBS -q prod
#PBS -o output_traefik.log
#PBS -e error_traefik.log
#PBS -l select=16
#PBS -l filesystems=flare:home
#PBS -l place=scatter

# ============================================================================
# Multi-Node vLLM + Traefik Load Balancer
# ============================================================================
# This script:
# 1. Stages model weights and vLLM environment to all nodes
# 2. Launches 6 vLLM backends per node (TP=2, 12 GPUs each)
# 3. Starts Traefik as a load balancer with health checks
# 4. Runs benchmark against the single Traefik endpoint
# ============================================================================

set -e

# --- CONFIGURATION ---
if [ -n "$PBS_O_WORKDIR" ]; then
    cd "$PBS_O_WORKDIR" || exit 1
fi

SCRIPT_DIR=$(pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")  # cluster_scaling directory
JOB_ID_CLEAN=$(echo "$PBS_JOBID" | cut -d. -f1)
NUM_NODES=$(sort -u "$PBS_NODEFILE" | wc -l)
JOB_LOG_DIR="$SCRIPT_DIR/logs/${JOB_ID_CLEAN}_${NUM_NODES}nodes"
mkdir -p "$JOB_LOG_DIR"

# Redirect stdout/stderr to log
exec > >(tee -a "$JOB_LOG_DIR/master_run.log") 2>&1

# Paths
CPTOTMP_SRC="$ROOT_DIR/cptotmp.c"
CPTOTMP_BIN="$ROOT_DIR/cptotmp_bin"
# Copy only the specific model, not the entire hub
MODEL_HUB_SOURCE="/flare/AuroraGPT/model-weights/optimized_model/hub"
MODEL_NAME="models--openai--gpt-oss-120b"
MODEL_SOURCE="$MODEL_HUB_SOURCE/$MODEL_NAME"
MODEL_DEST="/tmp/hub"  # Will be /tmp/hub/models--openai--gpt-oss-120b
ENV_TAR="/flare/AuroraGPT/ngetty/envs/packed_envs/vllm_serve_env.tar.gz"
LOCAL_ENV="/tmp/vllm_env"
TRAEFIK_BIN="$HOME/traefik/bin/traefik"

# Expected file for verification (tokenizer is critical)
VERIFY_FILE="$MODEL_DEST/$MODEL_NAME/snapshots/*/tokenizer.json"


# --- PROXY SETTINGS ---
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128
export no_proxy=localhost,127.0.0.1

# --- TIMING START ---
JOB_START_TIME=$(date +%s)
JOB_START_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "=============================================="
echo "Job ID: $PBS_JOBID | Nodes: $NUM_NODES"
echo "Head Node: $(hostname)"
echo "Traefik: $TRAEFIK_BIN"
echo "Start Time: $JOB_START_TIMESTAMP"
echo "=============================================="

# --- 0. PREPARE HOSTS & NO_PROXY ---
HEAD_NODE=$(hostname)
sort -u "$PBS_NODEFILE" > "$JOB_LOG_DIR/hosts.txt"
mapfile -t ALL_HOSTS < "$JOB_LOG_DIR/hosts.txt"

# Add all hosts to no_proxy
HOST_LIST=$(paste -sd, "$JOB_LOG_DIR/hosts.txt")
export no_proxy="$no_proxy,$HOST_LIST"
echo "Updated no_proxy: $no_proxy"

# --- 1. COMPILE COPY TOOL ---
if ! command -v mpicc &> /dev/null; then module load frameworks; fi
if [ ! -f "$CPTOTMP_BIN" ]; then
    echo "Compiling cptotmp..."
    mpicc -o "$CPTOTMP_BIN" "$CPTOTMP_SRC"
fi

# --- 2. STAGE FILES ---
echo "Staging Model Weights (only $MODEL_NAME) to $MODEL_DEST on all nodes..."
export MPIR_CVAR_CH4_OFI_ENABLE_MULTI_NIC_STRIPING=1
export MPIR_CVAR_CH4_OFI_MAX_NICS=4

# Create dest directory and copy specific model
mpiexec -np "$NUM_NODES" -ppn 1 bash -c "mkdir -p '$MODEL_DEST'"
mpiexec -ppn 1 --cpu-bind numa "$CPTOTMP_BIN" "$MODEL_SOURCE" "$MODEL_DEST"

echo "Staging Environment..."
mpiexec -ppn 1 --cpu-bind numa "$CPTOTMP_BIN" "$ENV_TAR" "/tmp"

# --- 2b. VERIFY STAGING ---
echo "Verifying staging on all nodes..."
STAGING_FAILED=0
for host in "${ALL_HOSTS[@]}"; do
    # Check if tokenizer.json exists and is not empty
    if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$host" \
        "ls $MODEL_DEST/$MODEL_NAME/snapshots/*/tokenizer.json >/dev/null 2>&1 && \
         [ -s \"\$(ls $MODEL_DEST/$MODEL_NAME/snapshots/*/tokenizer.json | head -1)\" ]"; then
        echo "ERROR: Staging verification FAILED on $host - tokenizer.json missing or empty"
        STAGING_FAILED=1
    else
        echo "  $host: staging verified"
    fi
done

if [ $STAGING_FAILED -eq 1 ]; then
    echo "WARNING: Staging verification failed on one or more nodes. Continuing anyway..."
else
    echo "Staging verification complete - all nodes OK"
fi

# --- 3. UNPACK ENV ---
TAR_NAME=$(basename "$ENV_TAR")
echo "Unpacking Environment on all nodes..."
mpiexec -np "$NUM_NODES" -ppn 1 bash -c "
    if [ ! -f '$LOCAL_ENV/bin/activate' ]; then
        echo \"Unpacking on \$(hostname)...\"
        mkdir -p '$LOCAL_ENV'
        tar -xf '/tmp/$TAR_NAME' -C '$LOCAL_ENV' && \
        source '$LOCAL_ENV/bin/activate' && \
        conda-unpack
    else
        echo \"Environment ready on \$(hostname).\"
    fi
"

# --- 4. START VLLM BACKENDS ON ALL NODES ---
echo "Starting vLLM backends on all nodes..."
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
BACKEND_SCRIPT="$SCRIPT_DIR/start_vllm_backends.sh"

for host in "${ALL_HOSTS[@]}"; do
    HOST_LOG_DIR="$JOB_LOG_DIR/${host}"
    mkdir -p "$HOST_LOG_DIR"
    echo "Launching backends on $host..."
    ssh $SSH_OPTS "$host" "bash -l '$BACKEND_SCRIPT' '$HOST_LOG_DIR'" > "$HOST_LOG_DIR/launch.log" 2>&1 &
done

echo "Waiting 300s for backends to initialize (model loading takes ~4 min)..."
sleep 300

# --- 5. GENERATE TRAEFIK DYNAMIC CONFIG ---
echo "Generating Traefik dynamic configuration..."
"$SCRIPT_DIR/generate_traefik_config.sh" /tmp/traefik_dynamic.yaml

# Copy static config to /tmp
cp "$SCRIPT_DIR/traefik.yaml" /tmp/traefik_static.yaml

# --- 6. START TRAEFIK EARLY ---
# Start Traefik now so we can use its API to check backend health
# CRITICAL: Set high ulimits to prevent thread exhaustion
ulimit -u 131072 2>/dev/null || echo "Could not set ulimit -u"
ulimit -n 65536 2>/dev/null || echo "Could not set ulimit -n"
ulimit -c 0  # Disable core dumps

echo "Starting Traefik load balancer..."
GOMAXPROCS=4 "$TRAEFIK_BIN" --configfile /tmp/traefik_static.yaml > "$JOB_LOG_DIR/traefik.log" 2>&1 &
TRAEFIK_PID=$!
sleep 5

# Verify Traefik is running
if ! ps -p $TRAEFIK_PID > /dev/null; then
    echo "CRITICAL: Traefik failed to start"
    cat "$JOB_LOG_DIR/traefik.log"
    exit 1
fi
echo "Traefik started (PID: $TRAEFIK_PID)"

# --- 7. WAIT FOR BACKENDS VIA TRAEFIK API ---
source "$LOCAL_ENV/bin/activate"
TOTAL_BACKENDS=$((NUM_NODES * 6))
MAX_WAIT=600  # 10 min

echo "Waiting for backends to become healthy via Traefik API..."
python3 "$SCRIPT_DIR/wait_for_backends.py" "$TOTAL_BACKENDS" "$MAX_WAIT" 95

# --- 7b. RESTART FAILED BACKENDS ---
echo "Checking for failed backends and attempting restart..."
python3 "$SCRIPT_DIR/restart_failed_backends.py" "$JOB_LOG_DIR/hosts.txt" "$SCRIPT_DIR/start_vllm_backends.sh" "$JOB_LOG_DIR"

# Quick re-check after restarts
sleep 10
python3 -c "
import json
from urllib.request import urlopen
try:
    data = json.loads(urlopen('http://localhost:8080/api/http/services', timeout=5).read())
    for svc in data:
        if 'vllm-backends' in svc.get('name', ''):
            status = svc.get('serverStatus', {})
            up = sum(1 for s in status.values() if s == 'UP')
            print(f'Final backend status: {up}/{len(status)} healthy')
except: pass
"

# --- TIMING: CLUSTER READY ---
CLUSTER_READY_TIME=$(date +%s)
CLUSTER_STARTUP_DURATION=$((CLUSTER_READY_TIME - JOB_START_TIME))
echo "Backend health check complete."
echo ">>> CLUSTER STARTUP TIME: ${CLUSTER_STARTUP_DURATION}s <<<"

# --- 8. START MONITORS ---
echo "Starting health monitor..."
python3 "$SCRIPT_DIR/health_monitor.py" "$JOB_LOG_DIR/health_summary.txt" 10 &
HEALTH_MONITOR_PID=$!
echo "Health monitor started (PID: $HEALTH_MONITOR_PID)"

echo "Starting resource monitor..."
python3 "$SCRIPT_DIR/resource_monitor.py" "$JOB_LOG_DIR/resource_summary.txt" 5 &
RESOURCE_MONITOR_PID=$!
echo "Resource monitor started (PID: $RESOURCE_MONITOR_PID)"

# --- 8b. WARMUP BACKENDS ---
# Send a warmup request to trigger any remaining JIT compilation
echo "Warming up backends (sending test requests via Traefik)..."
WARMUP_PAYLOAD='{"model": "openai/gpt-oss-120b", "prompt": "Hello", "max_tokens": 5}'
for i in $(seq 1 $TOTAL_BACKENDS); do
    curl -s -X POST "http://localhost:8000/v1/completions" \
        -H "Content-Type: application/json" \
        -d "$WARMUP_PAYLOAD" \
        --max-time 120 > /dev/null 2>&1 &
done
echo "Waiting for warmup requests to complete (max 120s)..."
wait
echo "Warmup complete."

# --- 9. RUN BENCHMARK ---
# --- TIMING: BENCHMARK START ---
BENCHMARK_START_TIME=$(date +%s)
echo "Running Benchmark..."
PROXY_URL="http://localhost:8000"
PROMPTS_PER_CLIENT=3200
INPUT_LEN=3024
OUTPUT_LEN=1024
MODEL="openai/gpt-oss-120b"
NUM_CLIENTS=12
REQUEST_RATE=200  # Requests per second per client to avoid overwhelming backends

for i in $(seq 1 $NUM_CLIENTS); do
    vllm bench serve --model "$MODEL" --backend openai --base-url "$PROXY_URL" \
        --dataset-name random --seed 12345 --num-prompts "$PROMPTS_PER_CLIENT" \
        --random-input-len "$INPUT_LEN" --random-output-len "$OUTPUT_LEN" \
        --request-rate "$REQUEST_RATE" \
        > "$JOB_LOG_DIR/bench_${i}.log" 2>&1 &
    PIDS[${i}]=$!
done

echo "Waiting for $NUM_CLIENTS benchmark clients to complete..."
wait "${PIDS[@]}"

# --- TIMING: BENCHMARK END ---
BENCHMARK_END_TIME=$(date +%s)
BENCHMARK_DURATION=$((BENCHMARK_END_TIME - BENCHMARK_START_TIME))
echo ">>> BENCHMARK DURATION: ${BENCHMARK_DURATION}s <<<"

# --- 10. AGGREGATE RESULTS ---
echo "=========================================="
echo "TRAEFIK BENCHMARK RESULTS (Multi-Node)"
echo "=========================================="
for i in $(seq 1 $NUM_CLIENTS); do
    echo "--- Client $i ---"
    grep "Output token throughput" "$JOB_LOG_DIR/bench_${i}.log" || echo "No results"
    grep "Total Token throughput" "$JOB_LOG_DIR/bench_${i}.log" || echo ""
done
echo "------------------------------------------"

awk '
    /Output token throughput/ { output_sum += $5 }
    /Total Token throughput/ { total_sum += $5 }
    END {
        printf "==========================================\n"
        printf "AGGREGATED METRICS:\n"
        printf "Total Output Token Throughput: %.2f tok/s\n", output_sum
        printf "Total Total Token Throughput:  %.2f tok/s\n", total_sum
        printf "==========================================\n"
    }
' "$JOB_LOG_DIR"/bench_*.log

# --- 10. STOP MONITORS & SHOW SUMMARIES ---
echo "Stopping monitors..."
kill -TERM $HEALTH_MONITOR_PID 2>/dev/null
kill -TERM $RESOURCE_MONITOR_PID 2>/dev/null
wait $HEALTH_MONITOR_PID 2>/dev/null || true
wait $RESOURCE_MONITOR_PID 2>/dev/null || true

# Display health summary
if [ -f "$JOB_LOG_DIR/health_summary.txt" ]; then
    echo ""
    cat "$JOB_LOG_DIR/health_summary.txt"
fi

# Display resource summary
if [ -f "$JOB_LOG_DIR/resource_summary.txt" ]; then
    echo ""
    cat "$JOB_LOG_DIR/resource_summary.txt"
fi

# --- 11. CLEANUP ---
echo "Cleaning up..."
kill $TRAEFIK_PID 2>/dev/null

for host in "${ALL_HOSTS[@]}"; do
    ssh $SSH_OPTS "$host" "pkill -f 'vllm serve'" 2>/dev/null || true
done

# --- TIMING: JOB END ---
JOB_END_TIME=$(date +%s)
JOB_TOTAL_DURATION=$((JOB_END_TIME - JOB_START_TIME))

echo ""
echo "==========================================" 
echo "TIMING SUMMARY"
echo "==========================================" 
echo "Job Start:         $JOB_START_TIMESTAMP"
echo "Job End:           $(date '+%Y-%m-%d %H:%M:%S')"
echo "------------------------------------------"
echo "Cluster Startup:   ${CLUSTER_STARTUP_DURATION}s"
echo "Benchmark Duration: ${BENCHMARK_DURATION}s"
echo "Total Job Time:    ${JOB_TOTAL_DURATION}s"
echo "==========================================" 

echo "Done."
