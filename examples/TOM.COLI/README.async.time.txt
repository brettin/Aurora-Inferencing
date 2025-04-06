(/rbscratch/brettin/conda_envs/vLLM) brettin@rbdgx1:/rbscratch/brettin/Aurora-Inferencing/examples/TOM.COLI$ time python ./test.coli.async.py --port 9999 --host rbdgx2 --key CELS --num_prompts 10 --dir 0 > test.coli.async.10.log

real	1m21.103s
user	0m0.634s
sys	0m0.181s
(/rbscratch/brettin/conda_envs/vLLM) brettin@rbdgx1:/rbscratch/brettin/Aurora-Inferencing/examples/TOM.COLI$ time python ./test.coli.async.py --port 9999 --host rbdgx2 --key CELS --num_prompts 19 --dir 0 > test.coli.async.19.log

real	0m46.075s
user	0m0.641s
sys	0m0.188s
(/rbscratch/brettin/conda_envs/vLLM) brettin@rbdgx1:/rbscratch/brettin/Aurora-Inferencing/examples/TOM.COLI$ time python ./test.coli.async.py --port 9999 --host rbdgx2 --key CELS --num_prompts 38 --dir 0 > test.coli.async.38.log

real	0m25.148s
user	0m0.648s
sys	0m0.183s
