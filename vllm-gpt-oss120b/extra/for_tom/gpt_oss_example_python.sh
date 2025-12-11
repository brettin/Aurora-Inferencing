#!/bin/bash -x
#
#
BENCH_DIR=/lus/flare/projects/datasets/softwares/testing/vllm-efforts
source ${BENCH_DIR}/env_gpt_oss_120b_12_03_2025.sh

OCL_ICD_FILENAMES="libintelocl.so" VLLM_DISABLE_SINKS=1 python ${BENCH_DIR}/for_tom/example_gpt_oss_120b.py
