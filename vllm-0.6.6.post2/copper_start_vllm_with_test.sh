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
#conda activate /lus/flare/projects/candle_aesp_CNDA/brettin/conda_envs/vllm-20250520
module unload oneapi/eng-compiler/2024.07.30.002
module use /opt/aurora/24.180.3/spack/unified/0.8.0/install/modulefiles/oneapi/2024.07.30.002
module use /soft/preview/pe/24.347.0-RC2/modulefiles
module add oneapi/release

export tiles=12
export ZE_FLAT_DEVICE_HIERARCHY=FLAT
export NUMEXPR_MAX_THREADS=208

mkdir -p /tmp/${USER}/copper
COPPER_MOUNT=/tmp/${USER}/copper
module load copper
launch_copper.sh -M 20GB
conda activate ${COPPER_MOUNT}/lus/flare/projects/candle_aesp_CNDA/brettin/conda_envs/vllm-20250520

# You need to change these because you need write perms on the dirs.
export HF_DATASETS_CACHE=${COPPER_MOUNT}/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
export TRANSFORMERS_CACHE=${COPPER_MOUNT}/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
export HF_HOME=${COPPER_MOUNT}/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
export HF_MODULES_CACHE=${COPPER_MOUNT}/lus/flare/projects/candle_aesp_CNDA/brettin/.cache

export TMPDIR=/tmp
export RAY_TMPDIR=/tmp
export VLLM_HOST_IP=$(getent hosts $(hostname).hsn.cm.aurora.alcf.anl.gov | awk '{ print $1 }' | tr ' ' '\n' | sort | head -n 1)
export RAY_ADDRESS=$VLLM_HOST_IP:6379
export VLLM_HOST_PORT=8000
export VLLM_MODEL="meta-llama/Llama-3.1-8B-Instruct"
# export VLLM_MODEL="meta-llama/Llama-3.3-70B-Instruct"



# export HF_HUB_OFFLINE=1
# export VLLM_MODEL=${COPPER_MOUNT}/lus/flare/projects/candle_aesp_CNDA/brettin/.cache/models--meta-llama--Llama-3.1-8B-Instruct



# Done setting up environment and variables.

echo "$(date) ${HOSTNAME} TSB starting ray on $VLLM_HOST_IP"
ray --logging-level info  start --head --verbose --node-ip-address=$VLLM_HOST_IP --port=6379 --num-cpus=64 --num-gpus=$tiles
echo "$(date) ${HOSTNAME} TSB done starting ray on $VLLM_HOST_IP"

echo "$(date) ${HOSTNAME} TSB starting vllm with ${VLLM_MODEL} on host ${HOSTNAME}"
echo "$(date) ${HOSTNAME} TSB writing log to $SCRIPT_DIR/${HOSTNAME}.vllm.log"

#vllm serve ${VLLM_MODEL} --port ${VLLM_HOST_PORT} --tensor-parallel-size 8 --device xpu --dtype float16 --trust-remote-code --max-model-len 32000 > $SCRIPT_DIR/${HOSTNAME}.vllm.log 2>&1 &

# Use this if you want more verbose output to debug starting vllm.
VLLM_SERVED_MODEL_NAME=Llama-3.1-8B-Instruct
python -u -m vllm.entrypoints.openai.api_server \
	--host $(hostname) \
	--model ${VLLM_MODEL} \
	--port ${VLLM_HOST_PORT} \
	--tensor-parallel-size 8 \
	--device xpu --dtype float16 \
	--trust-remote-code \
	--max-model-len 32000 \
	--served-model-name ${VLLM_SERVED_MODEL_NAME} \
	> ${HOSTNAME}.vllm.log 2>&1 &

vllm_pid=$!

unset HTTP_PROXY
unset HTTPS_PROXY
unset http_proxy
unset https_proxy

echo "$(date) ${HOSTNAME} TSB Waiting for vLLM..."
until curl -sf "http://${HOSTNAME}:${VLLM_HOST_PORT}/health" >/dev/null ; do
  sleep 2
done
echo "$(date) ${HOSTNAME} TSB vLLM ready!"

infile_base=$(basename $INFILE)
echo "$(date) ${HOSTNAME} TSB calling test.coli_v2.py on ${infile_base} using ${VLLM_MODEL}"
python -u ${SCRIPT_DIR}/../examples/TOM.COLI/test.coli_v2.py ${INFILE} ${HOSTNAME} \
	--batch-size 32 \
	--model ${VLLM_SERVED_MODEL_NAME} \
	--port ${VLLM_HOST_PORT} \
	> ${infile_base}.${HOSTNAME}.test.coli_v2.txt 2>&1

test_exit_code=$?
echo "$(date) test.coli returned ${test_exit_code}"

# Kill the vllm server when the python script is done
kill -SIGINT "$vllm_pid"

# Move the results to the shared fs

