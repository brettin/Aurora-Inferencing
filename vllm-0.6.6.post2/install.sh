export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128

module load frameworks
conda create --prefix /lus/flare/projects/candle_aesp_CNDA/brettin/conda_envs/vllm-0.6.6 python=3.10 -y
conda activate /lus/flare/projects/candle_aesp_CNDA/brettin/conda_envs/vllm-0.6.6

module unload oneapi/eng-compiler/2024.07.30.002
module use /opt/aurora/24.180.3/spack/unified/0.8.0/install/modulefiles/oneapi/2024.07.30.002
module use /soft/preview/pe/24.347.0-RC2/modulefiles
module add oneapi/release

pip install /flare/datasets/softwares/vllm-install/wheels/*
pip install /flare/datasets/softwares/vllm-install/vllm-0.6.6.post2.dev28+g5dbf8545.d20250129.xpu-py3-none-any.whl
