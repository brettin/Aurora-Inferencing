#!/bin/bash
# input argument: MODEL_NAME (optional). Launches vLLM server and keeps it running.
#
export PYTHONNOUSERSITE=1
USE_FRAMEWORKS=${USE_FRAMEWORKS:-0}

# Script and host configuration
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
HOSTNAME=$(hostname)

# Model and log configuration
VLLM_MODEL=${1:-"openai/gpt-oss-120b"}
VLLM_LOG_DIR="/dev/shm/vllm_logs_${HOSTNAME}_$$"

# VLLM configuration
VLLM_HOST_PORT=6739

# Authentication
export HF_TOKEN=${HF_TOKEN:-}

# print settings
echo "$(date) $HOSTNAME HOSTNAME: $HOSTNAME"
echo "$(date) $HOSTNAME VLLM_MODEL: $VLLM_MODEL"
echo "$(date) $HOSTNAME VLLM_HOST_PORT: $VLLM_HOST_PORT"

# Directory setup
mkdir -p "${VLLM_LOG_DIR}"

# Environment setup
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128

module load pti-gpu
module load hdf5

echo "$(date) $HOSTNAME USE_FRAMEWORKS: ${USE_FRAMEWORKS}"
if [ "${USE_FRAMEWORKS}" -eq 1 ]; then
    echo "$(date) $HOSTNAME Using frameworks module"
    module load frameworks
    echo "$(date) $HOSTNAME Frameworks module loaded"
else
    echo "$(date) $HOSTNAME Activating staged conda environment"
    # source "/opt/aurora/25.190.0/spack/unified/0.10.1/install/linux-sles15-x86_64/gcc-13.3.0/miniforge3-24.3.0-0-gfganax/bin/activate"
    # Clear positional parameters to avoid conda activate picking them up
    set --
    # conda activate /tmp/hf_home/hub/vllm_env
    source /tmp/hf_home/hub/vllm_env/bin/activate
    conda-unpack
    export LD_LIBRARY_PATH=/tmp/hf_home/hub/vllm_env/lib/python3.12/site-packages/intel_extension_for_pytorch/lib:/tmp/hf_home/hub/vllm_env/lib:/tmp/hf_home/hub/vllm_env/lib/python3.12/site-packages/torch/lib:${LD_LIBRARY_PATH}:/usr/lib64
    echo "$(date) $HOSTNAME LD_LIBRARY_PATH: ${LD_LIBRARY_PATH}"
    echo "$(date) $HOSTNAME Conda environment activated"
    which python
    python -c 'import sys ; print(sys.path)'

fi

# HuggingFace configuration
export HF_HOME="/tmp/hf_home"
export HF_DATASETS_CACHE="/tmp/hf_home"
export HF_MODULES_CACHE="/tmp/hf_home"
export HF_HUB_OFFLINE=1

# Ray and temp directories
export RAY_TMPDIR="/tmp"
export TMPDIR="/tmp"

# GPU/device configuration
export ZE_FLAT_DEVICE_HIERARCHY=FLAT
unset ONEAPI_DEVICE_SELECTOR

# CCL configuration for tensor-parallel >= 2
unset CCL_PROCESS_LAUNCHER
export CCL_PROCESS_LAUNCHER=None

# vLLM configuration
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export FI_MR_CACHE_MONITOR=userfaultfd
export TOKENIZERS_PARALLELISM=false
export VLLM_LOGGING_LEVEL=DEBUG
export OCL_ICD_SO="/opt/aurora/25.190.0/oneapi/2025.2/lib/libintelocl.so"
export VLLM_CACHE_ROOT="/tmp/hf_home/vllm_cache"

ray stop -f
export no_proxy="localhost,127.0.0.1" #Set no_proxy for the client to interact with the locally hosted model
export VLLM_HOST_IP=$(getent hosts $(hostname).hsn.cm.aurora.alcf.anl.gov | awk '{ print $1 }' | tr ' ' '\n' | sort | head -n 1)

# Start vLLM server
echo "$(date) $HOSTNAME Starting vLLM server with model: ${VLLM_MODEL}"
echo "$(date) $HOSTNAME Server port: ${VLLM_HOST_PORT}"
echo "$(date) $HOSTNAME Log file: ${VLLM_LOG_DIR}/${HOSTNAME}.vllm.log"

export OCL_ICD_FILENAMES="/opt/aurora/25.190.0/oneapi/2025.2/lib/libintelocl.so"
export VLLM_DISABLE_SINKS=1

#strace -ff -e trace=%file -o /tmp/strace.%p \
OCL_ICD_FILENAMES="/opt/aurora/25.190.0/oneapi/2025.2/lib/libintelocl.so" VLLM_DISABLE_SINKS=1 vllm serve ${VLLM_MODEL} \
  --dtype bfloat16 \
  --tensor-parallel-size 8 \
  --enforce-eager \
  --distributed-executor-backend mp \
  --trust-remote-code \
  --port ${VLLM_HOST_PORT} > "${VLLM_LOG_DIR}/${HOSTNAME}.vllm.log" 2>&1 &
# get vllm server pid
vllm_pid=$!

# wait for vllm server to be ready
echo "$(date) $HOSTNAME Waiting for vLLM server to be ready..."
while ! curl -s http://localhost:${VLLM_HOST_PORT}/health > /dev/null 2>&1; do
    sleep 5
    # if vllm_pid not in process table, exit loop
done
echo "$(date) ${HOSTNAME} vLLM server is ready"

# Keep script alive so vLLM keeps running until process exits or job ends
wait $vllm_pid
