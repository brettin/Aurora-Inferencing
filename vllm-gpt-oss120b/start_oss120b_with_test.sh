#!/bin/bash
# input arguments: INFILE MODEL_NAME (optional)
#
export PYTHONNOUSERSITE=1
#
# Timing configuration
START_TIME=$(date +%s)
WALLTIME=7200    # 60seconds * 60minutes * 2hrs = 7200
CLEANUP_MARGIN=300
PAUSE_EXECUTION=${PAUSE_EXECUTION:-}

# Script and host configuration
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
HOSTNAME=$(hostname)

# Input/Output configuration
INFILE=${1:-"${SCRIPT_DIR}/../examples/TOM.COLI/chunk_0000.txt"}
VLLM_MODEL=${2:-"openai/gpt-oss-120b"}
OUTPUT_DIR="/dev/shm"
TEST_OUTPUTS_DIR="${OUTPUT_DIR}/test_outputs_${HOSTNAME}_$$"
infile_base=$(basename "$INFILE")

# VLLM configuration
VLLM_HOST_PORT=6739
TEST_BATCH_SIZE=64

# Authentication
export HF_TOKEN=${HF_TOKEN:-}

# print settings
echo "$(date) $HOSTNAME INFILE: $INFILE"
echo "$(date) $HOSTNAME HOSTNAME: $HOSTNAME"
echo "$(date) $HOSTNAME TEST_BATCH_SIZE: $TEST_BATCH_SIZE"
echo "$(date) $HOSTNAME VLLM_MODEL: $VLLM_MODEL"
echo "$(date) $HOSTNAME VLLM_HOST_PORT: $VLLM_HOST_PORT"
echo "$(date) $HOSTNAME WALLTIME: $WALLTIME"
echo "$(date) $HOSTNAME START_TIME: $START_TIME"

# Directory setup
mkdir -p "${TEST_OUTPUTS_DIR}"

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
echo "$(date) $HOSTNAME Log file: ${TEST_OUTPUTS_DIR}/${HOSTNAME}.vllm.log"

export OCL_ICD_FILENAMES="/opt/aurora/25.190.0/oneapi/2025.2/lib/libintelocl.so" 
export VLLM_DISABLE_SINKS=1

strace -ff -e trace=%file -o /tmp/strace.%p \
vllm serve ${VLLM_MODEL} \
  --dtype bfloat16 \
  --tensor-parallel-size 8 \
  --enforce-eager \
  --distributed-executor-backend mp \
  --trust-remote-code \
  --port ${VLLM_HOST_PORT} > "${TEST_OUTPUTS_DIR}/${HOSTNAME}.vllm.log" 2>&1 &
# get vllm server pid
vllm_pid=$!

# wait for vllm server to be ready
echo "$(date) $HOSTNAME Waiting for vLLM server to be ready..."
while ! curl -s http://localhost:${VLLM_HOST_PORT}/health > /dev/null 2>&1; do
    sleep 5
    # if vllm_pid not in process table, exit loop
done
echo "$(date) ${HOSTNAME} vLLM server is ready"


# run test script with timeout
CURRENT_TIME=$(date +%s)
ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
TIMEOUT_SECONDS=$((WALLTIME - ELAPSED_TIME - CLEANUP_MARGIN))
echo "$(date) ${HOSTNAME} ELAPSED_TIME: ${ELAPSED_TIME}"
echo "$(date) ${HOSTNAME} Timeout seconds: ${TIMEOUT_SECONDS}"

module load frameworks

unset HTTP_PROXY
unset HTTPS_PROXY
unset http_proxy
unset https_proxy

# Print the full command with all variables expanded
echo "$(date) ${HOSTNAME} timeout ${TIMEOUT_SECONDS} python -u ${SCRIPT_DIR}/../examples/TOM.COLI/test.coli_v3.py $INFILE $HOSTNAME --batch-size ${TEST_BATCH_SIZE} --model ${VLLM_MODEL} --port ${VLLM_HOST_PORT} > ${TEST_OUTPUTS_DIR}/${infile_base}.${HOSTNAME}.test.coli_v3.txt 2>&1"
echo "$(date) ${HOSTNAME} TIMEOUT_SECONDS: ${TIMEOUT_SECONDS}"
echo "$(date) ${HOSTNAME} SCRIPT_DIR: ${SCRIPT_DIR}"
echo "$(date) ${HOSTNAME} INFILE: ${INFILE}"
echo "$(date) ${HOSTNAME} HOSTNAME: ${HOSTNAME}"
echo "$(date) ${HOSTNAME} TEST_BATCH_SIZE: ${TEST_BATCH_SIZE}"
echo "$(date) ${HOSTNAME} VLLM_MODEL: ${VLLM_MODEL}"
echo "$(date) ${HOSTNAME} VLLM_HOST_PORT: ${VLLM_HOST_PORT}"
echo "$(date) ${HOSTNAME} TEST_OUTPUTS_DIR: ${TEST_OUTPUTS_DIR}"
echo "$(date) ${HOSTNAME} infile_base: ${infile_base}"
echo "$(date) ${HOSTNAME} Python path: $(which python)"
echo "$(date) ${HOSTNAME} Python version: $(python --version 2>&1)"

timeout "${TIMEOUT_SECONDS}" python -u "${SCRIPT_DIR}/../examples/TOM.COLI/test.coli_v3.py" "$INFILE" "$HOSTNAME" \
	--batch-size "${TEST_BATCH_SIZE}" \
	--model "${VLLM_MODEL}" \
	--port "${VLLM_HOST_PORT}" > "${TEST_OUTPUTS_DIR}/${infile_base}.${HOSTNAME}.test.coli_v3.txt" 2>&1

# get exit code from timeout command
test_exit_code=$?

# check if timeout occurred (exit code 124)
if [ $test_exit_code -eq 124 ]; then
    echo "$(date) ${HOSTNAME} test.coli_v3.py timed out after 60 seconds"
elif [ $test_exit_code -eq 137 ]; then
    echo "$(date) ${HOSTNAME} test.coli_v3.py was killed (SIGKILL)"
else
    echo "$(date) ${HOSTNAME} test.coli_v3.py returned ${test_exit_code}"
fi

# go into a loop to pause execution
if [ -n "$PAUSE_EXECUTION" ]; then
    while [ -n "$PAUSE_EXECUTION" ]; do
        sleep 60
        echo "$(date) ${HOSTNAME} Pausing execution for 60 seconds"
    done
fi


echo "$(date) ${HOSTNAME} Stopping vLLM server (PID: $vllm_pid)..."
if kill -0 $vllm_pid 2>/dev/null; then
    kill -SIGINT $vllm_pid
    sleep 2
    kill -9 $vllm_pid 2>/dev/null || true
fi

# archive results
ARCHIVE_NAME="${HOSTNAME}_results_$(date +%Y%m%d_%H%M%S).tar.gz"
ARCHIVE_PATH="${SCRIPT_DIR}/${ARCHIVE_NAME}"

# create tar archive of all output files in TEST_OUTPUTS_DIR
cd "$OUTPUT_DIR" && tar -czf "$ARCHIVE_PATH" "test_outputs_${HOSTNAME}_$$/" 2>&1

# cleanup output directory
rm -rf "${TEST_OUTPUTS_DIR}"

# print archive size
echo "$(date) ${HOSTNAME} Archive size: $(du -h "$ARCHIVE_PATH" | cut -f1)"
