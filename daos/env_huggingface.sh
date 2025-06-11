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

export HF_DATASETS_CACHE=/tmp/$DAOS_POOL/$DAOS_CONT
export TRANSFORMERS_CACHE=/tmp/$DAOS_POOL/$DAOS_CONT
export HF_HOME=/tmp/$DAOS_POOL/$DAOS_CONT
export HF_MODULES_CACHE=/tmp/$DAOS_POOL/$DAOS_CONT
