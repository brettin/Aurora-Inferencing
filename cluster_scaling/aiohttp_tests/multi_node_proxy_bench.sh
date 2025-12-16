#!/bin/bash
#PBS -N vllm_proxy_bench_multi
#PBS -l walltime=00:20:00
#PBS -A candle_aesp_CNDA
#PBS -q prod
#PBS -o /home/ngetty/proj/vllm_gpt-oss/Aurora-Inferencing/cluster_scaling/aiohttp_tests/output_multi.log
#PBS -e /home/ngetty/proj/vllm_gpt-oss/Aurora-Inferencing/cluster_scaling/aiohttp_tests/error_multi.log
#PBS -l select=16
#PBS -l filesystems=flare:home
#PBS -l place=scatter

# --- CONFIGURATION ---
# --- CONFIGURATION ---
if [ -n "$PBS_O_WORKDIR" ]; then
    cd "$PBS_O_WORKDIR" || exit 1
fi
SCRIPT_DIR=$(pwd)
ROOT_DIR=$(dirname "$(dirname "$SCRIPT_DIR")") # Aurora-Inferencing
CPTOTMP_SRC="$ROOT_DIR/cluster_scaling/cptotmp.c"
CPTOTMP_BIN="$ROOT_DIR/cluster_scaling/cptotmp_bin"

# Model and Env Paths (Matches proxy_bench_tp2.sh)
MODEL_SOURCE="/flare/AuroraGPT/model-weights/optimized_model/hub" 
MODEL_DEST="/tmp"
ENV_TAR="/flare/AuroraGPT/ngetty/envs/packed_envs/vllm_env.tar.gz"
ENV_STAGE_DIR="/tmp"
LOCAL_ENV="/tmp/vllm_env"

# Proxy Settings
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export http_proxy=http://proxy.alcf.anl.gov:3128
export https_proxy=http://proxy.alcf.anl.gov:3128
export no_proxy=localhost,127.0.0.1

echo "---------------------------------------------------"
echo "Job ID: $PBS_JOBID"
echo "Nodes: $(cat $PBS_NODEFILE | wc -l)"
echo "Head Node: $(hostname)"
LOG_DIR="${SCRIPT_DIR}/logs/${PBS_JOBID%.*}"
mkdir -p "$LOG_DIR"
echo "Logs Directory: $LOG_DIR"
echo "---------------------------------------------------"

# --- 0. PREPARE HOSTS & NO_PROXY ---
# Get unique hosts
sort -u "$PBS_NODEFILE" > hosts.txt
mapfile -t HOSTS < hosts.txt

# Update no_proxy with all hostnames to bypass proxy for internal comms
HOST_LIST=$(paste -sd, hosts.txt)
export no_proxy="$no_proxy,$HOST_LIST"
echo "Updated no_proxy: $no_proxy"

# --- 1. COMPILE COPY TOOL ---
# We compile on head node, then use it. Requires MPI.
if ! command -v mpicc &> /dev/null; then
    module load frameworks
fi

if [ ! -f "$CPTOTMP_BIN" ]; then
    echo "Compiling cptotmp..."
    mpicc -o "$CPTOTMP_BIN" "$CPTOTMP_SRC"
fi

# --- 2. STAGE FILES (WEIGHTS & ENV) ON ALL NODES ---
echo "Staging Model Weights to $MODEL_DEST on all nodes..."
# Note: Using mpiexec to run cptotmp on all nodes. 
# cptotmp takes src dest. 
# We disable multi-nic striping as per other scripts? 
export MPIR_CVAR_CH4_OFI_ENABLE_MULTI_NIC_STRIPING=1
export MPIR_CVAR_CH4_OFI_MAX_NICS=4

mpiexec -ppn 1 --cpu-bind numa "$CPTOTMP_BIN" "$MODEL_SOURCE" "$MODEL_DEST"

echo "Staging Environment to $ENV_STAGE_DIR on all nodes..."
mpiexec -ppn 1 --cpu-bind numa "$CPTOTMP_BIN" "$ENV_TAR" "$ENV_STAGE_DIR"

