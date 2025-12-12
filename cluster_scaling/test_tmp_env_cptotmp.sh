#!/bin/bash
#PBS -N gpt_oss_120b_vllm
#PBS -l walltime=00:15:00
#PBS -A candle_aesp_CNDA
#PBS -q debug
#PBS -o output_tmp_cptotmp.log
#PBS -e error_tmp_cptotmp.log
#PBS -l select=1
#PBS -l filesystems=flare:home

export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128
export no_proxy=localhost,127.0.0.1

# --- 0. PREPARE COPY TOOL ---
# Path to your C source file (Adjust if needed, assuming it's in the submission dir)
CPTOTMP_SRC="${PBS_O_WORKDIR}/cptotmp.c"
CPTOTMP_BIN="/tmp/cptotmp"

# Compile the tool locally on the compute node
module load frameworks
mpicc -o "$CPTOTMP_BIN" "$CPTOTMP_SRC"

# --- OPTIMIZED ENV VARS ---
# Re-enable these for better broadcast performance on Aurora
export MPIR_CVAR_CH4_OFI_ENABLE_MULTI_NIC_STRIPING=1
export MPIR_CVAR_CH4_OFI_MAX_NICS=4

start_time=$(date +%s)

echo "Cleaning up tmp"

# --- 1. STAGE MODEL WEIGHTS ---
rm -rf /tmp/hub
copy_start=$(date +%s)
MODEL_SOURCE="/flare/AuroraGPT/model-weights/optimized_model/hub"
MODEL_DEST="/tmp"

echo "Staging weights from $MODEL_SOURCE to $MODEL_DEST..."

# Use mpiexec to run the streaming tool
mpiexec -ppn 1 --cpu-bind numa /tmp/cptotmp "$MODEL_SOURCE" "$MODEL_DEST"

copy_end=$(date +%s)
weights_copy_time=$((copy_end - copy_start))

# --- 2. STAGE & SETUP ENVIRONMENT ---
module load hdf5
# We need a base python to run conda-unpack later if the packed env isn't fully standalone yet
source /opt/aurora/25.190.0/spack/unified/0.10.1/install/linux-sles15-x86_64/gcc-13.3.0/miniforge3-24.3.0-0-gfganax/bin/activate

env_start=$(date +%s)
ENV_TAR="/flare/AuroraGPT/ngetty/envs/packed_envs/vllm_env.tar.gz"
LOCAL_ENV="/tmp/vllm_env"
ENV_STAGE_DIR="/tmp"

if [ ! -d "$LOCAL_ENV" ]; then
    mkdir -p "$LOCAL_ENV"
    
    echo "Staging environment tarball..."
    # 2a. Broadcast tarball to /tmp (creates /tmp/vllm_env.tar.gz)
    mpiexec -ppn 1 --cpu-bind numa "$CPTOTMP_BIN" "$ENV_TAR" "$ENV_STAGE_DIR"

    # 2b. Extract to local folder
    TAR_NAME=$(basename "$ENV_TAR")
    echo "Extracting $ENV_STAGE_DIR/$TAR_NAME..."
    tar -xf "$ENV_STAGE_DIR/$TAR_NAME" -C "$LOCAL_ENV"

    # 2c. Cleanup tarball to save space
    rm "$ENV_STAGE_DIR/$TAR_NAME"

    # 2d. Fix paths using conda-unpack
    echo "Running conda-unpack..."
    source "$LOCAL_ENV/bin/activate"
    conda-unpack
else
    source "$LOCAL_ENV/bin/activate"
fi
env_end=$(date +%s)


# --- 3. CONFIGURE VLLM ---
if [ -z "${HF_TOKEN:-}" ]; then
    echo "Error: HF_TOKEN not set. Please export it and pass with qsub -v HF_TOKEN"
    exit 1
fi
export HF_TOKEN
export HF_HOME="/tmp"
export HF_DATASETS_CACHE="/flare/AuroraGPT/model-weights"
export RAY_TMPDIR="/tmp"
export TMPDIR="/tmp"

export ZE_FLAT_DEVICE_HIERARCHY=FLAT
unset CCL_PROCESS_LAUNCHER
export CCL_PROCESS_LAUNCHER=None
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export FI_MR_CACHE_MONITOR=userfaultfd
export TORCH_COMPILE_DISABLE=1
export OMP_NUM_THREADS=16

# --- 4. RUN VLLM ---
echo "Starting vLLM..."
vllm serve openai/gpt-oss-120b --port 8080 --tensor-parallel-size 8 --dtype bfloat16 > vllm_startup_tmp.log 2>&1 &
VLLM_PID=$!
tail -f vllm_startup_tmp.log &
TAIL_PID=$!

echo "Waiting for vllm to start..."
checkpoint_start=""
while ! curl -s -f http://localhost:8080/health > /dev/null; do
    if [ -z "$checkpoint_start" ]; then
        if grep -q "Loading safetensors checkpoint shards" vllm_startup_tmp.log; then
            checkpoint_start=$(date +%s)
            echo "Checkpoint loading started at $checkpoint_start"
        fi
    fi
    sleep 1
done

end_time=$(date +%s)
if [ -z "$checkpoint_start" ]; then
    checkpoint_start=$end_time
fi

# --- 5. REPORT METRICS ---
env_time=$((env_end - env_start))
vllm_init_time=$((checkpoint_start - env_end))
weights_load_time=$((end_time - checkpoint_start))
total_time=$((end_time - start_time))

echo "----------------------------------------------------------------"
echo "Performance Metrics (Single Node with cptotmp)"
echo "----------------------------------------------------------------"
echo "Weights Staging Time (Lustre -> /tmp): $weights_copy_time seconds"
echo "Environment Setup Time (Copy + Untar + Unpack): $env_time seconds"
echo "VLLM Init Time (Env Ready -> Loading Checkpoints): $vllm_init_time seconds"
echo "Weights Loading Time (Loading Checkpoints -> Ready): $weights_load_time seconds"
echo "Total Time: $total_time seconds"

kill $VLLM_PID
kill $TAIL_PID