#!/bin/bash -x 
#
source /lus/flare/projects/datasets/softwares/testing/vllm-efforts/for_tom/env_gpt_oss_120b_12_03_2025.sh

export no_proxy="localhost,127.0.0.1"

curl -X POST "http://localhost:6739/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "openai/gpt-oss-120b",
        "prompt": "Explain protein structures.",
        "messages": [{"role": "user", "content": "Explain protein structures."}],
        "max_tokens": 1024,
        "temperature": 0
    }'
