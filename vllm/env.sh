#!/bin/bash
# Environment setup for vLLM on Aurora
# Source this file to configure your environment: source env.sh

# Proxy settings for downloading from HuggingFace (if needed)
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128

# Load the frameworks module (contains all vLLM dependencies)
module load frameworks

# Intel GPU configuration
export tiles=12
export ZE_FLAT_DEVICE_HIERARCHY=FLAT

# Thread and process configuration
export NUMEXPR_MAX_THREADS=208
export CCL_PROCESS_LAUNCHER=torchrun
unset ONEAPI_DEVICE_SELECTOR
unset OMP_NUM_THREADS

# Temporary directory configuration
export TMPDIR=/tmp
export RAY_TMPDIR=/tmp
export HF_HOME=/tmp/hf_home

# HuggingFace offline mode (use pre-downloaded models)
export HF_HUB_OFFLINE=1
