#!/bin/bash
#PBS -N vllm_ray_scaling
#PBS -l walltime=00:20:00
#PBS -A candle_aesp_CNDA
#PBS -q prod
#PBS -o output_ray_scaling.log
#PBS -e error_ray_scaling.log
#PBS -l select=8
#PBS -l filesystems=flare:home
#PBS -l place=scatter

# --- CONFIGURATION ---
DATE_TAG=$(date +%Y%m%d_%H%M%S)
if [ -n "$PBS_O_WORKDIR" ]; then
    cd "$PBS_O_WORKDIR" || exit 1
fi

SCRIPT_DIR=$(pwd)
# Create specific log directory for this run IMMEDIATELY
JOB_ID_CLEAN=$(echo "$PBS_JOBID" | cut -d. -f1)
NUM_NODES=$(sort -u "$PBS_NODEFILE" | wc -l)
JOB_LOG_DIR="$SCRIPT_DIR/logs/${JOB_ID_CLEAN}_${NUM_NODES}nodes"
mkdir -p "$JOB_LOG_DIR"
echo "Job Logs will be written to: $JOB_LOG_DIR"

# Redirect stdout/stderr to a file in the log dir while keeping console output
exec > >(tee -a "$JOB_LOG_DIR/run_output.log") 2>&1
CPTOTMP_SRC="$SCRIPT_DIR/../cptotmp.c"
CPTOTMP_BIN="$SCRIPT_DIR/../cptotmp_bin"

# Model and Env Paths
MODEL_SOURCE="/flare/AuroraGPT/model-weights/optimized_model/hub" 
MODEL_DEST="/tmp"
ENV_TAR="/flare/AuroraGPT/ngetty/envs/packed_envs/vllm_serve_env.tar.gz"
ENV_STAGE_DIR="/tmp"
LOCAL_ENV="/tmp/vllm_env"

# --- PROXY SETTINGS (Matches your working script) ---
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128
# We start with basic no_proxy, will append workers later
export no_proxy=localhost,127.0.0.1

echo "---------------------------------------------------"
echo "Job ID: $PBS_JOBID"
echo "Head Node: $(hostname)"
echo "---------------------------------------------------"

# --- 0. PREPARE HOSTS & NO_PROXY ---
HEAD_NODE=$(hostname)
sort -u "$PBS_NODEFILE" > hosts.txt
mapfile -t ALL_HOSTS < hosts.txt

WORKER_NODES=()
for host in "${ALL_HOSTS[@]}"; do
    if [[ "$host" == *"$HEAD_NODE"* ]]; then continue; fi
    WORKER_NODES+=("$host")
done

# CRITICAL: Ray needs all nodes in no_proxy to communicate efficiently
HOST_LIST=$(paste -sd, hosts.txt)
export no_proxy="$no_proxy,$HOST_LIST"
echo "Updated no_proxy: $no_proxy"

# --- 1. COMPILE COPY TOOL ---
if ! command -v mpicc &> /dev/null; then module load frameworks; fi
if [ ! -f "$CPTOTMP_BIN" ]; then
    echo "Compiling cptotmp..."
    mpicc -o "$CPTOTMP_BIN" "$CPTOTMP_SRC"
fi

# --- 2. STAGE FILES ---
echo "Staging Model Weights..."
export MPIR_CVAR_CH4_OFI_ENABLE_MULTI_NIC_STRIPING=1
export MPIR_CVAR_CH4_OFI_MAX_NICS=4

mpiexec -ppn 1 --cpu-bind numa "$CPTOTMP_BIN" "$MODEL_SOURCE" "$MODEL_DEST" || { echo "Model staging failed"; exit 1; }

echo "Staging Environment..."
mpiexec -ppn 1 --cpu-bind numa "$CPTOTMP_BIN" "$ENV_TAR" "$ENV_STAGE_DIR" || { echo "Env staging failed"; exit 1; }

# --- 3. UNPACK ENV ---
TAR_NAME=$(basename "$ENV_TAR")
mpiexec -ppn 1 bash -c "
    if [ ! -f '$LOCAL_ENV/bin/activate' ]; then
        echo \"Unpacking on \$(hostname)...\"
        mkdir -p '$LOCAL_ENV'
        tar -xf '$ENV_STAGE_DIR/$TAR_NAME' -C '$LOCAL_ENV' && \
        source '$LOCAL_ENV/bin/activate' && \
        conda-unpack
    fi
"

# --- 4. START RAY CLUSTER ---
HEAD_NODE_IP=$(getent hosts "$HEAD_NODE" | awk '{print $1}' | head -n 1)
RAY_PORT=6379

# Environment Vars for Ray
# REMOVED: HF_HUB_OFFLINE=1
# ADDED: HF_HOME=/tmp (Explicitly passed)
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
# Ray Serve Tuning for High Throughput
export RAY_SERVE_QUEUE_LENGTH_RESPONSE_DEADLINE_S=1
export RAY_SERVE_HTTP_PROXY_CALLBACKS_ENABLED=0
"

# Start Head
source "$LOCAL_ENV/bin/activate"
export PATH="$LOCAL_ENV/bin:$PATH"

ulimit -n 65536
ulimit -s 4096
ulimit -c 0

eval "$RAY_ENV_VARS"
ray stop --force

