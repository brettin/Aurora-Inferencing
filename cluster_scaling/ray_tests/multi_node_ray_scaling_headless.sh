#!/bin/bash
#PBS -N vllm_ray_scaling
#PBS -l walltime=00:10:00
#PBS -A candle_aesp_CNDA
#PBS -q prod
#PBS -o output_ray_scaling.log
#PBS -e error_ray_scaling.log
#PBS -l select=3
#PBS -l filesystems=flare:home
#PBS -l place=scatter

# --- CONFIGURATION ---
DATE_TAG=$(date +%Y%m%d_%H%M%S)
cd "$PBS_O_WORKDIR" || exit 1

SCRIPT_DIR=$(pwd)
JOB_ID_CLEAN=$(echo "$PBS_JOBID" | cut -d. -f1)
NUM_NODES=$(sort -u "$PBS_NODEFILE" | wc -l)
JOB_LOG_DIR="$SCRIPT_DIR/logs/${JOB_ID_CLEAN}_${NUM_NODES}nodes"
mkdir -p "$JOB_LOG_DIR"

exec > >(tee -a "$JOB_LOG_DIR/master_run.log") 2>&1

# Paths
MODEL_SOURCE="/flare/AuroraGPT/model-weights/optimized_model/hub" 
MODEL_DEST="/tmp"
LOCAL_ENV="/tmp/vllm_env"
ENV_TAR="/flare/AuroraGPT/ngetty/envs/packed_envs/vllm_serve_env.tar.gz"

# CPTOTMP Tool Config
CPTOTMP_SRC="$SCRIPT_DIR/../cptotmp.c"
CPTOTMP_BIN="$SCRIPT_DIR/../cptotmp_bin"

# --- PROXY SETTINGS ---
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128
export no_proxy=localhost,127.0.0.1

echo "---------------------------------------------------"
echo "Job ID: $PBS_JOBID | Nodes: $NUM_NODES"
echo "Head Node: $(hostname)"
echo "---------------------------------------------------"

# --- 0. PREPARE HOSTS & NO_PROXY ---
# Calculate HSN IP for the head node (Critical for Aurora)
HSN_IP_ADDRESS=$(getent hosts "$(hostname).hsn.cm.aurora.alcf.anl.gov" | awk '{ print $1 }' | sort | head -n 1)
export RAY_HEAD_IP="$HSN_IP_ADDRESS"

HEAD_NODE=$(hostname)
sort -u "$PBS_NODEFILE" > hosts.txt
mapfile -t ALL_HOSTS < hosts.txt

WORKER_NODES=()
for host in "${ALL_HOSTS[@]}"; do
    if [[ "$host" == *"$HEAD_NODE"* ]]; then continue; fi
    WORKER_NODES+=("$host")
done

# Resolve IPs for no_proxy to avoid going through corporate proxy for internal comms
> ips.txt
for host in "${ALL_HOSTS[@]}"; do
    getent hosts "$host" | awk '{print $1}' | head -n 1 >> ips.txt
    # Also add HSN IPs
    getent hosts "${host}.hsn.cm.aurora.alcf.anl.gov" | awk '{print $1}' | head -n 1 >> ips.txt
done

HOST_LIST=$(paste -sd, hosts.txt)
IP_LIST=$(paste -sd, ips.txt)
export no_proxy="$no_proxy,$HOST_LIST,$IP_LIST"
echo "Calculated no_proxy: $no_proxy"
echo "Head Node HSN IP: $RAY_HEAD_IP"

# --- 1. COMPILE & STAGE FILES ---
if ! command -v mpicc &> /dev/null; then module load frameworks; fi
if [ ! -f "$CPTOTMP_BIN" ]; then
    echo "Compiling copy tool..."
    mpicc -o "$CPTOTMP_BIN" "$CPTOTMP_SRC"
fi

# Optimized Network Vars for Copying
export MPIR_CVAR_CH4_OFI_ENABLE_MULTI_NIC_STRIPING=1
export MPIR_CVAR_CH4_OFI_MAX_NICS=4

echo "Staging Model Weights to $MODEL_DEST..."
mpiexec -ppn 1 --cpu-bind numa "$CPTOTMP_BIN" "$MODEL_SOURCE" "$MODEL_DEST"

echo "Staging Environment..."
mpiexec -ppn 1 --cpu-bind numa "$CPTOTMP_BIN" "$ENV_TAR" "/tmp"

echo "Unpacking Environment..."
mpiexec -np "$NUM_NODES" -ppn 1 bash -c "
    mkdir -p /tmp/vllm_env
    if [ ! -f /tmp/vllm_env/bin/activate ]; then
        if [ -f /tmp/vllm_serve_env.tar.gz ]; then
            tar -xf /tmp/vllm_serve_env.tar.gz -C /tmp/vllm_env
            source /tmp/vllm_env/bin/activate && conda-unpack
        fi
    fi
"

# --- 2. START RAY CLUSTER ---
RAY_PORT=6379

RAY_ENV_VARS="
export TMPDIR=/tmp
export RAY_TMPDIR=/tmp
export HF_HOME=/tmp
export RAY_EXPERIMENTAL_NOSET_CUDA_VISIBLE_DEVICES=1
export ZE_FLAT_DEVICE_HIERARCHY=FLAT
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export TORCH_COMPILE_DISABLE=1
export OMP_NUM_THREADS=12
export RAYON_NUM_THREADS=4
export MKL_NUM_THREADS=4
export TORCH_LLM_ALLREDUCE=1
export CCL_ZE_IPC_EXCHANGE=drmfd
export VLLM_IMAGE_FETCH_TIMEOUT=60
export TORCH_XPU_ALLOC_CONF=expandable_segments:True
export RAY_SERVE_QUEUE_LENGTH_RESPONSE_DEADLINE_S=1
export RAY_SERVE_HTTP_PROXY_CALLBACKS_ENABLED=0
"

