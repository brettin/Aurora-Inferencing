# Table of Contents
1. [Overview](#overview)
2. [Installation](#installation)
3. [Running](#running)
4. [How It Works](#how-it-works)

# Overview

This script is designed to run the `test.coli.py` Python script across multiple directories and hosts in a controlled, parallel manner. It ensures that only one test.coli.py process runs on each host at any given time, while maximizing throughput by processing directories in parallel batches.

# Installation

1. Place the script in the same directory as your `test.coli.py` file
2. Make the script executable:
   ```bash
   chmod +x run_tests.sh
   ```
3. Ensure you have a valid hostfile in the same directory containing the list of hosts to use
4. Verify that `test.coli.py` is executable:
   ```bash
   chmod +x test.coli.py
   ```

# Running

1. Execute the script:
   ```bash
   ./run_tests.sh
   ```
2. When prompted, enter the number of directories to process (0 to N-1)
3. The script will:
   - Read the hostfile to determine available hosts
   - Process directories in batches equal to the number of available hosts
   - Wait for each batch to complete before starting the next batch
   - Continue until all directories have been processed

# How It Works

## Setup and Initialization
1. The script first determines its own directory location and the path to the hostfile
2. It performs validation checks:
   - Ensures the hostfile exists and is not empty
   - Verifies that test.coli.py exists and is executable
3. It prompts the user to enter the number of directories to process
4. It reads all hostnames from the hostfile into an array

## Batch Processing Logic
The core of the script uses a nested loop structure to process directories in batches:

1. **Outer Loop**: Iterates through directories in batches of NUM_HOSTS
   ```bash
   for ((d=0; d<NUM_DIRS; d+=NUM_HOSTS)); do
   ```
   This ensures we process directories in groups equal to the number of available hosts

2. **Inner Loop**: For each batch, launches up to NUM_HOSTS processes
   ```bash
   for ((i=0; i<NUM_HOSTS && d+i<NUM_DIRS; i++)); do
   ```
   The condition `d+i<NUM_DIRS` prevents processing beyond the total number of directories

3. **Process Launch**: For each directory-host pair:
   - Calculates the actual directory number: `dir=$((d+i))`
   - Selects the appropriate host: `host=${HOSTS[$i]}`
   - Launches test.coli.py with these parameters in the background: `python "$SCRIPT_DIR/test.coli.py" "$dir" "$host" &`

4. **Batch Completion**: After launching all processes in a batch:
   ```bash
   wait
   ```
   This command waits for all background processes to complete before moving to the next batch

## Example Flow
If you have 5 hosts and 12 directories:
1. First batch: Directories 0-4 run on hosts 0-4
2. After these complete, second batch: Directories 5-9 run on hosts 0-4
3. After these complete, final batch: Directories 10-11 run on hosts 0-1

This approach efficiently distributes the workload while ensuring no host is overloaded with multiple simultaneous processes.

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

