import os
import sys

# --- ENVIRONMENT CONFIGURATION ---
os.environ["HTTP_PROXY"] = "http://proxy.alcf.anl.gov:3128"
os.environ["HTTPS_PROXY"] = "http://proxy.alcf.anl.gov:3128"
os.environ["http_proxy"] = "http://proxy.alcf.anl.gov:3128"
os.environ["https_proxy"] = "http://proxy.alcf.anl.gov:3128"
os.environ["HF_HOME"] = "/tmp" 

if "no_proxy" not in os.environ:
    os.environ["no_proxy"] = "localhost,127.0.0.1"

import ray
from ray import serve
import logging
import traceback
import socket
from fastapi import FastAPI, Request

# Set tiktoken cache to /tmp to avoid permission/missing file issues
os.environ["TIKTOKEN_CACHE_DIR"] = "/tmp"

def get_open_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("", 0))
        return s.getsockname()[1]
from fastapi.responses import JSONResponse, StreamingResponse
from vllm.engine.arg_utils import AsyncEngineArgs
from vllm.engine.async_llm_engine import AsyncLLMEngine
from vllm.entrypoints.openai.protocol import ChatCompletionRequest, CompletionRequest, ErrorResponse
from vllm.entrypoints.openai.serving_chat import OpenAIServingChat
from vllm.entrypoints.openai.serving_completion import OpenAIServingCompletion
# FIX: Import serving models classes required for recent vLLM versions
from vllm.entrypoints.openai.serving_models import OpenAIServingModels, BaseModelPath


# CRITICAL FIX: Monkey-patch vllm.utils.get_open_port to return our deterministic MASTER_PORT
# VLLM V1 multiproc_executor ignores MASTER_PORT env var and calls get_open_port(), causing races.
import vllm.utils
original_get_open_port = vllm.utils.get_open_port
def deterministic_get_open_port():
    if "MASTER_PORT" in os.environ:
        return int(os.environ["MASTER_PORT"])
    return original_get_open_port()
vllm.utils.get_open_port = deterministic_get_open_port
print(f"[VLLM] Monkey-patched vllm.utils.get_open_port to enforce MASTER_PORT")

# --- CONFIGURATION ---
REPO_ID = "openai/gpt-oss-120b" # Name exposed to API clients
TP_SIZE = 2
GPUS_PER_REPLICA = 2 

logger = logging.getLogger("ray.serve")
app_vllm = FastAPI()

