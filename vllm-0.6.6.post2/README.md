
To build the conda environment, see the install.sh script. You will need to change the
name of the conda environment. I use --prefix to name the conda environment, but using
--name is fine too. I use --prefix so that I can control the location of the conda env.
I highly recommend building the environment on a compute node as this has not been tested
on a login node.

```
./install.sh
```

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

