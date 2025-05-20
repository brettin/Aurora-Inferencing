#!/bin/bash -l
# THis script works after ssh'ing into the head node of
# an interactive job. I source the env.sh before running it,
# though that shouldn't matter. But, it needs to be tested before
# merging with main.

# should replace this with $PBS_O_WORKDIR
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
HOSTNAME=$(hostname)
echo "$(date) TSB script directory is: $SCRIPT_DIR"
echo "$(date) TSB hostname: $HOSTNAME"

# contained in env.sh
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128

module load frameworks
conda activate /lus/flare/projects/candle_aesp_CNDA/brettin/conda_envs/vllm-20250520
module unload oneapi/eng-compiler/2024.07.30.002
module use /opt/aurora/24.180.3/spack/unified/0.8.0/install/modulefiles/oneapi/2024.07.30.002
module use /soft/preview/pe/24.347.0-RC2/modulefiles
module add oneapi/release

export NUMEXPR_MAX_THREADS=208
export HF_DATASETS_CACHE=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
export TRANSFORMERS_CACHE=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
export HF_HOME=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache

export TMPDIR=/tmp
export RAY_TMPDIR=/tmp
export ZE_FLAT_DEVICE_HIERARCHY=FLAT

# done conained in env.sh

export VLLM_HOST_IP=$(getent hosts $(hostname).hsn.cm.aurora.alcf.anl.gov | awk '{ print $1 }' | tr ' ' '\n' | sort | head -n 1)
export RAY_ADDRESS=$VLLM_HOST_IP:6379

echo "$(date) TSB starting ray on $VLLM_HOST_IP"

ray --logging-level info  start --head --verbose --node-ip-address=$VLLM_HOST_IP --port=6379 --num-cpus=64 --num-gpus=8
echo "$(date) TSB done starting ray on $VLLM_HOST_IP"

# vllm serve meta-llama/Llama-3.3-70B-Instruct --port 8000 --tensor-parallel-size 8 --device xpu --dtype float16 --trust-remote-code --max-model-len 32000 > $PBS_O_WORKDIR/$$.vllm.log &

echo "$(date) TSB starting vllm on host ${HOSTNAME}"
echo "$(date) TSB writing log to $SCRIPT_DIR/${HOSTNAME}.vllm.log"

python -u -m vllm.entrypoints.openai.api_server --host $(hostname) --model meta-llama/Llama-3.3-70B-Instruct --port 8000 --tensor-parallel-size 8 --device xpu --dtype float16 --trust-remote-code --max-model-len 32000 > ${SCRIPT_DIR}/${HOSTNAME}.vllm.log 2>&1

