#!/bin/bash -x 
#

export HF_TOKEN="YOURTOKEN"

## Proxies to clone from a compute node
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
#

module load pti-gpu
module load hdf5

## This has vllm_0.11.x our built wheel
source /opt/aurora/25.190.0/spack/unified/0.10.1/install/linux-sles15-x86_64/gcc-13.3.0/miniforge3-24.3.0-0-gfganax/bin/activate
## Our build triton
conda activate /lus/flare/projects/datasets/softwares/envs/conda_envs/RC1_vllm_0.11.x_triton_3.5.0+git1b0418a9_no_patch_oneapi_2025.2.0_numpy_2.3.4_python3.12.8

export HF_HOME="/lus/flare/projects/datasets/model-weights"
export HF_DATASETS_CACHE="/lus/flare/projects/datasets/model-weights"
export HF_MODULES_CACHE="/lus/flare/projects/datasets/model-weights"
#export HF_TOKEN="YOUR_HF_TOKEN"
export RAY_TMPDIR="/tmp"
export TMPDIR="/tmp"

export ZE_FLAT_DEVICE_HIERARCHY=FLAT

## For -tp >= 2
unset CCL_PROCESS_LAUNCHER
export CCL_PROCESS_LAUNCHER=None
## Must Have
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export FI_MR_CACHE_MONITOR=userfaultfd

## From Julia
unset ONEAPI_DEVICE_SELECTOR

#BENCH_DIR=/lus/flare/projects/datasets/softwares/testing/vllm-efforts
#export VLLM_TORCH_PROFILER_DIR=/lus/flare/projects/datasets/softwares/testing/vllm-efforts/profiles/llama3_8b
export TOKENIZERS_PARALLELISM=false
export VLLM_LOGGING_LEVEL=DEBUG
export OCL_ICD_FILENAMES="libintelocl.so"

echo "=== HOSTNAMEs ==="
printenv | grep "HOSTNAME"
echo "=== HOSTNAMEs ==="

ray stop -f
#export VLLM_HOST_IP=$(getent hosts $(hostname).hsn.cm.aurora.alcf.anl.gov | awk '{ print $1 }' | tr ' ' '\n' | sort | head -n 1)
#echo "VLLM_HOST_IP = ${VLLM_HOST_IP}"
#export tiles=12
#ray --logging-level debug start --head --verbose --node-ip-address=$VLLM_HOST_IP --port=6379 --num-cpus=64 --num-gpus=$tiles&
#
#export RAY_ADDRESS=$VLLM_HOST_IP:6379
#
export no_proxy="localhost,127.0.0.1" #Set no_proxy for the client to interact with the locally hosted model

export VLLM_HOST_IP=$(getent hosts $(hostname).hsn.cm.aurora.alcf.anl.gov | awk '{ print $1 }' | tr ' ' '\n' | sort | head -n 1)