# Cleanup
echo "Cleaning up previous processes..."
mpiexec -np "$NUM_NODES" -ppn 1 bash -c "pkill -9 -u $USER ray; pkill -9 -u $USER vllm; pkill -9 -u $USER python" 2>/dev/null

source "$LOCAL_ENV/bin/activate"

# Start Head
ulimit -c 0        # Disable core dumps
ulimit -n 65536
ulimit -u 65536
eval "$RAY_ENV_VARS"
export VLLM_HOST_IP="$HSN_IP_ADDRESS"

echo "Starting Ray Head on $HSN_IP_ADDRESS..."
ray start --head --node-ip-address="$HSN_IP_ADDRESS" --port=$RAY_PORT \
    --num-gpus=0 --num-cpus=96 --include-dashboard=true --block > "$JOB_LOG_DIR/ray_head.log" 2>&1 &
sleep 15

# Start Workers
for worker in "${WORKER_NODES[@]}"; do
    echo "Starting Ray Worker on $worker..."
    ssh "$worker" "bash -l -c '
        source \"$LOCAL_ENV/bin/activate\"
        export PATH=\"$LOCAL_ENV/bin:\$PATH\"
        export HTTP_PROXY=\"$HTTP_PROXY\"
        export HTTPS_PROXY=\"$HTTPS_PROXY\"
        export no_proxy=\"$no_proxy\"
        
        # Calculate HSN IP for this worker
        WORKER_HSN=\$(getent hosts \"\$(hostname).hsn.cm.aurora.alcf.anl.gov\" | awk \"{ print \\\$1 }\" | sort | head -n 1)
        export VLLM_HOST_IP=\"\$WORKER_HSN\"
        
        # Force limits inside SSH session
        ulimit -c 0
        ulimit -n 65536
        ulimit -u 65536
        
        $RAY_ENV_VARS
        
        ray start --address=\"$RAY_HEAD_IP:$RAY_PORT\" \
            --node-ip-address=\"\$WORKER_HSN\" \
            --num-gpus=12 \
            --num-cpus=96 \
            --resources=\"{\\\"node:${worker}\\\": 100}\" \
            --block
    '" > "$JOB_LOG_DIR/ray_${worker}.log" 2>&1 &
done

echo "Waiting 30s for cluster stabilization..."
sleep 30
ray status

# --- 3. DEPLOY SERVE (HEADLESS) ---
echo "Deploying vLLM Service..."

# CRITICAL FIX: Isolate Driver from GPUs and restrict threads to prevent Head Node exhaustion.
# The driver only coordinates; it needs no GPU access and minimal threads.
# Hiding GPUs prevents PyTorch/IPEX from initializing 12 heavy contexts on import.
(
    export OMP_NUM_THREADS=1
    export MKL_NUM_THREADS=1
    export ZE_AFFINITY_MASK="" 
    python -u ray_serve_vllm_headless.py
) > "$JOB_LOG_DIR/serve_deployment.log" 2>&1 &
SERVE_PID=$!

echo "Waiting for Health Check..."
MAX_WAIT=900
START_TIME=$(date +%s)
COUNT=0

while true; do
    # Try local proxy
    if curl -s http://127.0.0.1:8000/v1/health | grep -q "ok"; then
        echo "Head Node Proxy is UP and Healthy."
        break
    fi
    
    # Check if driver died
    if ! ps -p $SERVE_PID > /dev/null; then
        echo "CRITICAL: Deployment script died."
        cat "$JOB_LOG_DIR/serve_deployment.log"
        exit 1
    fi

    CURRENT_TIME=$(date +%s)
    if (( CURRENT_TIME - START_TIME > MAX_WAIT )); then
        echo "TIMEOUT: Cluster failed to initialize."
        exit 1
    fi
    
    echo "Waiting for service... (${COUNT}s)"
    sleep 10
    COUNT=$((COUNT+10))
done

echo "Cluster Service is READY."

# --- 4. BENCHMARK ---
CLIENTS_PER_NODE=12 
PROMPTS=200

for worker in "${WORKER_NODES[@]}"; do
    echo "Triggering Benchmark on $worker..."
    ssh "$worker" "bash -l -c '
        source \"$LOCAL_ENV/bin/activate\"
        export no_proxy=\"$no_proxy\"
        export HF_HOME=/tmp
        
        BENCH_MODEL=\"openai/gpt-oss-120b\"
        
        echo \"Benchmarking using model name: \$BENCH_MODEL (expecting local /tmp cache)\"
        
        vllm bench serve --model \"\$BENCH_MODEL\" \
            --backend openai \
            --base-url \"http://127.0.0.1:8000/v1\" \
            --dataset-name random \
            --num-prompts $((CLIENTS_PER_NODE * PROMPTS)) \
            --random-input-len 1024 \
            --random-output-len 1024 \
            --trust-remote-code
    '" > "$JOB_LOG_DIR/bench_${worker}.log" 2>&1 &
done

wait
echo "Benchmarks Completed."
grep "Throughput" "$JOB_LOG_DIR"/bench_*.log

# Cleanup
kill $SERVE_PID 2>/dev/null
ray stop --force
for worker in "${WORKER_NODES[@]}"; do
    ssh "$worker" "ray stop --force"
done