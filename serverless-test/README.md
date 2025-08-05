# Aurora Serverless Inference Test

This directory contains a serverless inference test system designed to run on the Aurora supercomputer at ALCF. The system demonstrates running one model per tile, on 12 tiles per node, using 4 nodes, for a total of 48 model instances. 

## System Architecture

The system implements a distributed inference pipeline where:
- A model is instantiated, one per tile, on each compute node.
- GPU tiles are mapped to MPI ranks.
- Each model processes a different set of input prompts.
- Input prompts are in files that are named numerically so they can map to a rank.
- Results are written to individual output files per rank

## Call Stack Overview

```
submit.sh
├── gpu_tile_compact.sh
    └── simple_test.sh
        └── simple_test.py
```

**submit.sh (Entry Point)**
PBS job submission script that orchestrates the distributed execution.


**gpu_tile_compact.sh (GPU Tile Mapper)**
Maps MPI ranks to GPU tiles in a compact, round-robin fashion.


**simple_test.sh (Environment Setup)**
Configures the execution environment and launches the Python inference script.


**simple_test.py (Inference Engine)**
Performs the actual inference using vLLM. Processing Flow:
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
   - Each process loads model weights. The model must be small enough to fit on one tile.
   - Each process reads from `{rank}.in` and writes to `{rank}.out`
   - All processes run in parallel

3. **Output**:
   - 48 output files (`0.out` through `47.out`)
   - Each contains generated text for the corresponding input prompts
