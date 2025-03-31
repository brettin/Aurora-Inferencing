module use /soft/modulefiles
module load frameworks
module load xpu-smi
module load pti-gpu

export CANDLE_DATA_DIR=.
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128
git config --global http.proxy http://proxy.alcf.anl.gov:3128

export NUMEXPR_MAX_THREADS=208
export HF_DATASETS_CACHE=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
export TRANSFORMERS_CACHE=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
export HF_HOME=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache

# export PS1="\u@\h: "
