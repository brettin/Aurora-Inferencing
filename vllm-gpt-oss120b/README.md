# GPT-OSS-120B vLLM Multi-Node Deployment

This directory contains scripts for deploying and running the GPT-OSS-120B model using vLLM across multiple compute nodes on Aurora.

## Quick Start

### Prerequisites

- Access to Aurora compute nodes via PBS
- Input files in `../examples/TOM.COLI/batch_1/`
- GPT-OSS-120B model weights at `/lus/flare/projects/datasets/model-weights/hub/models--openai--gpt-oss-120b`

### Basic Usage

1. **Submit a job with default settings:**
   ```bash
   qsub submit_oss120b_with_test.sh
   ```

2. **Submit with custom offset (for resuming from a specific file):**
   ```bash
   qsub -v OFFSET=10 submit_oss120b_with_test.sh
   ```

3. **Submit without model weight staging:**
   ```bash
   qsub -v STAGE_WEIGHTS=0 submit_oss120b_with_test.sh
   ```

4. **Monitor job progress:**
   ```bash
   tail -f output.log
   ```

### Environment Variables

You can customize the job behavior by setting these environment variables when submitting:

| Variable | Default | Description |
|----------|---------|-------------|
| `OFFSET` | 0 | Starting file index for batch processing (useful for resuming) |
| `STAGE_WEIGHTS` | 1 | Whether to stage model weights to /tmp (1=yes, 0=no) |

### Output

- **Job logs:** `output.log` and `error.log`
- **Results archives:** `<hostname>_results_<timestamp>.tar.gz` (one per node)
- **Hostfile:** `hostfile` (list of allocated nodes)

---

## How the Code Works

### Architecture Overview

The deployment system consists of two main scripts:

1. **`submit_oss120b_with_test.sh`** - PBS job submission script (this file)
   - Orchestrates multi-node deployment
   - Manages batch processing of input files
   - Monitors execution and collects results

2. **`start_oss120b_with_test.sh`** - Per-node execution script
   - Starts vLLM server on a compute node
   - Runs inference tests
   - Archives results

### Workflow

#### 1. Job Initialization

When the PBS job starts:
- Reads allocated nodes from `$PBS_NODEFILE`
- Validates the input directory exists
- Creates hostname array from nodefile

#### 2. Model Weight Staging (Optional)

If `STAGE_WEIGHTS=1`:
- Compiles `cptotmp.c` utility for efficient file copying
- Uses MPI to copy model weights from shared filesystem to `/tmp` on each node
- Improves I/O performance by reducing network filesystem load

**Why staging?** Large models on shared filesystems can create I/O bottlenecks. Staging to local `/tmp` provides faster access.

#### 3. Input File Distribution

The script processes input files from `INPUT_DIR` in batch mode:

```
Total files: 100
Allocated nodes: 2
OFFSET: 0

Result: Files 0-1 distributed to 2 nodes
```

**Load Balancing:**
- Each node gets exactly one input file
- Number of files processed = `min(available_files, available_nodes)`
- The `OFFSET` parameter enables resuming from a specific file index

#### 4. Parallel Deployment

For each allocated node:
1. Assigns an input file: `filenames[OFFSET + node_index]`
2. SSH to the node and execute `start_oss120b_with_test.sh <input_file>`
3. Launch happens in background (parallel execution)
4. 2-second delay between launches to avoid overwhelming the system

#### 5. Monitoring and Results

The script waits for all background processes to complete:
- Tracks success/failure for each node
- Captures exit codes
- Displays deployment summary

### Configuration

All configurable parameters are centralized at the top of the script:

**Directories:**
- `SCRIPT_DIR`: Location of this script
- `INPUT_DIR`: Batch input files location
- `MODEL_PATH`: Path to model weights

**Operation Settings:**
- `OFFSET`: Starting file index (default: 0)
- `STAGE_WEIGHTS`: Enable/disable weight staging (default: 1)

