# GPT-OSS-120B vLLM Multi-Node Deployment

Deploy and run GPT-OSS-120B model using vLLM across multiple Aurora compute nodes.

## Quick Start

### Submit a Job

```bash
# Basic submission (processes files starting from index 0)
qsub submit_oss120b_with_test.sh

# Resume from a specific file (e.g., start at file 10)
qsub -v OFFSET=10 submit_oss120b_with_test.sh

# Skip model weight staging (faster startup, slower inference)
qsub -v STAGE_WEIGHTS=0 submit_oss120b_with_test.sh

# Monitor progress
tail -f output.log
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OFFSET` | 0 | Starting file index (for resuming) |
| `STAGE_WEIGHTS` | 1 | Copy model to /tmp (1=yes, 0=no) |
| `STAGE_CONDA` | 1 | Copy conda environment to /tmp (1=yes, 0=no) |
| `USE_FRAMEWORKS` | unset | Use frameworks module instead of staged conda env |

## How It Works

1. **Job starts** → Reads allocated nodes from PBS
2. **Stage weights** (optional) → Copies model to /tmp on each node for faster I/O
3. **Distribute files** → Assigns one input file per node from `../examples/TOM.COLI/batch_1/`
4. **Launch in parallel** → SSH to each node and run `start_oss120b_with_test.sh`
5. **Wait & collect** → Monitors completion and reports success/failure

### File Assignment

With 100 files and 2 nodes, `OFFSET=0`:
- Node 1 gets file[0], Node 2 gets file[1]

To process remaining files:
```bash
qsub -v OFFSET=2 submit_oss120b_with_test.sh  # Processes files 2-3
qsub -v OFFSET=4 submit_oss120b_with_test.sh  # Processes files 4-5
```

## Configuration

Edit these at the top of `submit_oss120b_with_test.sh`:

```bash
SCRIPT_DIR="/path/to/script"           # This script's location
INPUT_DIR="${SCRIPT_DIR}/../examples/TOM.COLI/batch_1"  # Input files
MODEL_PATH="/path/to/model"            # Model weights location
OFFSET=0                               # Starting file index
STAGE_WEIGHTS=1                        # Stage to /tmp?
SSH_TIMEOUT=10                         # SSH timeout (seconds)
LAUNCH_DELAY=2                         # Delay between launches (seconds)
```

## Input Data

The `batch_1` directory contains input files:
- Repository includes 5 example files (chunk_0000.txt through chunk_0004.txt) for testing
- Populate with your full dataset for production runs
- Files should be named `chunk_NNNN.txt`

## Output

- **Logs:** `output.log`, `error.log`
- **Results:** `<hostname>_results_<timestamp>.tar.gz` (one per node)
- **Hostfile:** List of allocated nodes

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Input directory not found" | Check INPUT_DIR path exists |
| "No files to process" | Verify OFFSET < total files |
| SSH failures | Verify SCRIPT_DIR is accessible on compute nodes |
| Model staging fails | Use `STAGE_WEIGHTS=0` to skip |

## Customization

**Change node count:** Edit `#PBS -l select=2` in the script

**Change walltime:** Edit `#PBS -l walltime=01:00:00` in the script
