# Table of Contents
1. [Overview](#overview)
2. [Installation](#installation)
3. [Running](#running)
4. [How It Works](#how-it-works)

# Overview

This script is designed to run the `test.coli_v2.py` Python script across multiple files and hosts in a controlled, parallel manner. It ensures that only one test.coli_v2.py process runs on each host at any given time, while maximizing throughput by processing files in parallel batches.

# Installation

1. Clone the github repository

   ```
   git clone https://github.com/brettin/Aurora-Inferencing
   ```

2. Make the install script executable:

   ```
   cd Aurora-Inferencing/vllm-0.6.6.post2
   chmod +x install.sh
   ```

3. Edit install.sh to contain the name or prefix of the new conda env.

4. Run the install.sh script

   ```
   ./install.sh
   ```

# Running

1. Submit the submit script. Edit PBS directives for more or fewer servers.
   Watch for the servers to start. The test_servers.sh script needs work.
   Launch inferencing code. See examples directory.


   ```
   cd Aurora-Inferencing/vllm-0.6.6.post2
   vi submit_with_test.sh
   qsub ./submit_with_test.sh
   ```

   The submit script launches the servers. Then launches the python script.

   To use copper, use the copper_submit_with_test.sh script.

   ```
   cd Aurora-Inferencing/vllm-0.6.6.post2
   vi copper_submit_with_test.sh
   qsub ./copper_submit_with_test.sh
   ```

3. The script will:
   - Read the hostfile to determine available hosts
   - Process files in batches equal to the number of available hosts
   - Wait for each batch to complete before starting the next batch
   - Continue until all directories have been processed

# How It Works

Yet to be finalized.

Call stack:
```
   submit_with_test.sh (PBS job)
   ├── SSH process 1 (background)
   │   └── start_vllm_with_test.sh (foreground)
   │       ├── ray start (goes to background once it starts)
   │       ├── vllm serve (background)
   |       └── python ../examples/TOM.COLI/test.coli_v2.py
   ├── SSH process 2 (background)
   │   └── start_vllm_with_test.sh (foreground)
   │       ├── ray start (goes to background once it starts)
   │       ├── vllm serve (background)
   |       └── python ../examples/TOM.COLI/test.coli_v2.py
   └── ... (more SSH processes)
```
## Example Flow
If you have 5 hosts and 12 directories:
1. First batch: Directories 0-4 run on hosts 0-4
2. After these complete, second batch: Directories 5-9 run on hosts 0-4
3. After these complete, final batch: Directories 10-11 run on hosts 0-1

This approach efficiently distributes the workload while ensuring no host is overloaded with multiple simultaneous processes.

