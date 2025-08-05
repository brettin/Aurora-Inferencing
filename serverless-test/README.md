# Aurora Serverless Inference Test

This directory contains a serverless inference test system designed to run on the Aurora supercomputer at ALCF. The system demonstrates distributed inference using vLLM across multiple nodes with GPU tile mapping.

## System Architecture

The system implements a distributed inference pipeline where:
- Multiple compute nodes run in parallel
- Each node processes a subset of input prompts
- GPU tiles are mapped to MPI ranks for optimal resource utilization
- Results are written to individual output files per rank

## Call Stack Overview

```
submit.sh
├── gpu_tile_compact.sh
    └── simple_test.sh
        └── simple_test.py
```

### 1. submit.sh (Entry Point)
**Purpose**: PBS job submission script that orchestrates the distributed execution

**Key Components**:
- **PBS Configuration**: 
  - Wall time: 10 minutes
  - Account: `candle_aesp_CNDA`
  - Queue: `debug-scaling`
  - Nodes: 4 nodes with scatter placement
  - Filesystems: `flare:home`

- **MPI Configuration**:
  - Total processes: `NN * 12` (where NN = number of nodes)
  - Processes per node: 12
  - Uses `mpiexec` for distributed execution

**Execution Flow**:
```bash
mpiexec -np $NP -ppn $PPN ${SCRIPT_DIR}/gpu_tile_compact.sh ${SCRIPT_DIR}/simple_test.sh
```

### 2. gpu_tile_compact.sh (GPU Tile Mapper)
**Purpose**: Maps MPI ranks to GPU tiles in a compact, round-robin fashion

**Key Features**:
- **GPU Detection**: Uses `udevadm` to detect available Intel GPUs
- **Tile Mapping**: Maps each rank to a specific GPU tile (2 tiles per GPU)
- **Environment Setup**: 
  - Sets `ZE_ENABLE_PCI_ID_DEVICE_ORDER=1`
  - Configures `ZE_AFFINITY_MASK` for GPU tile binding
  - Unsets `EnableWalkerPartition`

**Mapping Algorithm**:
```
GPU ID = (Rank ID / num_tiles) % num_gpus
Tile ID = Rank ID % num_tiles
```

**Example Mapping** (3 GPUs, 2 tiles each, 7 ranks):
- Rank 0 → GPU 0, Tile 0
- Rank 1 → GPU 0, Tile 1  
- Rank 2 → GPU 1, Tile 0
- Rank 3 → GPU 1, Tile 1
- Rank 4 → GPU 2, Tile 0
- Rank 5 → GPU 2, Tile 1
- Rank 6 → GPU 0, Tile 0 (round-robin)

### 3. simple_test.sh (Environment Setup)
**Purpose**: Configures the execution environment and launches the Python inference script

**Environment Configuration**:
- **Proxy Settings**: Configures HTTP/HTTPS proxies for ALCF network
- **Module Management**:
  - Loads `frameworks` module
  - Activates conda environment: `/lus/flare/projects/candle_aesp_CNDA/brettin/conda_envs/vllm-20250520`
  - Manages oneAPI compiler modules for Aurora compatibility
- **Execution Context**: Logs hostname, rank, and GPU tile information

**Execution**:
```bash
python ${SCRIPT_DIR}/simple_test.py ${PMIX_RANK}.in ${PMIX_RANK}.out
```

### 4. simple_test.py (Inference Engine)
**Purpose**: Performs the actual inference using vLLM

**Key Components**:
- **Model**: Uses `facebook/opt-125m` (125M parameter model)
- **Device**: Configured for Intel XPU (GPU)
- **Sampling Parameters**:
  - Temperature: 0.8
  - Top-p: 0.95
- **I/O**: Reads prompts from rank-specific input files, writes results to rank-specific output files

**Processing Flow**:
1. Reads prompts from `{rank}.in` file
2. Initializes vLLM with OPT-125M model
3. Generates text for each prompt
4. Writes results to `{rank}.out` file

## Data Flow

### Input Files
- **Format**: Text files named `{rank}.in` (e.g., `0.in`, `1.in`, etc.)
- **Content**: One prompt per line
- **Example**:
  ```
  The most important invention of the 21st century is
  When humans first make contact with aliens, the conversation begins with
  To solve climate change, the world must
  The secret to a long and fulfilling life is
  ```

### Output Files
- **Format**: Text files named `{rank}.out` (e.g., `0.out`, `1.out`, etc.)
- **Content**: Generated text for each input prompt
- **Format**: `Prompt: {prompt}, Generated text: {generated_text}`

## Execution Example

For a 4-node job with 12 processes per node:

1. **Job Submission**:
   ```bash
   qsub submit.sh
   ```

2. **Execution Flow**:
   - 48 total processes (4 nodes × 12 processes)
   - Each process gets mapped to a GPU tile
   - Each process reads from `{rank}.in` and writes to `{rank}.out`
   - All processes run in parallel

3. **Output**:
   - 48 output files (`0.out` through `47.out`)
   - Each containing generated text for the corresponding input prompts

## Key Features

### Scalability
- **Horizontal Scaling**: Add more nodes to process more data
- **GPU Utilization**: Efficient mapping of ranks to GPU tiles
- **Parallel Processing**: All ranks process data simultaneously

### Resource Management
- **GPU Tile Mapping**: Compact, round-robin allocation
- **Memory Efficiency**: Uses small model (125M parameters)
- **Network Optimization**: Proxy configuration for ALCF environment

### Fault Tolerance
- **Independent Processing**: Each rank operates independently
- **File-based I/O**: Simple, reliable input/output mechanism
- **Error Isolation**: Failures in one rank don't affect others

## Dependencies

- **vLLM**: For efficient inference
- **Intel oneAPI**: For Aurora compatibility
- **MPI**: For distributed execution
- **Conda Environment**: `vllm-20250520` with required packages

## Notes

- This system is designed for Aurora's Intel GPU architecture
- The small model size (125M parameters) allows for efficient multi-node scaling
- The file-based I/O approach simplifies the architecture but may not be optimal for very large datasets
- Consider using Copper (ALCF's cooperative caching layer) for improved I/O performance at scale 