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




(/rbscratch/brettin/conda_envs/vLLM) brettin@rbdgx1:/rbscratch/brettin/Aurora-Inferencing/examples/TOM.COLI$ time ./test.coli.async.sh

Script directory: /rbscratch/brettin/Aurora-Inferencing/examples/TOM.COLI
Hostfile path: /rbscratch/brettin/Aurora-Inferencing/examples/TOM.COLI/../../vllm-0.6.6.post2/hostfile
Enter the number of directories to process (0 to N-1): 120

python ./test.coli.async.py --port 9999 --host rbdgx2 --key CELS --num_prompts 38 --dir 0 > test.coli.async.38.log

...

python ./test.coli.async.py --port 9999 --host rbdgx2.cels.anl.gov --key CELS --num_prompts 38 --dir 119 > test.coli.async.119.log
Waiting for batch to complete...
All directories have been processed

real	51m55.634s
user	1m15.424s
sys	0m21.632s






### Time to start 20 servers

-------------------
Starting server tests...
----------------------------------------
Summary:
Total hosts tested: 20
Servers UP: 20
Servers DOWN: 0
----------------------------------------
All vLLM servers are up and running

aurora-pbs-0001.hostmgmt.cm.aurora.alcf.anl.gov: 
                                                                 Req'd  Req'd   Elap
Job ID               Username Queue    Jobname    SessID NDS TSK Memory Time  S Time
-------------------- -------- -------- ---------- ------ --- --- ------ ----- - -----
3905960.aurora-pbs-* brettin  debug-s* submit_al*  74281  20 41*    --  01:00 R 00:34
