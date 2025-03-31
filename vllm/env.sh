module load frameworks
conda activate /lus/flare/projects/candle_aesp_CNDA/brettin/conda_envs/vllm_scaling
module unload oneapi/eng-compiler/2024.07.30.002
module use /opt/aurora/24.180.3/spack/unified/0.8.0/install/modulefiles/oneapi/2024.07.30.002
module use /soft/preview/pe/24.347.0-RC2/modulefiles
module add oneapi/release

export TORCH_LLM_ALLREDUCE=1
export CCL_ZE_IPC_EXCHANGE=drmfd
export ZE_FLAT_DEVICE_HIERARCHY=FLAT
export TORCH_LLM_ALLREDUCE=1
export CCL_ZE_IPC_EXCHANGE=drmfd
export ZE_FLAT_DEVICE_HIERARCHY=FLAT

export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128
git config --global http.proxy http://proxy.alcf.anl.gov:3128

[ -z "$HF_TOKEN" ] && export HF_TOKEN="some_default"

HF_DATASETS_CACHE=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
TRANSFORMERS_CACHE=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
HF_HOME=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
HF_MODULES_CACHE=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache

ulimit -c unlimited
