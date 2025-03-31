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
export HSN_IP_ADDRESS=$(getent hosts "$(hostname).hsn.cm.aurora.alcf.anl.gov" | awk '{ print $1 }' | sort | head -n 1)
export VLLM_HOST_IP="$HSN_IP_ADDRESS"

export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128
git config --global http.proxy http://proxy.alcf.anl.gov:3128

[ -z "$HF_TOKEN" ] && export HF_TOKEN="some_default"

export HF_DATASETS_CACHE=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
export TRANSFORMERS_CACHE=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
export HF_HOME=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache
HF_MODULES_CACHE=/lus/flare/projects/candle_aesp_CNDA/brettin/.cache

export TMPDIR="/tmp"
export RAY_TMPDIR="/tmp"
export VLLM_IMAGE_FETCH_TIMEOUT=60
ulimit -c unlimited

echo "$(date) starting ray"
ray start --head --num-gpus 8 --num-cpus 64
echo "$(date) done starting ray"

#model="google/txgemma-2b-predict"
#model="google/gemma-3-27b-it"
#model=mistralai/Mistral-7B-Instruct
#model=meta-llama/Llama-3.2-3B-Instruct-QLORA_INT4_EO8
model=meta-llama/Llama-3.1-8B-Instruct
port=8000

echo "$(date) starting vllm server with ${model}"

python -m vllm.entrypoints.openai.api_server --model  ${model} --port 8000 --device xpu --dtype float16 --trust-remote-code  --chat-template /home/brettin/candle_aesp_CNDA/brettin/Aurora-Inferencing/vllm/llama-3-chat.tmpl

#python -m vllm.entrypoints.openai.api_server --model  meta-llama/Llama-3.1-405B-Instruct --port 8000 --tensor-parallel-size 8 --pipeline-parallel-size 2 --device xpu --dtype float16 --trust-remote-code --max-model-len 1024

#python -m vllm.entrypoints.openai.api_server --model mistralai/Mistral-7B-Instruct --port 8000  --device xpu --dtype float16 --trust-remote-code

# default max-model-len is 131072
#ZE_AFFINITY_MASK=1.0,2.0,3.0,4.0,5.0,6.0,7.0
# python -m vllm.entrypoints.openai.api_server --model meta-llama/Llama-3.3-70B-Instruct --port 8000  --device xpu --dtype float16 --trust-remote-code --chat-template /home/brettin/candle_aesp_CNDA/brettin/Aurora-Inferencing/vllm/llama-3-chat.tmpl --tensor-parallel 8 --max-model-len 64000

# python -m vllm.entrypoints.openai.api_server --model meta-llama/Meta-Llama-3-8B --port 8000  --device xpu --dtype float16 --trust-remote-code --chat-template /home/brettin/candle_aesp_CNDA/brettin/Aurora-Inferencing/vllm/llama-3-chat.tmpl

# python -m vllm.entrypoints.openai.api_server --model google/gemma-3-27b-it --port 8000  --device xpu --dtype float16 --trust-remote-code

#python -m vllm.entrypoints.openai.api_server --model google/txgemma-2b-predict --port 8000  --device xpu --dtype float16 --trust-remote-code &

echo "$(date) vllm server started serving $model on $port."


