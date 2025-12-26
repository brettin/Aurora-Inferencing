#!/bin/bash
# input arguments: INFILE PORT

# Timing configuration
START_TIME=$(date +%s)
WALLTIME=3600
CLEANUP_MARGIN=300
PAUSE_EXECUTION=${PAUSE_EXECUTION:-}

# Script and host configuration
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
HOSTNAME=$(hostname)

# Input/Output configuration
OUTPUT_DIR="/dev/shm"
INFILE=${1:-"${SCRIPT_DIR}/../../examples/TOM.COLI/chunk_0000.txt"}
VLLM_HOST_PORT=${2:-6739}
TENSOR_PARALLEL_SIZE=${3:-2}  # Third parameter, default to 2
infile_base=$(basename "$INFILE")
TEST_OUTPUTS_DIR="${OUTPUT_DIR}/test_outputs_${HOSTNAME}_${VLLM_HOST_PORT}_$$"

# VLLM configuration
VLLM_MODEL="openai/gpt-oss-120b"
# VLLM_MODEL_CACHE="/tmp/hf_home/hub/models--openai--gpt-oss-120b/snapshots/b5c939de8f754692c1647ca79fbf85e8c1e70f8a"
TEST_BATCH_SIZE=64

# Calculate GPU affinity based on port
# Port 6739 -> index 0 -> GPUs 0,1
# Port 6740 -> index 1 -> GPUs 2,3
# etc.
BASE_PORT=6739
PORT_INDEX=$((VLLM_HOST_PORT - BASE_PORT))
GPU_START=$((PORT_INDEX * TENSOR_PARALLEL_SIZE))
GPU_END=$((GPU_START + TENSOR_PARALLEL_SIZE - 1))
ZE_AFFINITY_MASK=$(seq -s, $GPU_START $GPU_END)

# Authentication
export HF_TOKEN=${HF_TOKEN:-}

# Delay execution for PORT_INDEX * 10 seconds
sleep $((PORT_INDEX * 10))

# print settings
echo "$(date) $HOSTNAME INFILE: $INFILE"
echo "$(date) $HOSTNAME HOSTNAME: $HOSTNAME"
echo "$(date) $HOSTNAME TEST_BATCH_SIZE: $TEST_BATCH_SIZE"
echo "$(date) $HOSTNAME VLLM_MODEL: $VLLM_MODEL"
# echo "$(date) $HOSTNAME VLLM_MODEL_CACHE: $VLLM_MODEL_CACHE"
echo "$(date) $HOSTNAME VLLM_HOST_PORT: $VLLM_HOST_PORT"
echo "$(date) $HOSTNAME TENSOR_PARALLEL_SIZE: $TENSOR_PARALLEL_SIZE"
echo "$(date) $HOSTNAME ZE_AFFINITY_MASK: $ZE_AFFINITY_MASK"

# Directory setup
mkdir -p "${TEST_OUTPUTS_DIR}"

# Environment setup
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128

module load pti-gpu
module load hdf5

# Conda environment is unpacked by submit script before launching servers
source "/opt/aurora/25.190.0/spack/unified/0.10.1/install/linux-sles15-x86_64/gcc-13.3.0/miniforge3-24.3.0-0-gfganax/bin/activate"
#conda activate "/lus/flare/projects/datasets/softwares/envs/conda_envs/RC1_vllm_0.11.x_triton_3.5.0+git1b0418a9_no_patch_oneapi_2025.2.0_numpy_2.3.4_python3.12.8"
conda activate /tmp/hf_home/hub/vllm_env

# HuggingFace configuration
export HF_HUB_OFFLINE=1
export HF_HOME="/tmp/hf_home"
export HF_DATASETS_CACHE="/tmp/hf_home"
export HF_MODULES_CACHE="/tmp/hf_home"

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
export OCL_ICD_FILENAMES="libintelocl.so"
export TORCH_COMPILE_DISABLE=1
export OMP_NUM_THREADS=32
export TORCH_XPU_ALLOC_CONF=expandable_segments:True

ray stop -f
export no_proxy="localhost,127.0.0.1" #Set no_proxy for the client to interact with the locally hosted model
export VLLM_HOST_IP=$(getent hosts $(hostname).hsn.cm.aurora.alcf.anl.gov | awk '{ print $1 }' | tr ' ' '\n' | sort | head -n 1)