echo "Starting Ray Head on $HEAD_NODE_IP..."
# Note: Ray Head inherits current shell's proxies
ray start --head --node-ip-address="$HEAD_NODE_IP" --port=$RAY_PORT \
    --num-gpus=0 --num-cpus=96 --include-dashboard=false --block > /tmp/ray_head.log 2>&1 &
RAY_HEAD_PID=$!
sleep 10

# Start Workers
for worker in "${WORKER_NODES[@]}"; do
    echo "Starting Ray Worker on $worker..."
    # We pass the proxies explicitly to the worker via SSH
    ssh "$worker" "bash -l -c '
        source \"$LOCAL_ENV/bin/activate\"
        export PATH=\"$LOCAL_ENV/bin:\$PATH\"
        
        # INJECT PROXIES
        export HTTP_PROXY=\"$HTTP_PROXY\"
        export HTTPS_PROXY=\"$HTTPS_PROXY\"
        export http_proxy=\"$http_proxy\"
        export https_proxy=\"$https_proxy\"
        export no_proxy=\"$no_proxy\"
        
        ulimit -n 65536
        ulimit -s 2048
        ulimit -c 0
        
        $RAY_ENV_VARS
        
        ray stop --force
        ray start --address=\"$HEAD_NODE_IP:$RAY_PORT\" --num-gpus=12 --num-cpus=96 --block
    '" > /tmp/ray_worker_${worker}.log 2>&1 &
done

echo "Waiting 30s for cluster..."
sleep 30
ray status

# --- 5. DEPLOY SERVICE ---
ulimit -s 2048
ulimit -c 0

DEPLOY_SCRIPT="$SCRIPT_DIR/ray_serve_vllm.py"
python="$LOCAL_ENV/bin/python"
$python -u "$DEPLOY_SCRIPT" > "$JOB_LOG_DIR/ray_serve_deployment.log" 2>&1 &
SERVE_DRIVER_PID=$!

echo "Waiting for Service Deployment..."
MAX_RETRIES=60 # 10 minutes
COUNT=0

echo "Waiting for Cluster Readiness (All Replicas RUNNING)..."
while ! curl -s -f "http://localhost:8000/v1/cluster_ready" > /dev/null; do
    if ! ps -p $SERVE_DRIVER_PID > /dev/null; then
        echo "CRITICAL: Service Driver died."
        cat "$JOB_LOG_DIR/ray_serve_deployment.log"
        exit 1
    fi
    if [ $COUNT -ge $MAX_RETRIES ]; then
        echo "TIMEOUT: Cluster took too long to stabilize."
        # Try to get status one last time for debugging
        curl -s "http://localhost:8000/v1/cluster_ready"
        exit 1
    fi
    
    # Optional: Print status periodically
    if (( COUNT % 6 == 0 )); then
         STATUS=$(curl -s "http://localhost:8000/v1/cluster_ready")
         echo "Status: $STATUS"
    fi

    echo "Cluster not ready yet... ($COUNT/$MAX_RETRIES)"
    sleep 10
    COUNT=$((COUNT+1))
done
echo "Cluster Ready!"

PROMPTS_PER_CLIENT=400
INPUT_LEN=3024
OUTPUT_LEN=1024

# --- 6. BENCHMARK ---

if ps -p $SERVE_DRIVER_PID > /dev/null; then
    echo "Service alive. Running Benchmark..."
    
    # Calculate number of clients to keep utilization high
    # We have 6 replicas per node (12 GPUs / 2 GPUs/replica)
    # So we want roughly 1 client per replica to ensure saturation
    #REPLICAS_PER_NODE=3 2#$(( NUM_NODES * REPLICAS_PER_NODE ))
    NUM_CLIENTS=12
    
    echo "Launching $NUM_CLIENTS benchmark clients for $NUM_NODES nodes..."

    PROXY_URL="http://localhost:8000"
    MODEL="openai/gpt-oss-120b"
    
    for i in $(seq 1 $NUM_CLIENTS); do
        vllm bench serve --model "$MODEL" --backend openai --base-url "$PROXY_URL" \
            --dataset-name random --seed 12345 --num-prompts "$PROMPTS_PER_CLIENT" \
            --random-input-len "$INPUT_LEN" --random-output-len "$OUTPUT_LEN" > "$JOB_LOG_DIR/bench_proxy_${i}.log" 2>&1 &
        PIDS[${i}]=$!
    done
    wait ${PIDS[@]}

    echo "=========================================="
    echo "PROXY BENCHMARK RESULTS (Multi-Node)"
    echo "=========================================="
    for i in $(seq 1 $NUM_CLIENTS); do
        echo "--- Client $i ---"
        grep "Output token throughput" "$JOB_LOG_DIR/bench_proxy_${i}.log"
        grep "Total Token throughput" "$JOB_LOG_DIR/bench_proxy_${i}.log"
    done
    echo "------------------------------------------"

    # Calculate Aggregated Totals
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
    ' "$JOB_LOG_DIR"/bench_proxy_*.log
else
    echo "CRITICAL: Service Driver died."
    cat "$JOB_LOG_DIR/ray_serve_deployment.log"
fi

# Cleanup
kill $SERVE_DRIVER_PID 2>/dev/null
"$LOCAL_ENV/bin/ray" stop --force
for worker in "${WORKER_NODES[@]}"; do
    ssh "$worker" "$LOCAL_ENV/bin/ray stop --force"
done