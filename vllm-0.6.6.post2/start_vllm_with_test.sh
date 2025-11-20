#!/bin/bash -l

# Record start time for timeout calculation
SCRIPT_START_TIME=$(date +%s)

# Set total walltime in seconds (default: 60 minutes)
# Can be overridden by setting WALLTIME_SECONDS environment variable
TOTAL_WALLTIME=${WALLTIME_SECONDS:-1200}

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
INFILE=${1:-"${SCRIPT_DIR}/../examples/TOM.COLI/1.txt"}
HOSTNAME=$(hostname)
echo "$(date) ${HOSTNAME} TSB script directory is: $SCRIPT_DIR"
echo "$(date) ${HOSTNAME} TSB infile is ${INFILE}"
echo "$(date) ${HOSTNAME} TSB hostname: $HOSTNAME"
echo "$(date) ${HOSTNAME} TSB Total walltime: ${TOTAL_WALLTIME}s ($(($TOTAL_WALLTIME/60)) minutes)"

# This is needed incase vllm tries to download from huggingface.
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128

module load frameworks

export tiles=12
export ZE_FLAT_DEVICE_HIERARCHY=FLAT
export NUMEXPR_MAX_THREADS=208
export CCL_PROCESS_LAUNCHER=torchrun # Per Ken R.

# You need to change these because you need write perms on the dirs.
#export HF_DATASETS_CACHE=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
#export TRANSFORMERS_CACHE=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
#export HF_HOME=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
#export HF_MODULES_CACHE=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
export HF_HOME="/tmp/hf_home"

export TMPDIR=/tmp
export RAY_TMPDIR=/tmp
export VLLM_HOST_IP=$(getent hosts $(hostname).hsn.cm.aurora.alcf.anl.gov | awk '{ print $1 }' | tr ' ' '\n' | sort | head -n 1)
export RAY_ADDRESS=$VLLM_HOST_IP:6379
export VLLM_HOST_PORT=8000

#export VLLM_MODEL="meta-llama/Llama-3.1-8B-Instruct"
export VLLM_MODEL="meta-llama/Llama-3.3-70B-Instruct"
#export VLLM_MODEL="openai/gpt-oss-120b"

export HF_HUB_OFFLINE=1

unset ONEAPI_DEVICE_SELECTOR
export NUMEXPR_MAX_THREADS=208
unset OMP_NUM_THREADS

export CCL_PROCESS_LAUNCHER=torchrun

# Done setting up environment and variables.

# Setup local output directory on /dev/shm for fast I/O
OUTPUT_DIR="/dev/shm/vllm_output_${HOSTNAME}_$$"
mkdir -p "$OUTPUT_DIR"
echo "$(date) ${HOSTNAME} TSB Local output directory: $OUTPUT_DIR"

echo "$(date) ${HOSTNAME} TSB starting ray on $VLLM_HOST_IP"
ray --logging-level info  start --head --verbose --node-ip-address=$VLLM_HOST_IP --port=6379 --num-cpus=64 --num-gpus=$tiles
echo "$(date) ${HOSTNAME} TSB done starting ray on $VLLM_HOST_IP"

echo "$(date) ${HOSTNAME} TSB starting vllm with ${VLLM_MODEL} on host ${HOSTNAME}"
echo "$(date) ${HOSTNAME} TSB writing log to $OUTPUT_DIR/${HOSTNAME}.vllm.log"

# Start vLLM server in background, redirecting output to log file
# Use PYTHONUNBUFFERED to ensure output is written immediately
PYTHONUNBUFFERED=1 vllm serve ${VLLM_MODEL} --port ${VLLM_HOST_PORT} --tensor-parallel-size 8 --dtype bfloat16 --trust-remote-code --max-model-len 32000 > $OUTPUT_DIR/${HOSTNAME}.vllm.log 2>&1 &
vllm_pid=$!
echo "$(date) ${HOSTNAME} TSB vLLM PID: $vllm_pid"

unset HTTP_PROXY
unset HTTPS_PROXY
unset http_proxy
unset https_proxy