# Start vLLM server
echo "$(date) $HOSTNAME Starting vLLM server with model: ${VLLM_MODEL}"
echo "$(date) $HOSTNAME Server port: ${VLLM_HOST_PORT}"
echo "$(date) $HOSTNAME Tensor parallel size: ${TENSOR_PARALLEL_SIZE}"
echo "$(date) $HOSTNAME GPU affinity mask: ${ZE_AFFINITY_MASK}"
echo "$(date) $HOSTNAME Log file: ${TEST_OUTPUTS_DIR}/${HOSTNAME}_${VLLM_HOST_PORT}.vllm.log"
ZE_AFFINITY_MASK=${ZE_AFFINITY_MASK} OCL_ICD_FILENAMES="libintelocl.so" VLLM_DISABLE_SINKS=1 vllm serve ${VLLM_MODEL} \
  --dtype bfloat16 \
  --tensor-parallel-size ${TENSOR_PARALLEL_SIZE} \
  --enforce-eager \
  --distributed-executor-backend mp \
  --disable-custom-all-reduce \
  --trust-remote-code \
  --port ${VLLM_HOST_PORT} > "${TEST_OUTPUTS_DIR}/${HOSTNAME}_${VLLM_HOST_PORT}.vllm.log" 2>&1 &
# get vllm server pid
vllm_pid=$!

# wait for vllm server to be ready
echo "$(date) $HOSTNAME Waiting for vLLM server to be ready - PORT_INDEX=${PORT_INDEX} port=${VLLM_HOST_PORT}"
while ! curl -s http://localhost:${VLLM_HOST_PORT}/health > /dev/null 2>&1; do
    sleep 5
done
echo "$(date) ${HOSTNAME} vLLM server is ready - PORT_INDEX=${PORT_INDEX} port=${VLLM_HOST_PORT}"


# run test script with timeout
CURRENT_TIME=$(date +%s)
ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
TIMEOUT_SECONDS=$((WALLTIME - ELAPSED_TIME - CLEANUP_MARGIN))
echo "$(date) ${HOSTNAME} Timeout seconds: ${TIMEOUT_SECONDS}"

module load frameworks

unset HTTP_PROXY
unset HTTPS_PROXY
unset http_proxy
unset https_proxy

# Print the full command with all variables expanded
echo "$(date) ${HOSTNAME} timeout ${TIMEOUT_SECONDS} python -u ${SCRIPT_DIR}/../../examples/TOM.COLI/test.coli_v3.py $INFILE $HOSTNAME --batch-size ${TEST_BATCH_SIZE} --model ${VLLM_MODEL} --port ${VLLM_HOST_PORT} > ${TEST_OUTPUTS_DIR}/${infile_base}.${HOSTNAME}_${VLLM_HOST_PORT}.test.coli_v3.txt 2>&1"
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

timeout "${TIMEOUT_SECONDS}" python -u "${SCRIPT_DIR}/../../examples/TOM.COLI/test.coli_v3.py" "$INFILE" "$HOSTNAME" \
	--batch-size "${TEST_BATCH_SIZE}" \
	--model "${VLLM_MODEL}" \
	--port "${VLLM_HOST_PORT}" > "${TEST_OUTPUTS_DIR}/${infile_base}.${HOSTNAME}_${VLLM_HOST_PORT}.test.coli_v3.txt" 2>&1

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
ARCHIVE_NAME="${HOSTNAME}_${VLLM_HOST_PORT}_results_$(date +%Y%m%d_%H%M%S).tar.gz"
ARCHIVE_PATH="${SCRIPT_DIR}/${ARCHIVE_NAME}"

# create tar archive of all output files in TEST_OUTPUTS_DIR
cd "$OUTPUT_DIR" && tar -czf "$ARCHIVE_PATH" "test_outputs_${HOSTNAME}_${VLLM_HOST_PORT}_$$/" 2>&1

# cleanup output directory
rm -rf "${TEST_OUTPUTS_DIR}"

# print archive size
echo "$(date) ${HOSTNAME} Archive size: $(du -h "$ARCHIVE_PATH" | cut -f1)"
