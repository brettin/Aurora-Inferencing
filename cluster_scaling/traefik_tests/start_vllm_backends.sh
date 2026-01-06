#!/bin/bash

# This script is run on each compute node to start 6 vLLM backends (TP=2)
# Usage: start_vllm_backends.sh <log_dir>

set -e

# --- PROXY SETTINGS ---
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128
export no_proxy=localhost,127.0.0.1

# --- SETUP ENVIRONMENT ---
LOG_DIR="${1:-/tmp}"
mkdir -p "$LOG_DIR"

LOCAL_ENV="/tmp/vllm_env"

if [ -f "$LOCAL_ENV/bin/activate" ]; then
    source "$LOCAL_ENV/bin/activate"
else
    echo "ERROR: $LOCAL_ENV/bin/activate not found on $(hostname)"
    exit 1
fi

# --- ENVIRONMENT VARIABLES ---
# HF_HOME points to /tmp, so models are at /tmp/hub/models--openai--...
export HF_HOME="/tmp"
export TMPDIR="/tmp"
export ZE_FLAT_DEVICE_HIERARCHY=FLAT
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export FI_MR_CACHE_MONITOR=userfaultfd
export TORCH_COMPILE_DISABLE=1
export OMP_NUM_THREADS=12
export TORCH_XPU_ALLOC_CONF=expandable_segments:True

# Disable core dumps
ulimit -c 0

MODEL="openai/gpt-oss-120b"

echo "Starting 6 vLLM Backends (TP=2) on $(hostname)..."
echo "Logging to $LOG_DIR"

# Launch 6 backends with staggered starts to avoid resource contention
# Each backend uses 2 GPUs (TP=2)

declare -A GPU_PAIRS=(
    [1]="0,1"
    [2]="2,3"
    [3]="4,5"
    [4]="6,7"
    [5]="8,9"
    [6]="10,11"
)

declare -A PORTS=(
    [1]="8001"
    [2]="8002"
    [3]="8003"
    [4]="8004"
    [5]="8005"
    [6]="8006"
)

declare -A VLLM_PORTS=(
    [1]="12340"
    [2]="12341"
    [3]="12342"
    [4]="12343"
    [5]="12344"
    [6]="12345"
)

for i in {1..6}; do
    GPU_MASK="${GPU_PAIRS[$i]}"
    PORT="${PORTS[$i]}"
    VLLM_PORT="${VLLM_PORTS[$i]}"
    
    echo "Starting Backend $i (Port $PORT, GPUs $GPU_MASK)..."
    
    ZE_AFFINITY_MASK="$GPU_MASK" VLLM_PORT="$VLLM_PORT" nohup vllm serve "$MODEL" \
        --tensor-parallel-size 2 \
        --port "$PORT" \
        --disable-custom-all-reduce \
        --enforce-eager \
        --distributed-executor-backend mp \
        --dtype bfloat16 \
        --gpu-memory-utilization 0.90 \
        > "$LOG_DIR/vllm_${i}.log" 2>&1 &
    
    echo "Backend $i started (PID: $!)"
    
    # Stagger startup to reduce contention
    if [ $i -lt 6 ]; then
        sleep 10
    fi
done

echo "All 6 backends launched on $(hostname)"