# --- 3. UNPACK ENV ON ALL NODES ---
echo "Unpacking Environment on all nodes..."
TAR_NAME=$(basename "$ENV_TAR")

# We execute a bash snippet on all nodes via mpiexec
mpiexec -ppn 1 bash -c "
    if [ ! -f '$LOCAL_ENV/bin/activate' ]; then
        echo \"Unpacking on \$(hostname)...\"
        mkdir -p '$LOCAL_ENV'
        tar -xf '$ENV_STAGE_DIR/$TAR_NAME' -C '$LOCAL_ENV' && \
        source '$LOCAL_ENV/bin/activate' && \
        conda-unpack
    else
        echo \"Environment already ready on \$(hostname).\"
    fi
"

# --- 4. START VLLM ON ALL NODES ---
echo "Launching vLLM Backends..."
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
NODE_SCRIPT="$SCRIPT_DIR/start_vllm_backends.sh"

for host in "${HOSTS[@]}"; do
    echo "Starting backends on $host..."
    # We run the script in background via ssh
    # We redirect output to a log file on the compute node (via the script)
    # But we want to ensure the SSH returns.
    # Pass LOG_DIR to the script. Since LOG_DIR is on shared FS, all nodes can write to it.
    # We use a subdir for each host to avoid name collisions if filenames were same (they are vllm_1..6)
    # Actually vllm_1..6 are unique per node, but if we write to same dir distinct by host is needed.
    HOST_LOG_DIR="${LOG_DIR}/${host}"
    mkdir -p "$HOST_LOG_DIR"
    ssh $SSH_OPTS "$host" "bash -l '$NODE_SCRIPT' '$HOST_LOG_DIR'" > "${HOST_LOG_DIR}/launch.log" 2>&1 &
done

# Wait a bit for launches to initialize
echo "Waiting 60s for backends to initialize..."
sleep 60

# --- 5. GENERATE PROXY.PY WITH DYNAMIC BACKENDS ---
echo "Generating proxy.py..."

# Create the python list of backends
# [ "http://host1:8001", "http://host1:8002", ... "http://host2:8001" ... ]
BACKEND_LIST_STR="["
for host in "${HOSTS[@]}"; do
    for port in {8001..8006}; do
        BACKEND_LIST_STR+="\"http://${host}:${port}\", "
    done
done
BACKEND_LIST_STR="${BACKEND_LIST_STR%, }]" # Remove trailing comma

# Write the python script
cat <<EOF > /tmp/proxy.py
import aiohttp
from aiohttp import web
import asyncio
import sys

# Dynamically generated backends
BACKENDS = $BACKEND_LIST_STR
idx = 0
client_session = None

async def on_startup(app):
    global client_session
    connector = aiohttp.TCPConnector(limit=0, ttl_dns_cache=300)
    timeout = aiohttp.ClientTimeout(total=None, connect=5, sock_connect=5)
    client_session = aiohttp.ClientSession(connector=connector, timeout=timeout)
    print(f"Proxy: Robust ClientSession started ({len(BACKENDS)} Backends).")

async def on_cleanup(app):
    global client_session
    if client_session:
        await client_session.close()

async def handler(request):
    global idx
    try:
        body = await request.read()
    except Exception as e:
        return web.Response(status=500, text=f"Proxy Read Error: {e}")

    max_retries = len(BACKENDS)
    last_error = None
    
    for attempt in range(max_retries):
        target_base = BACKENDS[idx]
        idx = (idx + 1) % len(BACKENDS)
        target_url = f"{target_base}{request.path_qs}"
        
        try:
            async with client_session.request(
                request.method,
                target_url,
                headers=request.headers,
                data=body,
                allow_redirects=False
            ) as resp:
                response = web.StreamResponse(status=resp.status, reason=resp.reason)
                for h, v in resp.headers.items():
                    if h.lower() not in ('content-length', 'content-encoding', 'transfer-encoding', 'connection'):
                        response.headers[h] = v
                await response.prepare(request)
                async for chunk in resp.content.iter_chunked(65536):
                    await response.write(chunk)
                return response
        except (aiohttp.ClientConnectorError, asyncio.TimeoutError, aiohttp.ClientError) as e:
            # print(f"WARNING: Backend {target_base} failed (Attempt {attempt+1}): {e}")
            last_error = e
            continue
        except Exception as e:
            return web.Response(text=f"Proxy Error: {str(e)}", status=500)
    
    return web.Response(text=f"All backends failed. Last error: {last_error}", status=502)

