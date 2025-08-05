export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128

module load frameworks
conda activate /lus/flare/projects/candle_aesp_CNDA/brettin/conda_envs/vllm-20250520

module unload oneapi/eng-compiler/2024.07.30.002
module use /opt/aurora/24.180.3/spack/unified/0.8.0/install/modulefiles/oneapi/2024.07.30.
module use /soft/preview/pe/24.347.0-RC2/modulefiles
module add oneapi/release

echo "running on host $(hostname), rank ${PMIX_RANK}, xpu ${ZE_AFFINITY_MASK}"

SCRIPT_DIR="/lus/flare/projects/candle_aesp_CNDA/brettin/Aurora-Inferencing/serverless-test"
python ${SCRIPT_DIR}/simple_test.py ${SCRIPT_DIR}/${PMIX_RANK}.in ${SCRIPT_DIR}/${PMIX_RANK}.out 
