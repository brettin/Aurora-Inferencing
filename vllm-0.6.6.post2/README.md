
To build the conda environment, see the install.sh script. You will need to change the
name of the conda environment. I use --prefix to name the conda environment, but using
--name is fine too. I use --prefix so that I can control the location of the conda env.
I highly recommend building the environment on a compute node as this has not been tested
on a login node.

```
# to get an interactive node. You might have to change the allocation given to the -A option.
qsub -l select=10 -A candle_aesp_CNDA -q debug-scaling -l filesystems=flare:home -l walltime=60:00 -I

cd Aurora-Inferencing/vllm-06.6.post2/
./install.sh
```

Running multiple servers.
From the interactive terminal, set up the environment and then launch the vllm servers.

```
source env.sh
./start_all_p.sh
```

I don't yet have a good way to check to see that all of the servers are running. Right now,
I grep the log file looking for Uvicorn running

```
grep -c "Uvicorn running" start_all_p.log
```

There is an example in examples/TOM.COLI/test.coli.py



Running one server.
To start the vllm server on the compute node of an interactive job, ssh from the head
node into your interactive node. It's important to start vllm from this new window and
not the window that was provided by the qsub -I command. That command is doing something
funky with host names and socket names <b>(see Note 1 below)</b>.

```
./start_vllm.sh
```

Now you can run a test. The text can be run from any terminal that is logged into the
compute host. Be sure to unset the http proxy variables as those mess up network routing.

```
source unset_proxy.sh
python ./test.python.openai.py --host localhost --port 8000 --model meta-llama/Llama-3.3-70B-Instruct
```

#### Note 1:
This error occurs when running from the terminal session that starts when submitting an interactive job
to PBS. It does not occur when running from a terminal session that was not initiated by qsub.

OSError: AF_UNIX path length cannot exceed 107 bytes: '/var/tmp/pbs.3774485.aurora-pbs-0001.hostmgmt.cm.aurora.alcf.anl.gov/ray/session_2025-03-31_17-02-50_053952_74995/sockets/plasma_store'


qsub -l select=2 -A candle_aesp_CNDA -q debug -l filesystems=flare:home -l walltime=60:00 -I
cd $HOME/candle_aesp_CNDA/brettin/Aurora-Inferencing/vllm-0.6.6.post2
source env.sh
./start_all_p.sh

