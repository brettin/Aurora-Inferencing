#!/usr/bin/env python3
"""
Restart failed backends via SSH.

Usage: python3 restart_failed_backends.py <hosts_file> <backend_script> <log_base_dir>

Queries Traefik API for DOWN backends and restarts them.
"""

import sys
import os
import json
import subprocess
from urllib.request import urlopen, Request
from urllib.error import URLError

TRAEFIK_API_URL = "http://localhost:8080/api/http/services"


def get_down_backends():
    """Get list of DOWN backends from Traefik API."""
    try:
        req = Request(TRAEFIK_API_URL)
        with urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode())
        
        down = []
        for service in data:
            if "vllm-backends" in service.get("name", ""):
                server_status = service.get("serverStatus", {})
                for url, status in server_status.items():
                    if status != "UP":
                        # Parse URL: http://host:port -> (host, port)
                        # E.g., http://x4512c5s1b0n0.hsn.cm.aurora.alcf.anl.gov:8004
                        url_parts = url.replace("http://", "").split(":")
                        host = url_parts[0]
                        port = int(url_parts[1])
                        down.append((host, port, url))
        return down
    except (URLError, json.JSONDecodeError, KeyError) as e:
        print(f"Error querying Traefik API: {e}")
        return []


def restart_backend(host: str, port: int, log_dir: str):
    """Restart a single vLLM backend via SSH."""
    # Map port to backend number (8001->1, 8002->2, etc.)
    backend_num = port - 8000
    
    # GPU pairs for each backend
    gpu_pairs = {
        1: "0,1", 2: "2,3", 3: "4,5",
        4: "6,7", 5: "8,9", 6: "10,11"
    }
    vllm_ports = {
        1: "12340", 2: "12341", 3: "12342",
        4: "12343", 5: "12344", 6: "12345"
    }
    
    gpu_mask = gpu_pairs.get(backend_num, "0,1")
    vllm_port = vllm_ports.get(backend_num, "12340")
    
    # SSH command to restart the specific backend
    restart_cmd = f"""
source /tmp/vllm_env/bin/activate
export HF_HOME="/tmp"
export TMPDIR="/tmp"
export ZE_FLAT_DEVICE_HIERARCHY=FLAT
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export FI_MR_CACHE_MONITOR=userfaultfd
export TORCH_COMPILE_DISABLE=1
export OMP_NUM_THREADS=12
export TORCH_XPU_ALLOC_CONF=expandable_segments:True
export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
export no_proxy=localhost,127.0.0.1

pkill -f "vllm serve.*--port {port}" 2>/dev/null || true
sleep 2

ZE_AFFINITY_MASK="{gpu_mask}" VLLM_PORT="{vllm_port}" nohup vllm serve openai/gpt-oss-120b \\
    --tensor-parallel-size 2 \\
    --port {port} \\
    --disable-custom-all-reduce \\
    --enforce-eager \\
    --distributed-executor-backend mp \\
    --dtype bfloat16 \\
    --gpu-memory-utilization 0.90 \\
    > "{log_dir}/vllm_{backend_num}_restart.log" 2>&1 &

echo "Restarted backend {backend_num} on port {port}"
"""
    
    ssh_cmd = [
        "ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
        host, restart_cmd
    ]
    
    try:
        result = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=30)
        return result.returncode == 0
    except Exception as e:
        print(f"  Error restarting {host}:{port}: {e}")
        return False


def main():
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <hosts_file> <backend_script> <log_base_dir>")
        sys.exit(1)
    
    hosts_file = sys.argv[1]
    backend_script = sys.argv[2]
    log_base_dir = sys.argv[3]
    
    down_backends = get_down_backends()
    
    if not down_backends:
        print("All backends are healthy - no restarts needed.")
        sys.exit(0)
    
    print(f"Found {len(down_backends)} DOWN backend(s). Attempting restart...")
    
    restarted = 0
    for host, port, url in down_backends:
        print(f"  Restarting {host}:{port}...")
        host_log_dir = f"{log_base_dir}/{host}"
        
        if restart_backend(host, port, host_log_dir):
            restarted += 1
            print(f"    ✓ Restart initiated for {host}:{port}")
        else:
            print(f"    ✗ Failed to restart {host}:{port}")
    
    print(f"Restart attempts complete: {restarted}/{len(down_backends)}")
    
    if restarted > 0:
        print("Waiting 60s for restarted backends to become healthy...")
        import time
        time.sleep(60)


if __name__ == "__main__":
    main()
