import os
import sys
import ray
from ray import serve
import logging
import traceback
import socket
import time
import resource
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

# --- IMPORTS & MONKEY PATCHES ---
import vllm.utils
import vllm.utils.network_utils

# 1. Enforce High limits for Ray/vLLM threads (Global Scope - Driver)
try:
    soft, hard = resource.getrlimit(resource.RLIMIT_NPROC)
    # Ensure we don't try to exceed hard limit if it's lower than 65536
    target_limit = min(65536, hard)
    resource.setrlimit(resource.RLIMIT_NPROC, (target_limit, hard))
    print(f"[SYSTEM] Driver Initial Limits - NPROC: Soft={soft}, Hard={hard}")
    print(f"[SYSTEM] Set RLIMIT_NPROC to {target_limit} (Global)")
except Exception as e:
    print(f"[SYSTEM] Warning: Could not set RLIMIT_NPROC: {e}")

# 2. Monkey-patch to fix MASTER_PORT collisions on multi-gpu nodes
def deterministic_get_open_port():
    if "MASTER_PORT" in os.environ:
        return int(os.environ["MASTER_PORT"])
    return vllm.utils.network_utils.get_open_port()

vllm.utils.get_open_port = deterministic_get_open_port
vllm.utils.network_utils.get_open_port = deterministic_get_open_port
print(f"[VLLM] Monkey-patched get_open_port for MASTER_PORT enforcement")

# --- VLLM IMPORTS ---
from vllm.engine.arg_utils import AsyncEngineArgs
from vllm.engine.async_llm_engine import AsyncLLMEngine
from vllm.entrypoints.openai.protocol import ChatCompletionRequest, CompletionRequest, ErrorResponse
from vllm.entrypoints.openai.serving_chat import OpenAIServingChat
from vllm.entrypoints.openai.serving_completion import OpenAIServingCompletion
from vllm.entrypoints.openai.serving_models import OpenAIServingModels, BaseModelPath

# --- CONFIG ---
REPO_ID = "openai/gpt-oss-120b"
TP_SIZE = 2
GPUS_PER_REPLICA = 2
REPLICAS_PER_NODE = 6 # 12 GPUs / 2 = 6 replicas

logger = logging.getLogger("ray.serve")
app_vllm = FastAPI()

@serve.deployment(
    autoscaling_config=None,
    max_ongoing_requests=200, 
    graceful_shutdown_timeout_s=30,
    health_check_period_s=10,
    health_check_timeout_s=30,
)
@serve.ingress(app_vllm)
class VLLMService:
    def __init__(self):
        # CRITICAL: Enforce resource limits INSIDE the worker process upon initialization
        # This guards against cases where Ray doesn't inherit limits from the driver or shell
        try:
            soft, hard = resource.getrlimit(resource.RLIMIT_NPROC)
            logger.info(f"Replica Startup Limits - NPROC: Soft={soft}, Hard={hard}")
            
            target = min(65536, hard)
            if soft < target:
                resource.setrlimit(resource.RLIMIT_NPROC, (target, hard))
                logger.info(f"Replica Raised NPROC to {target}")
            
            # Also boost file descriptors just in case
            soft_f, hard_f = resource.getrlimit(resource.RLIMIT_NOFILE)
            target_f = min(65536, hard_f)
            if soft_f < target_f:
                resource.setrlimit(resource.RLIMIT_NOFILE, (target_f, hard_f))
                logger.info(f"Replica Raised NOFILE to {target_f}")
                
        except Exception as e:
            logger.warning(f"Failed to enforce limits in __init__: {e}")

        self.engine_ready = False
        try:
            self._initialize_service()
            self.engine_ready = True
        except Exception:
            logger.error(f"Init Failed: {traceback.format_exc()}")
            raise

    def _initialize_service(self):
        ctx = ray.get_runtime_context()
        
        # 1. Device & Port setup
        gpu_ids = []
        try:
            res = ctx.get_resource_ids()
            gpu_ids = [str(int(g[0])) for g in res.get("GPU", [])]
        except:
            pass

        if gpu_ids:
            # Sort IDs to ensure consistent pinning
            gpu_ids = sorted(gpu_ids, key=lambda x: int(x))
            affinity = ",".join(gpu_ids)
            os.environ["ZE_AFFINITY_MASK"] = affinity
            # Calculate a unique port based on the *first* GPU ID
            os.environ["MASTER_PORT"] = str(29600 + int(gpu_ids[0]))
            print(f"[VLLM] Node: {socket.gethostname()} | GPUs: {affinity} | Port: {os.environ['MASTER_PORT']}")
        else:
            print("[VLLM] WARNING: No GPU IDs found in context.")

        # 2. Model Path
        model_path = REPO_ID
        # Priority: Local /tmp -> Local /tmp/hub -> Shared FS
        for p in ["/tmp", "/tmp/hub", "/flare/AuroraGPT/model-weights/optimized_model/hub"]:
            if os.path.exists(os.path.join(p, "config.json")):
                model_path = p
                break
        
        print(f"[VLLM] Loading model from: {model_path}")

        # 3. Engine Args
        engine_args = AsyncEngineArgs(
            model=model_path,
            tensor_parallel_size=TP_SIZE,
            dtype="bfloat16",
            disable_custom_all_reduce=True,
            enforce_eager=True,
            distributed_executor_backend="mp", 
            trust_remote_code=True,
            gpu_memory_utilization=0.90,
            max_model_len=4096,
        )
        
        self.engine = AsyncLLMEngine.from_engine_args(engine_args)
        
        # 4. Serving Objects
        base_model_paths = [BaseModelPath(name=REPO_ID, model_path=model_path)]
        self.openai_serving_models = OpenAIServingModels(self.engine, base_model_paths)
        self.openai_serving_chat = OpenAIServingChat(self.engine, self.openai_serving_models, "assistant")
        self.openai_serving_completion = OpenAIServingCompletion(self.engine, self.openai_serving_models)

    @app_vllm.get("/health")
    def health(self):
        return {"status": "ok"} if self.engine_ready else JSONResponse(status_code=503, content={"status": "initializing"})

    @app_vllm.post("/chat/completions")
    async def chat(self, request: Request):
        req = ChatCompletionRequest(**await request.json())
        gen = await self.openai_serving_chat.create_chat_completion(req)
        if isinstance(gen, ErrorResponse): return JSONResponse(gen.model_dump(), status_code=gen.code)
        return StreamingResponse(gen, media_type="text/event-stream") if req.stream else JSONResponse(gen.model_dump())