@serve.deployment(
    ray_actor_options={"num_gpus": GPUS_PER_REPLICA, "num_cpus": 8}
)
@serve.ingress(app_vllm)
class VLLMService:
    def __init__(self, target_replicas: int = 12):
        self.target_replicas = target_replicas
        # Wrap init in try/except to catch the REAL error masked by the shutdown error
        try:
            self._initialize_service()
        except Exception:
            # Log the full traceback so we can see why init failed
            print("CRITICAL ERROR IN VLLM SERVICE INIT:")
            traceback.print_exc()
            raise

    def _initialize_service(self):
        # 1. Device Setup
        
        # Handle Ray deprecation of get_resource_ids()
        ctx = ray.get_runtime_context()
        if hasattr(ctx, "get_accelerator_ids"):
            # New API: Returns dict like {"GPU": [0, 1]}
            accelerator_ids = ctx.get_accelerator_ids()
            print(f"[VLLM] Accelerator IDs: {accelerator_ids}")
            gpu_ids = accelerator_ids.get("GPU", [])
        else:
            # Fallback for older Ray versions
            resource_ids = ctx.get_resource_ids()
            print(f"[VLLM] Raw resource_ids: {resource_ids}")
            gpu_ids = resource_ids.get("GPU", [])

        # Deduplicate device indices to handle potential Ray reporting quirks
        device_indices = []
        for g in gpu_ids:
            if isinstance(g, (list, tuple)):
                device_indices.append(str(int(g[0])))
            else:
                device_indices.append(str(int(g)))
        device_indices = sorted(list(set(device_indices)))
        
        if len(device_indices) < GPUS_PER_REPLICA:
             raise RuntimeError(f"Insufficient distinct GPUs assigned! Expected {GPUS_PER_REPLICA}, got {len(device_indices)}: {device_indices}")

        affinity_mask = ",".join(device_indices)
        os.environ["ZE_AFFINITY_MASK"] = affinity_mask
        os.environ["ZE_FLAT_DEVICE_HIERARCHY"] = "FLAT"
        
        print(f"[VLLM] Init on devices: {affinity_mask} | HF_HOME={os.environ['HF_HOME']}")

        # 2. Model Path Resolution
        model_path_arg = REPO_ID
        candidate_paths = ["/tmp", "/tmp/hub"]
        
        for path in candidate_paths:
            if os.path.exists(os.path.join(path, "config.json")):
                print(f"[VLLM] Found local model files at: {path}")
                model_path_arg = path
                break
        
        if model_path_arg == REPO_ID:
            print(f"[VLLM] No local config.json found in {candidate_paths}. Attempting download/cache lookup for {REPO_ID}")

        # 3. Engine Setup
        # CRITICAL: Set a unique MASTER_PORT to prevent collisions between multiple replicas on the same node
        # when initializing the torch.distributed process group.
        if "MASTER_PORT" not in os.environ:
            # Fix for EADDRINUSE: Use deterministic port based on the first GPU ID assigned to this replica.
            # Ray guarantees unique GPU allocations per replica on a node.
            # Base port 29600 prevents conflict with default 29500.
            context = ray.get_runtime_context()
            gpu_ids = context.get_accelerator_ids().get("GPU", [])
            if gpu_ids:
                # gpu_ids is list of strings e.g. ['0', '1']
                # We use the integer value of the first GPU to offset the port.
                replica_gpu_offset = int(gpu_ids[0])
                master_port = 29600 + replica_gpu_offset
                os.environ["MASTER_PORT"] = str(master_port)
                print(f"[VLLM] Assigned deterministic MASTER_PORT={master_port} (GPU ID {gpu_ids[0]})")
            else:
                # Fallback for CPU-only (should not happen in this setup)
                master_port = get_open_port()
                os.environ["MASTER_PORT"] = str(master_port)
                print(f"[VLLM] Assigned random MASTER_PORT={master_port} (No GPUs found)")

        engine_args = AsyncEngineArgs(
            model=model_path_arg, 
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
        self.ChatCompletionRequest = ChatCompletionRequest


        # FIX: Create OpenAIServingModels instance first (Arg 2 requirement)
        # This wrapper handles model paths and configs, providing the .processor attribute
        base_model_paths = [BaseModelPath(name=REPO_ID, model_path=REPO_ID)]
        self.openai_serving_models = OpenAIServingModels(
            engine_client=self.engine,
            base_model_paths=base_model_paths,
        )

        # FIX: Instantiate Chat with exact signature requirements
        # FIX: Instantiate Chat with exact signature requirements and retry logic for tiktoken races
        import time
        max_retries = 5
        for attempt in range(max_retries):
            try:
                self.openai_serving_chat = OpenAIServingChat(
                    self.engine,                        # Arg 1: engine_client
                    self.openai_serving_models,         # Arg 2: models (OpenAIServingModels instance)
                    response_role="assistant",          # Arg 3: response_role (str)
                    request_logger=None,                # Kwarg: request_logger
                    chat_template=None,                 # Kwarg: chat_template
                    chat_template_content_format="auto" # Kwarg: chat_template_content_format
                )
                break
            except Exception as e:
                print(f"[VLLM] OpenAIServingChat init failed (attempt {attempt+1}/{max_retries}): {e}")
                if attempt == max_retries - 1:
                    raise
                time.sleep(2)
        self.openai_serving_completion = OpenAIServingCompletion(
            self.engine,
            self.openai_serving_models,
            request_logger=None,
        )
        print("[VLLM] Service Ready.")

    @app_vllm.get("/cluster_ready")
    def cluster_ready(self):
        """Checks if the internal Ray Serve status shows all replicas as RUNNING."""
        try:
            # serve.status() returns a ServeStatus object
            status = serve.status()
            
            # Navigate to our application and deployment
            app_status = status.applications.get("vllm_service")
            if not app_status:
                return JSONResponse(status_code=503, content={"status": "initializing", "details": "App not found"})
            
            deploy_status = app_status.deployments.get("VLLMService")
            if not deploy_status:
                return JSONResponse(status_code=503, content={"status": "initializing", "details": "Deployment not found"})
            
            # Check replica counts in "RUNNING" state
            running_count = deploy_status.replica_states.get("RUNNING", 0)
            
            if running_count >= self.target_replicas:
                return JSONResponse(content={"status": "ready", "running_replicas": running_count, "target": self.target_replicas})
            else:
                return JSONResponse(status_code=503, content={
                    "status": "not_ready", 
                    "running_replicas": running_count, 
                    "target": self.target_replicas,
                    "details": f"Waiting for replicas. Status: {deploy_status.replica_states}"
                })
        except Exception as e:
            print(f"Error checking cluster status: {e}")
            traceback.print_exc()
            return JSONResponse(status_code=500, content={"error": str(e)})

    @app_vllm.post("/completions")
    async def completions(self, request: Request):
        try:
            req_json = await request.json()
            request_obj = CompletionRequest(**req_json)
            
            generator = await self.openai_serving_completion.create_completion(request_obj)
            
            if isinstance(generator, ErrorResponse):
                return JSONResponse(content=generator.model_dump(), status_code=generator.code)
            
            if request_obj.stream:
                return StreamingResponse(content=generator, media_type="text/event-stream")
            else:
                return JSONResponse(content=generator.model_dump())
        except Exception as e:
            print(f"Error: {e}")
            traceback.print_exc()
            return JSONResponse(content={"error": str(e)}, status_code=500)

    @app_vllm.post("/chat/completions")
    async def chat_completions(self, request: Request):
        try:
            req_json = await request.json()
            request_obj = self.ChatCompletionRequest(**req_json)
            
            generator = await self.openai_serving_chat.create_chat_completion(request_obj)
            
            if isinstance(generator, property): 
                 return JSONResponse(content={"error": "Generator failed"}, status_code=500)

            if request_obj.stream:
                return StreamingResponse(content=generator, media_type="text/event-stream")
            else:
                return JSONResponse(content=generator.model_dump()) 
        except Exception as e:
            print(f"Error: {e}")
            traceback.print_exc()
            return JSONResponse(content={"error": str(e)}, status_code=500)

    # @app_vllm.middleware("http")
    # async def log_requests(request: Request, call_next):
    #     # print(f"DEBUG: Middleware received request: {request.method} {request.url.path}")
    #     response = await call_next(request)
    #     return response

    @app_vllm.get("/health")
    def health(self):
        return {"status": "ok", "gpu": os.environ.get("ZE_AFFINITY_MASK")}

    @app_vllm.get("/models")
    async def show_models(self):
        return JSONResponse(content={
            "object": "list",
            "data": [{
                "id": REPO_ID,
                "object": "model",
                "created": 1234567890,
                "owned_by": "vllm",
            }]
        })

    @app_vllm.get("/")
    def root(self):
        return {"status": "ok"}
    
    @app_vllm.post("/")
    def root_post(self):
        return {"status": "ok"}

    # Catch-all for debugging and to satisfy ANY weird probe
    @app_vllm.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE"])
    async def catch_all(self, path: str, request: Request):
        print(f"DEBUG: Catch-all hit for path: {path} | Full URL: {request.url}")
        return JSONResponse(content={"status": "ok", "debug_path": path})


if __name__ == "__main__":
    os.environ["PYTHONWARNINGS"] = "ignore::DeprecationWarning"
    ray.init(address="auto")
    print("Connected to Ray Cluster.")

    resources = ray.available_resources()
    total_gpus = resources.get("GPU", 0)
    num_replicas = int(total_gpus // GPUS_PER_REPLICA)

    if num_replicas < 1:
        print("ERROR: Not enough resources for replicas!")
        sys.exit(1)

    # Force 12 replicas if we have enough GPUs (2 nodes * 12 GPUs = 24 GPUs / 2 = 12 replicas)
    # The benchmark uses 12 clients, so 12 replicas is ideal.
    if num_replicas < 12 and total_gpus >= 24:
        print(f"WARNING: Ray reports {num_replicas} replicas but we expect 12. Forcing check.")
    
    # We want to match the aiohttp benchmark which has 12 backends.
    # If Ray autoscaling logic was calculating this, it might have been correct (24 // 2 = 12).
    # But autoscaling config having min/max might have introduced lag.
    
    print(f"Deploying {num_replicas} FIXED replicas (Total GPUs: {total_gpus})...")

    # CRITICAL: Increase keep_alive_timeout_s to 600s (default 5s) to match aiohttp baseline persistence.
    # This prevents the proxy from closing connections during high-load benchmarks.
    serve.start(http_options={
        "host": "0.0.0.0", 
        "port": 8000,
        "keep_alive_timeout_s": 600
    })
    
    serve.run(
        VLLMService.options(
            num_replicas=num_replicas,
            ray_actor_options={
                "num_gpus": GPUS_PER_REPLICA, 
                "num_cpus": 12,
                "runtime_env": {
                    "env_vars": {
                        "OMP_NUM_THREADS": "12",
                        "VLLM_WORKER_MULTIPROC_METHOD": "spawn",
                        "FI_MR_CACHE_MONITOR": "userfaultfd",
                        "TORCH_COMPILE_DISABLE": "1",
                        "TORCH_XPU_ALLOC_CONF": "expandable_segments:True"
                    }
                }
            },
            max_ongoing_requests=1000,
            autoscaling_config=None
        ).bind(num_replicas),
        name="vllm_service",
        route_prefix="/v1",
    )
    

    
    print("Serve Deployment Started.")
    
    import time
    try:
        while True: time.sleep(10)
    except KeyboardInterrupt:
        print("Stopping...")