app = web.Application()
app.on_startup.append(on_startup)
app.on_cleanup.append(on_cleanup)
app.router.add_route('*', '/{path_info:.*}', handler)

if __name__ == '__main__':
    web.run_app(app, port=8000, access_log=None)
EOF

# Activate environment on head node for Python availability
source $LOCAL_ENV/bin/activate

# --- 6. HEALTH CHECK ---
echo "Checking Backend Health..."
# We use a simple python snippet to check all backends in parallel/sequence
cat <<EOF > /tmp/health_check.py
import requests
import sys
import time

backends = $BACKEND_LIST_STR

def check_backend(url):
    try:
        r = requests.get(f"{url}/health", timeout=2)
        return r.status_code == 200
    except:
        return False

print(f"Checking {len(backends)} backends...")
start = time.time()
while time.time() - start < 1200: # 20 min timeout
    all_ready = True
    for b in backends:
        if not check_backend(b):
            all_ready = False
            # print(f"waiting for {b}")
            break
    if all_ready:
        print("All backends READY.")
        sys.exit(0)
    time.sleep(5)

print("Timeout waiting for backends.")
sys.exit(1)
EOF

python /tmp/health_check.py
if [ $? -ne 0 ]; then
    echo "Health check failed."
    # Cleanup?
    # exit 1
fi

# --- 7. START PROXY ---
echo "Starting Proxy..."
nohup python /tmp/proxy.py > /tmp/proxy.log 2>&1 &
PROXY_PID=$!

sleep 5

# --- 8. RUN BENCHMARK ---
echo "Running Benchmark..."
PROXY_URL="http://localhost:8000"
PROMPTS_PER_CLIENT=800
INPUT_LEN=3024
OUTPUT_LEN=1024
MODEL="openai/gpt-oss-120b"
# We need to make sure vLLM modules are loaded to run 'vllm bench'
# Environment already activated above


# Launch 6 clients (or more?)
# Since we are scaling capacity, we might want to scale load.
# But let's stick to 6 clients for now.
for i in {1..12}; do
    vllm bench serve --model "$MODEL" --backend openai --base-url "$PROXY_URL" \
        --dataset-name random --seed 12345 --num-prompts $PROMPTS_PER_CLIENT \
        --random-input-len $INPUT_LEN --random-output-len $OUTPUT_LEN > "$LOG_DIR/bench_proxy_${i}.log" 2>&1 &
    PIDS[${i}]=$!
done

wait ${PIDS[@]}

echo "=========================================="
echo "PROXY BENCHMARK RESULTS (Multi-Node)"
echo "=========================================="
for i in {1..12}; do
    echo "--- Client $i ---"
    grep "Output token throughput" "$LOG_DIR/bench_proxy_${i}.log"
    grep "Total Token throughput" "$LOG_DIR/bench_proxy_${i}.log"
done
echo "------------------------------------------"

# Calculate Aggregated Totals
awk '
    /Output token throughput/ { output_sum += $5 }
    /Total Token throughput/ { total_sum += $5 }
    END {
        printf "==========================================\n"
        printf "AGGREGATED METRICS:\n"
        printf "Total Output Token Throughput: %.2f tok/s\n", output_sum
        printf "Total Total Token Throughput:  %.2f tok/s\n", total_sum
        printf "==========================================\n"
    }
' "$LOG_DIR"/bench_proxy_*.log


# --- 9. CLEANUP ---
kill $PROXY_PID
# Kill remote vLLMs
echo "Cleaning up remote vLLMs..."
for host in "${HOSTS[@]}"; do
    ssh $SSH_OPTS "$host" "pkill -f 'vllm serve'"
done

echo "Done."
