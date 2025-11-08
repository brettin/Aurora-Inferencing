#!/bin/bash -l

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
INFILE=${1:-"${SCRIPT_DIR}/../examples/TOM.COLI/1.txt"}
HOSTNAME=$(hostname)
echo "$(date) ${HOSTNAME} TSB script directory is: $SCRIPT_DIR"
echo "$(date) ${HOSTNAME} TSB infile is ${INFILE}"
echo "$(date) ${HOSTNAME} TSB hostname: $HOSTNAME"

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
export HF_DATASETS_CACHE=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
export TRANSFORMERS_CACHE=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
export HF_HOME=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
export HF_MODULES_CACHE=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache

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

echo "$(date) ${HOSTNAME} TSB starting ray on $VLLM_HOST_IP"
ray --logging-level info  start --head --verbose --node-ip-address=$VLLM_HOST_IP --port=6379 --num-cpus=64 --num-gpus=$tiles
echo "$(date) ${HOSTNAME} TSB done starting ray on $VLLM_HOST_IP"

echo "$(date) ${HOSTNAME} TSB starting vllm with ${VLLM_MODEL} on host ${HOSTNAME}"
echo "$(date) ${HOSTNAME} TSB writing log to $SCRIPT_DIR/${HOSTNAME}.vllm.log"

#vllm serve ${VLLM_MODEL} --port ${VLLM_HOST_PORT} --tensor-parallel-size 8 --dtype float16 --trust-remote-code --max-model-len 32000 > $SCRIPT_DIR/${HOSTNAME}.vllm.log &
vllm serve ${VLLM_MODEL} --port ${VLLM_HOST_PORT} --tensor-parallel-size 8 --dtype bfloat16 --trust-remote-code --max-model-len 32000 > $SCRIPT_DIR/${HOSTNAME}.vllm.log &


# Use this if you want more verbose output to debug starting vllm.
# python -u -m vllm.entrypoints.openai.api_server \
# 	--host $(hostname) \
# 	--model ${VLLM_MODEL} \
# 	--port ${VLLM_HOST_PORT} \
# 	--tensor-parallel-size 8 \
#	--dtype float16 \
# 	--trust-remote-code \
# 	--max-model-len 32000 \
# 	--served-model-name ${VLLM_MODEL} \
# 	> ${HOSTNAME}.vllm.log 2>&1 &

vllm_pid=$!

unset HTTP_PROXY
unset HTTPS_PROXY
unset http_proxy
unset https_proxy

echo "$(date) ${HOSTNAME} TSB Waiting for vLLM..."
until curl -sf "http://${HOSTNAME}:${VLLM_HOST_PORT}/health" ; do
  sleep 2
done
echo "$(date) ${HOSTNAME} TSB vLLM ready!"

infile_base=$(basename $INFILE)
echo "$(date) ${HOSTNAME} TSB calling test.coli_v2.py on ${infile_base} using ${VLLM_MODEL}"

python -u ${SCRIPT_DIR}/../examples/TOM.COLI/test.coli_v2.py ${INFILE} ${HOSTNAME} \
	--batch-size 32 \
	--model ${VLLM_MODEL} \
	--port ${VLLM_HOST_PORT} \
	> ${infile_base}.${HOSTNAME}.test.coli_v2.txt 2>&1

test_exit_code=$?
echo "$(date) test.coli returned ${test_exit_code}"

# Kill the vllm server when the python script is done
kill -SIGINT "$vllm_pid"
