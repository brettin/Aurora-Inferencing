This was produced when launching llama 70B with the following command.

vllm serve meta-llama/Llama-3.3-70B-Instruct --port 8000 --tensor-parallel-size 8 --device xpu --dtype float16 --trust-remote-code

# This ran the xpu out of memory on start
INFO 03-31 15:48:41 distributed_gpu_executor.py:61] Maximum concurrency for 131072 tokens per request: 8.23x

# This loaded when I set --max-model-len 3200
INFO 03-31 15:52:04 distributed_gpu_executor.py:61] Maximum concurrency for 3200 tokens per request: 337.01x
