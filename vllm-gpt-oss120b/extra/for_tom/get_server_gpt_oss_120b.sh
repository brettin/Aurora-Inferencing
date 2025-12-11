#!/bin/bash -x
#
source /lus/flare/projects/datasets/softwares/testing/vllm-efforts/for_tom/env_gpt_oss_120b_12_03_2025.sh

OCL_ICD_FILENAMES="libintelocl.so" VLLM_DISABLE_SINKS=1 vllm serve openai/gpt-oss-120b \
  --dtype bfloat16 \
  --tensor-parallel-size 8 \
  --enforce-eager \
  --distributed-executor-backend mp \
  --trust-remote-code \
  --port 6739
