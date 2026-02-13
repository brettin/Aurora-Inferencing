#!/bin/bash
#PBS -N gpt_oss_120b_vllm
#PBS -l walltime=00:20:00
#PBS -A candle_aesp_CNDA
#PBS -q debug
#PBS -o output_lus.log
#PBS -e error_lus.log
#PBS -l select=1
#PBS -l filesystems=flare:home

export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128
export no_proxy=localhost,127.0.0.1

start_time=$(date +%s)

rm -rf /tmp/hub
copy_start=$(date +%s)
cp -r /flare/AuroraGPT/model-weights/optimized_model/hub /tmp/ &
CP_PID=$!

## module load pti-gpu
module load hdf5

## This has vllm_0.11.x our built wheel
source /opt/aurora/25.190.0/spack/unified/0.10.1/install/linux-sles15-x86_64/gcc-13.3.0/miniforge3-24.3.0-0-gfganax/bin/activate

env_start=$(date +%s)
## Our build triton
conda activate /lus/flare/projects/datasets/softwares/envs/conda_envs/RC1_vllm_0.11.x_triton_3.5.0+git1b0418a9_no_patch_oneapi_2025.2.0_numpy_2.3.4_python3.12.8
env_end=$(date +%s)

# Check for HF_TOKEN
if [ -z "${HF_TOKEN:-}" ]; then
    echo "Error: HF_TOKEN not set. Please export it and pass with qsub -v HF_TOKEN"
    exit 1
fi
export HF_TOKEN
export HF_HOME="/tmp"
export RAY_TMPDIR="/tmp"
export TMPDIR="/tmp"

export ZE_FLAT_DEVICE_HIERARCHY=FLAT

## For -tp >= 2
unset CCL_PROCESS_LAUNCHER
export CCL_PROCESS_LAUNCHER=None
## Must Have
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export FI_MR_CACHE_MONITOR=userfaultfd
export TORCH_COMPILE_DISABLE=1
export OMP_NUM_THREADS=52

wait $CP_PID
copy_end=$(date +%s)
weights_copy_time=$((copy_end - copy_start))

vllm serve openai/gpt-oss-120b --port 8080 --tensor-parallel-size 8 --dtype bfloat16 > vllm_startup_lus.log 2>&1 &
VLLM_PID=$!
tail -f vllm_startup_lus.log &
TAIL_PID=$!

echo "Waiting for vllm to start..."
checkpoint_start=""
while ! curl -s -f http://localhost:8080/health > /dev/null; do
    if [ -z "$checkpoint_start" ]; then
        if grep -q "Loading safetensors checkpoint shards" vllm_startup_lus.log; then
            checkpoint_start=$(date +%s)
            echo "Checkpoint loading started at $checkpoint_start"
        fi
    fi
    sleep 1
done

end_time=$(date +%s)
# If we never caught the message (e.g. it happened very fast or text changed), default to end_time to avoid negative numbers or errors, but typically we expect to see it.
if [ -z "$checkpoint_start" ]; then
    checkpoint_start=$end_time
fi

env_time=$((env_end - env_start))
vllm_init_time=$((checkpoint_start - env_end))
weights_load_time=$((end_time - checkpoint_start))
total_time=$((end_time - start_time))

echo "Environment Load Time: $env_time seconds"
echo "Weights Copy Time: $weights_copy_time seconds"
echo "VLLM Init Time (Env Ready -> Loading Checkpoints): $vllm_init_time seconds"
echo "Weights Loading Time (Loading Checkpoints -> Ready): $weights_load_time seconds"
echo "Total Time: $total_time seconds"

kill $VLLM_PID
kill $TAIL_PID