# Table of Contents
1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Running](#running)
4. [How It Works](#how-it-works)
5. [Revisions](#revisions)

# Overview

This directory contains scripts for running vLLM (Large Language Model serving) on Aurora. The system is designed to run the `test.coli_v2.py` Python script across multiple files and hosts in a controlled, parallel manner. It ensures that only one vLLM server and test.coli_v2.py process runs on each host at any given time, while maximizing throughput by processing files in parallel batches.

# Prerequisites

All required dependencies are included in the `frameworks` module on Aurora. No additional installation is needed.

Simply clone the repository to get started:

```
git clone https://github.com/brettin/Aurora-Inferencing
cd Aurora-Inferencing/vllm
```

The scripts will automatically load the `frameworks` module which includes vLLM and all necessary dependencies.

# Running

1. Navigate to the vllm directory:

   ```
   cd Aurora-Inferencing/vllm
   ```

2. Edit the submit script to configure PBS directives (number of nodes, walltime, etc.):

   ```
   vi submit_with_test.sh
   ```

3. Submit the job:

   ```
   qsub ./submit_with_test.sh
   ```

   The submit script will:
   - Launch vLLM servers on the allocated nodes
   - Start the inferencing code on each node
   - Process files in parallel batches

4. Monitor the job progress. The script will:
   - Read the hostfile to determine available hosts
   - Map one input file to one host
   - Process file batches in parallel
   - Continue until all files have been processed

# How It Works

## Call Stack

The system uses a hierarchical process structure:

```
submit_with_test.sh (PBS job)
├── SSH process 1 (background)
│   └── start_vllm_with_test.sh (foreground)
│       ├── ray start (background daemon)
│       ├── vllm serve (background server)
│       └── python ../examples/TOM.COLI/test.coli_v2.py (foreground)
├── SSH process 2 (background)
│   └── start_vllm_with_test.sh (foreground)
│       ├── ray start (background daemon)
│       ├── vllm serve (background server)
│       └── python ../examples/TOM.COLI/test.coli_v2.py (foreground)
└── ... (additional SSH processes for remaining nodes)
```

## Process Flow

1. **Job Submission**: The PBS job allocates nodes and creates a hostfile
2. **Model Staging**: Model weights are copied to `/tmp` on each node using MPI
3. **Parallel Launch**: For each node, an SSH connection launches `start_vllm_with_test.sh`
4. **Server Setup**: Each node starts Ray and vLLM server
5. **Inferencing**: Once the server is ready, the test script processes its assigned input file
6. **Cleanup**: Results are archived from `/dev/shm` to the shared filesystem
7. **Completion**: The main job waits for all parallel processes to complete

# Revisions

## November 2025 - Directory Cleanup and Rename

**Changes made:**
- Renamed directory from `vllm-0.6.6.post2` to `vllm`
- Updated README documentation with clearer structure and updated directory paths
- Removed `install.sh` - all dependencies are now available through the `frameworks` module
- Removed copper-specific scripts (`copper_start_vllm_with_test.sh` and `copper_submit_with_test.sh`) as they are not needed
- Cleaned up `env.sh` to match the environment configuration in `start_vllm_with_test.sh`
- Updated `SCRIPT_DIR` paths in `submit.sh` and `submit_with_test.sh`
- Updated `HOSTFILE` paths in examples scripts (`test.coli.sh`, `test.coli.async.sh`, `test.coli_v3.sh`)

**Tagged as:** `before-vllm-cleanup`

**To revert these changes:**

If you need to return to the state before this cleanup, you can use the git tag:

```bash
# View the tagged commit
git show before-vllm-cleanup

# Reset to the tagged state (WARNING: this will discard uncommitted changes)
git reset --hard before-vllm-cleanup

# Or create a new branch from the tagged state
git checkout -b restore-branch before-vllm-cleanup
```