if __name__ == "__main__":
    # Use the existing cluster
    ray.init(address="auto", ignore_reinit_error=True)

    # Clean previous deployments
    try:
        serve.shutdown()
        time.sleep(5)
    except: pass

    # --- HEADLESS CONFIGURATION ---
    print("Starting Serve with location='EveryNode'...")
    serve.start(http_options={
        "host": "0.0.0.0", 
        "port": 8000, 
        "location": "EveryNode",
        "keep_alive_timeout_s": 600
    })

    # --- FIX: ROBUST NODE LISTING ---
    from ray.util.state import list_nodes
    
    all_nodes = list_nodes()
    head_ip = ray.util.get_node_ip_address()
    
    worker_nodes = []
    for node in all_nodes:
        # Ray 2.x NodeState object: use getattr to safely access attributes
        # state is "ALIVE" or "DEAD"
        state = getattr(node, "state", "DEAD")
        node_ip = getattr(node, "node_ip", "")
        
        # Filter: Must be ALIVE and NOT the Head Node IP
        if state == "ALIVE" and node_ip != head_ip:
            worker_nodes.append(node)
            
    num_workers = len(worker_nodes)
    if num_workers == 0:
        print("CRITICAL: No worker nodes detected! Check Ray cluster status.")
        # Fallback to list all alive nodes if filtering was too aggressive
        worker_nodes = [n for n in all_nodes if getattr(n, "state", "") == "ALIVE"]
        num_workers = len(worker_nodes)

    total_replicas = num_workers * REPLICAS_PER_NODE
    
    print(f"Deploying {total_replicas} replicas across {num_workers} nodes (Head IP: {head_ip})...")
    print(f"Target Nodes: {[getattr(n, 'node_name', 'unknown') for n in worker_nodes]}")

    # Deploy as a SINGLE application
    app = VLLMService.options(
        num_replicas=total_replicas,
        ray_actor_options={
            "num_gpus": GPUS_PER_REPLICA,
            "num_cpus": 12,
            "runtime_env": {
                "env_vars": {
                    "OMP_NUM_THREADS": "2",     # Reduced from 4 to safe levels
                    "MKL_NUM_THREADS": "2",     
                    "RAYON_NUM_THREADS": "2",
                    "VLLM_WORKER_MULTIPROC_METHOD": "spawn",
                    "TORCH_COMPILE_DISABLE": "1",
                    "TORCH_XPU_ALLOC_CONF": "expandable_segments:True"
                }
            }
        }
    ).bind()
    
    # CRITICAL FIX: Set blocking=False to prevent the Driver script from crashing 
    # due to 'Resource temporarily unavailable' (thread exhaustion) while waiting 
    # for long-running model initialization across many nodes.
    print("Submitting deployment (non-blocking)...")
    serve.run(app, name="vllm_service", route_prefix="/v1", blocking=False)
    
    print("Deployment submitted successfully. Entering keep-alive loop.")
    while True:
        time.sleep(10)