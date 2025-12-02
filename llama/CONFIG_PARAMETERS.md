# Llama Server Configuration Parameters

This document describes all configurable parameters in `start_llama_with_test.sh`.

All parameters can be overridden by setting environment variables before running the script.

## Command-Line Arguments

The script accepts the following positional arguments:

| Position | Variable | Default | Description |
|----------|----------|---------|-------------|
| 1 | `DEVICE` | `0` | GPU device ID (determines port as BASE_PORT + DEVICE) |
| 2 | `BATCH_SIZE` | `32` | Batch size for inference test |
| 3 | `REDIS_HOST` | `localhost` | Redis service registry hostname |
| 4 | `REDIS_PORT` | `6379` | Redis service registry port |
| 5 | `INFILE` | `${SCRIPT_DIR}/../examples/TOM.COLI/1.txt` | Test input file path |

**Usage:**
```bash
./start_llama_with_test.sh [DEVICE] [BATCH_SIZE] [REDIS_HOST] [REDIS_PORT] [INFILE]

# Examples:
./start_llama_with_test.sh 0 32 localhost 6379
./start_llama_with_test.sh 2 64 redis-host 6379 /path/to/input.txt
```

## Port Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `LLAMA_BASE_PORT` | `8888` | Base port number. Actual port = BASE_PORT + DEVICE |

## Performance & Threading

| Variable | Default | Description |
|----------|---------|-------------|
| `LLAMA_OMP_THREADS` | `64` | OpenMP thread count |
| `LLAMA_CONTEXT_SIZE` | `131072` | Model context window size (tokens) |
| `LLAMA_PARALLEL_SLOTS` | `32` | Number of parallel request slots |
| `LLAMA_THREADS` | `32` | Number of inference threads |
| `LLAMA_GPU_LAYERS` | `80` | Number of model layers to offload to GPU |

## Timeout Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `WALLTIME_SECONDS` | `3600` | Total walltime for script execution (seconds, 60 minutes) |
| `LLAMA_CLEANUP_MARGIN` | `300` | Time reserved for cleanup (seconds) |
| `LLAMA_STARTUP_TIMEOUT` | `600` | Max time to wait for server startup (seconds) |
| `LLAMA_HEALTH_INTERVAL` | `2` | Health check interval (seconds) |
| `LLAMA_HEARTBEAT_INTERVAL` | `10` | Redis heartbeat interval (seconds) |
| `LLAMA_MAX_FAILURES` | `3` | Max health check failures before marking unhealthy |
| `LLAMA_MIN_TIMEOUT` | `60` | Minimum timeout for test execution (seconds) |
| `LLAMA_FLUSH_DELAY` | `2` | Time to wait for filesystem flush (seconds) |

## Path Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `ONEAPI_SETVARS` | `/opt/intel/oneapi/setvars.sh` | Intel oneAPI environment script |
| `LLAMA_OUTPUT_DIR` | `/dev/shm` | Base directory for output files |
| `REDIS_ENV_DIR` | `/tmp/redis_env` | Redis Python environment directory |
| `LLAMA_BUILD_DIR` | `gpt-oss-120b-intel-max-gpu` | Directory containing llama.cpp build |
| `LLAMA_MODEL_FILE` | `/tmp/hf_home/hub/models/gpt-oss-120b-Q4_K_M-00001-of-00002.gguf` | Full path to model file |
| `LLAMA_MODEL_ALIAS` | `gpt-oss-120b` | Model alias for API calls |

## Proxy Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `HTTP_PROXY_URL` | `http://proxy.alcf.anl.gov:3128` | HTTP proxy URL |
| `HTTPS_PROXY_URL` | `http://proxy.alcf.anl.gov:3128` | HTTPS proxy URL |

## Usage Examples

### Use larger context window
```bash
export LLAMA_CONTEXT_SIZE=262144
./start_llama_with_test.sh 0 32 localhost 6379
```

### Increase parallel slots for higher throughput
```bash
export LLAMA_PARALLEL_SLOTS=64
export LLAMA_THREADS=64
./start_llama_with_test.sh 0 32 localhost 6379
```

### Use different model
```bash
export LLAMA_MODEL_FILE="/custom/path/my-model.gguf"
export LLAMA_MODEL_ALIAS="my-model"
./start_llama_with_test.sh 0 32 localhost 6379
```

### Use different llama.cpp build
```bash
export LLAMA_BUILD_DIR="my-custom-llama-build"
./start_llama_with_test.sh 0 32 localhost 6379
```

### Adjust GPU layer offloading
```bash
export LLAMA_GPU_LAYERS=40  # Reduce GPU usage
./start_llama_with_test.sh 0 32 localhost 6379
```

### Faster health checks
```bash
export LLAMA_HEALTH_INTERVAL=1
export LLAMA_HEARTBEAT_INTERVAL=5
./start_llama_with_test.sh 0 32 localhost 6379
```

### Use different output directory
```bash
export LLAMA_OUTPUT_DIR="/tmp"
./start_llama_with_test.sh 0 32 localhost 6379
```

### Extend total walltime
```bash
export WALLTIME_SECONDS=7200  # 2 hours
./start_llama_with_test.sh 0 32 localhost 6379
```

## Multi-Environment Setup

You can create environment-specific configuration files:

**production.env:**
```bash
export LLAMA_CONTEXT_SIZE=131072
export LLAMA_PARALLEL_SLOTS=64
export LLAMA_THREADS=64
export LLAMA_GPU_LAYERS=80
export LLAMA_HEARTBEAT_INTERVAL=10
```

**testing.env:**
```bash
export LLAMA_CONTEXT_SIZE=4096
export LLAMA_PARALLEL_SLOTS=8
export LLAMA_THREADS=16
export LLAMA_GPU_LAYERS=40
export LLAMA_HEARTBEAT_INTERVAL=5
```

Then use:
```bash
source production.env
./start_llama_with_test.sh 0 32 localhost 6379
```

## Performance Tuning Guide

### High Throughput Configuration
- Increase `LLAMA_PARALLEL_SLOTS` (32 → 64+)
- Increase `LLAMA_THREADS` to match
- May need to reduce `LLAMA_CONTEXT_SIZE` if memory constrained

### Low Latency Configuration
- Reduce `LLAMA_PARALLEL_SLOTS` (32 → 8-16)
- Increase `LLAMA_GPU_LAYERS` for maximum GPU usage
- Keep `LLAMA_CONTEXT_SIZE` moderate

### Memory-Constrained Configuration
- Reduce `LLAMA_CONTEXT_SIZE`
- Reduce `LLAMA_GPU_LAYERS` (offload fewer layers)
- Reduce `LLAMA_PARALLEL_SLOTS`

### Large Context Configuration
- Increase `LLAMA_CONTEXT_SIZE` (131072 → 262144+)
- May need to reduce `LLAMA_PARALLEL_SLOTS`
- Ensure sufficient GPU memory

