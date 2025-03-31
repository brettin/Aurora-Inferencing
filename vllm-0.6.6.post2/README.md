
To build the conda environment, see the install.sh script. You will need to change the
name of the conda environment. I use --prefix to name the conda environment, but using
--name is fine too. I use --prefix so that I can control the location of the conda env.

```
./install.sh
```



###
This error occurs when running on on an interactive node. It does not occur when running from a terminal session that was not initiated by qsub -I.

OSError: AF_UNIX path length cannot exceed 107 bytes: '/var/tmp/pbs.3774485.aurora-pbs-0001.hostmgmt.cm.aurora.alcf.anl.gov/ray/session_2025-03-31_17-02-50_053952_74995/sockets/plasma_store'

###
This was produced when launching llama 70B with the following command.

vllm serve meta-llama/Llama-3.3-70B-Instruct --port 8000 --tensor-parallel-size 8 --device xpu --dtype float16 --trust-remote-code

# This ran the xpu out of memory on start
INFO 03-31 15:48:41 distributed_gpu_executor.py:61] Maximum concurrency for 131072 tokens per request: 8.23x

# This loaded when I set --max-model-len 3200
INFO 03-31 15:52:04 distributed_gpu_executor.py:61] Maximum concurrency for 3200 tokens per request: 337.01x