**Timing Settings:**
- `SSH_TIMEOUT`: SSH connection timeout (default: 10 seconds)
- `LAUNCH_DELAY`: Delay between node launches (default: 2 seconds)

### File Assignment Example

With 5 input files and 2 nodes, `OFFSET=0`:

```
Node 1: file[0] = chunk_0000.txt
Node 2: file[1] = chunk_0001.txt
(files 2-4 not processed this run)
```

To process the remaining files in a second job:
```bash
qsub -v OFFSET=2 submit_oss120b_with_test.sh
```

This assigns:
```
Node 1: file[2] = chunk_0002.txt
Node 2: file[3] = chunk_0003.txt
```

### Error Handling

The script includes several validation checks:

1. **Input directory validation**: Exits if directory not found
2. **Offset validation**: Ensures OFFSET < total_files
3. **SSH failure handling**: Reports failed node launches
4. **Exit code tracking**: Monitors each node's completion status

### PBS Configuration

The script requests:
- **Queue:** `debug-scaling`
- **Nodes:** 2 (configurable via `#PBS -l select=`)
- **Walltime:** 1 hour
- **Filesystems:** `flare:home`
- **Node placement:** `scatter` (spreads nodes across racks)

### Functions

**`start_vllm_on_host(host, filename)`**
- Connects to remote host via SSH
- Changes to script directory
- Executes `start_oss120b_with_test.sh` with the input file
- Returns 1 on failure, 0 on success

### Execution Flow Diagram

```
PBS Job Start
    ↓
Initialize & Validate
    ↓
Stage Weights? → Yes → MPI Copy to /tmp
    ↓                        ↓
    No ←─────────────────────┘
    ↓
Load Input Files
    ↓
Calculate File Distribution
    ↓
For Each Node:
    - Assign Input File
    - SSH & Launch vLLM
    - Track PID
    ↓
Wait for All Nodes
    ↓
Collect Results
    ↓
Display Summary
    ↓
Exit
```

---

## Troubleshooting

### Common Issues

**Problem:** "Input directory not found"
- **Solution:** Verify `INPUT_DIR` path exists and contains files

**Problem:** "No files to process"
- **Solution:** Check that `OFFSET` is less than the total number of input files

**Problem:** SSH connection failures
- **Solution:** Verify nodes are accessible and `SCRIPT_DIR` path is correct on compute nodes

**Problem:** Model staging fails
- **Solution:** Set `STAGE_WEIGHTS=0` to skip staging and use shared filesystem

### Debugging

To see detailed execution:
```bash
# Watch the output log in real-time
tail -f output.log

# Check for errors
tail -f error.log

# View hostfile to see allocated nodes
cat hostfile
```

---

## Advanced Usage

### Processing Large Batches

For 1000 files across 10 job submissions (2 nodes each):

```bash
# Job 1: files 0-1
qsub -v OFFSET=0 submit_oss120b_with_test.sh

# Job 2: files 2-3
qsub -v OFFSET=2 submit_oss120b_with_test.sh

# Job 3: files 4-5
qsub -v OFFSET=4 submit_oss120b_with_test.sh

# ... and so on
```

### Customizing Node Count

Edit line 8 in the script:
```bash
#PBS -l select=4  # Request 4 nodes instead of 2
```

### Modifying Walltime

Edit line 3 in the script:
```bash
#PBS -l walltime=02:00:00  # Request 2 hours instead of 1
```

---

## Files and Dependencies

### Main Scripts
- `submit_oss120b_with_test.sh` - This orchestration script
- `start_oss120b_with_test.sh` - Per-node execution script

### Utilities
- `../cptotmp.c` - MPI-based file copying utility for weight staging

### Dependencies
- `../examples/TOM.COLI/batch_1/` - Input files directory
- `/lus/flare/projects/datasets/model-weights/hub/models--openai--gpt-oss-120b` - Model weights

---

## Contributing

When modifying this script:
1. Test with a small job (2 nodes, few files) first
2. Verify all paths are correct
3. Check that error handling works as expected
4. Update this README if behavior changes
