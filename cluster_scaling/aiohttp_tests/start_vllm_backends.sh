#!/bin/bash

# This script is intended to be run on each compute node.
# It handles:
# 1. Activating the environment (assumed to be at /tmp/vllm_env)
# 2. Setting necessary environment variables
# 3. Launching 6 vLLM backends (TP=2) for the local GPU tiles

# --- PROXY SETTINGS ---
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128
export no_proxy=localhost,127.0.0.1

# --- 1. SETUP ENVIRONMENT ---
LOG_DIR="${1:-/tmp}"
mkdir -p "$LOG_DIR"

if [ -f "/tmp/vllm_env/bin/activate" ]; then
    source /tmp/vllm_env/bin/activate
else
    echo "ERROR: /tmp/vllm_env/bin/activate not found on $(hostname)"
    exit 1
fi

if [ -z "${HF_TOKEN:-}" ]; then
    echo "Error: HF_TOKEN not set."
    exit 1
fi

export HF_HOME="/tmp"
export RAY_TMPDIR="/tmp"
export TMPDIR="/tmp"

# --- CONFIGURATION FIXES ---
export ZE_FLAT_DEVICE_HIERARCHY=FLAT
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export FI_MR_CACHE_MONITOR=userfaultfd
export TORCH_COMPILE_DISABLE=1

# THREAD TUNING:
# 6 Servers * 12 Threads = 72 Threads (Server Load)
# 6 Clients * 4 Threads = 24 Threads (Client Load) -- Note: Clients are on head node, but this is safe default
# Total = 96 Threads (Safe for 104-core node)
export OMP_NUM_THREADS=12
export TORCH_XPU_ALLOC_CONF=expandable_segments:True

# We use the same model path as proxy_bench_tp2.sh
MODEL="openai/gpt-oss-120b"
# The weights are assumed to be in /tmp/hub (mapped by vllm or HF_HOME)
# Actually, if HF_HOME is /tmp, and we copied to /tmp/hub, we need to ensure vLLM finds it.
# In proxy_bench_tp2.sh, it just sets HF_HOME=/tmp and runs model "openai/gpt-oss-120b".
# This assumes the structure in /tmp matches what HF expects or vLLM uses cached weights.

echo "Starting 6 vLLM Backends (TP=2) on $(hostname)..."
echo "Logging to $LOG_DIR"

# Logs will go to $LOG_DIR/vllm_[1-6].log on the local node.

# --- BACKEND 1 (GPUs 0,1) ---
ZE_AFFINITY_MASK=0,1 VLLM_PORT=12340 nohup vllm serve $MODEL \
    --tensor-parallel-size 2 --port 8001 --disable-custom-all-reduce --enforce-eager \
    --distributed-executor-backend mp --dtype bfloat16 > "$LOG_DIR/vllm_1.log" 2>&1 &
echo "Backend 1 (Port 8001) started."
sleep 10


# --- BACKEND 2 (GPUs 2,3) ---
ZE_AFFINITY_MASK=2,3 VLLM_PORT=12341 nohup vllm serve $MODEL \
    --tensor-parallel-size 2 --port 8002 --disable-custom-all-reduce --enforce-eager \
    --distributed-executor-backend mp --dtype bfloat16 > "$LOG_DIR/vllm_2.log" 2>&1 &
echo "Backend 2 (Port 8002) started."
sleep 10


# --- BACKEND 3 (GPUs 4,5) ---
ZE_AFFINITY_MASK=4,5 VLLM_PORT=12342 nohup vllm serve $MODEL \
    --tensor-parallel-size 2 --port 8003 --disable-custom-all-reduce --enforce-eager \
    --distributed-executor-backend mp --dtype bfloat16 > "$LOG_DIR/vllm_3.log" 2>&1 &
echo "Backend 3 (Port 8003) started."
sleep 10


# --- BACKEND 4 (GPUs 6,7) ---
ZE_AFFINITY_MASK=6,7 VLLM_PORT=12343 nohup vllm serve $MODEL \
    --tensor-parallel-size 2 --port 8004 --disable-custom-all-reduce --enforce-eager \
    --distributed-executor-backend mp --dtype bfloat16 > "$LOG_DIR/vllm_4.log" 2>&1 &
echo "Backend 4 (Port 8004) started."
sleep 10


# --- BACKEND 5 (GPUs 8,9) ---
ZE_AFFINITY_MASK=8,9 VLLM_PORT=12344 nohup vllm serve $MODEL \
    --tensor-parallel-size 2 --port 8005 --disable-custom-all-reduce --enforce-eager \
    --distributed-executor-backend mp --dtype bfloat16 > "$LOG_DIR/vllm_5.log" 2>&1 &
echo "Backend 5 (Port 8005) started."
sleep 10


# --- BACKEND 6 (GPUs 10,11) ---
ZE_AFFINITY_MASK=10,11 VLLM_PORT=12345 nohup vllm serve $MODEL \
    --tensor-parallel-size 2 --port 8006 --disable-custom-all-reduce --enforce-eager \
    --distributed-executor-backend mp --dtype bfloat16 > "$LOG_DIR/vllm_6.log" 2>&1 &
echo "Backend 6 (Port 8006) started."