echo "$(date) ${HOSTNAME} TSB Waiting for vLLM..."
until curl -sf "http://${HOSTNAME}:${VLLM_HOST_PORT}/health" ; do
  sleep 2
done
echo "$(date) ${HOSTNAME} TSB vLLM ready!"


# Calculate remaining time for timeout
CURRENT_TIME=$(date +%s)
ELAPSED_TIME=$((CURRENT_TIME - SCRIPT_START_TIME))
TIMEOUT_SECONDS=$((TOTAL_WALLTIME - ELAPSED_TIME))

# Add safety margin (reserve 60 seconds for cleanup)
TIMEOUT_SECONDS=$((TIMEOUT_SECONDS - 60))

# Ensure timeout is positive
if [ $TIMEOUT_SECONDS -le 0 ]; then
    echo "$(date) ${HOSTNAME} TSB WARNING: No time remaining for test (elapsed: ${ELAPSED_TIME}s)"
    TIMEOUT_SECONDS=60  # Give it at least 1 minute
fi

echo "$(date) ${HOSTNAME} TSB Elapsed time: ${ELAPSED_TIME}s, Timeout set to: ${TIMEOUT_SECONDS}s"


infile_base=$(basename $INFILE)
echo "$(date) ${HOSTNAME} TSB calling test.coli_v2.py on ${infile_base} using ${VLLM_MODEL}"

# Run python with timeout, output to /dev/shm
timeout ${TIMEOUT_SECONDS} python -u ${SCRIPT_DIR}/../examples/TOM.COLI/test.coli_v2.py ${INFILE} ${HOSTNAME} \
	--batch-size 32 \
	--model ${VLLM_MODEL} \
	--port ${VLLM_HOST_PORT} \
	> ${OUTPUT_DIR}/${infile_base}.${HOSTNAME}.test.coli_v2.txt 2>&1

# Get exit code from timeout command
test_exit_code=$?

# Check if timeout occurred (exit code 124)
if [ $test_exit_code -eq 124 ]; then
    echo "$(date) ${HOSTNAME} TSB test.coli TIMED OUT after ${TIMEOUT_SECONDS} seconds"
elif [ $test_exit_code -eq 137 ]; then
    echo "$(date) ${HOSTNAME} TSB test.coli was KILLED (SIGKILL)"
else
    echo "$(date) ${HOSTNAME} TSB test.coli returned ${test_exit_code}"
fi

# Kill the vllm server when the python script is done
echo "$(date) ${HOSTNAME} TSB Stopping vLLM server..."
kill -SIGINT "$vllm_pid"
wait "$vllm_pid" 2>/dev/null

# Give filesystem time to flush any buffered output
sleep 2
echo "$(date) ${HOSTNAME} TSB vLLM log size: $(du -h $OUTPUT_DIR/${HOSTNAME}.vllm.log 2>/dev/null | cut -f1 || echo '0')"

# Archive and transfer results from /dev/shm to shared filesystem
echo "$(date) ${HOSTNAME} TSB Archiving results from $OUTPUT_DIR"
ARCHIVE_NAME="${HOSTNAME}_results_$(date +%Y%m%d_%H%M%S).tar.gz"
ARCHIVE_PATH="${SCRIPT_DIR}/${ARCHIVE_NAME}"

# Create tar archive of all output files
cd /dev/shm
tar -czf "$ARCHIVE_PATH" "vllm_output_${HOSTNAME}_$$/" 2>&1

if [ $? -eq 0 ]; then
    echo "$(date) ${HOSTNAME} TSB Results archived to: $ARCHIVE_PATH"
    
    # Show archive size
    ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
    echo "$(date) ${HOSTNAME} TSB Archive size: $ARCHIVE_SIZE"
    
    # Cleanup /dev/shm
    echo "$(date) ${HOSTNAME} TSB Cleaning up $OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR"
    echo "$(date) ${HOSTNAME} TSB Cleanup complete"
else
    echo "$(date) ${HOSTNAME} TSB ERROR: Failed to create archive"
    echo "$(date) ${HOSTNAME} TSB Output files remain in: $OUTPUT_DIR"
fi

echo "$(date) ${HOSTNAME} TSB Script complete"
