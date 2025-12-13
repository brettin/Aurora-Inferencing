    #!/bin/bash
    #PBS -N gpt_oss_120b_vllm
    #PBS -l walltime=00:25:00
    #PBS -A candle_aesp_CNDA
    #PBS -q debug
    #PBS -o output_multi_engine.log
    #PBS -e error_multi_engine.log
    #PBS -l select=1
    #PBS -l filesystems=flare:home

    export HTTP_PROXY=http://proxy.alcf.anl.gov:3128
    export HTTPS_PROXY=http://proxy.alcf.anl.gov:3128
    export http_proxy=http://proxy.alcf.anl.gov:3128
    export https_proxy=http://proxy.alcf.anl.gov:3128
    export no_proxy=localhost,127.0.0.1

    # --- 0. PREPARE COPY TOOL ---
    # Path to your C source file (Adjust if needed, assuming it's in the submission dir)
    CPTOTMP_SRC="${PBS_O_WORKDIR}/cptotmp.c"
    CPTOTMP_BIN="/tmp/cptotmp"

    # Compile the tool locally on the compute node
    module load frameworks
    mpicc -o "$CPTOTMP_BIN" "$CPTOTMP_SRC"

    # --- OPTIMIZED ENV VARS ---
    # Re-enable these for better broadcast performance on Aurora
    export MPIR_CVAR_CH4_OFI_ENABLE_MULTI_NIC_STRIPING=1
    export MPIR_CVAR_CH4_OFI_MAX_NICS=4

    start_time=$(date +%s)

    echo "Cleaning up tmp"

    # --- 1. STAGE MODEL WEIGHTS ---
    rm -rf /tmp/hub
    copy_start=$(date +%s)
    MODEL_SOURCE="/flare/AuroraGPT/model-weights/optimized_model/hub"
    MODEL_DEST="/tmp"

    echo "Staging weights from $MODEL_SOURCE to $MODEL_DEST..."

    # Use mpiexec to run the streaming tool
    mpiexec -ppn 1 --cpu-bind numa /tmp/cptotmp "$MODEL_SOURCE" "$MODEL_DEST"

    copy_end=$(date +%s)
    weights_copy_time=$((copy_end - copy_start))

    # --- 2. STAGE & SETUP ENVIRONMENT ---
    module load hdf5
    # We need a base python to run conda-unpack later if the packed env isn't fully standalone yet
    source /opt/aurora/25.190.0/spack/unified/0.10.1/install/linux-sles15-x86_64/gcc-13.3.0/miniforge3-24.3.0-0-gfganax/bin/activate

    env_start=$(date +%s)
    ENV_TAR="/flare/AuroraGPT/ngetty/envs/packed_envs/vllm_env.tar.gz"
    LOCAL_ENV="/tmp/vllm_env"
    ENV_STAGE_DIR="/tmp"

    if [ ! -d "$LOCAL_ENV" ]; then
        mkdir -p "$LOCAL_ENV"
        
        echo "Staging environment tarball..."
        # 2a. Broadcast tarball to /tmp (creates /tmp/vllm_env.tar.gz)
        mpiexec -ppn 1 --cpu-bind numa "$CPTOTMP_BIN" "$ENV_TAR" "$ENV_STAGE_DIR"

        # 2b. Extract to local folder
        TAR_NAME=$(basename "$ENV_TAR")
        echo "Extracting $ENV_STAGE_DIR/$TAR_NAME..."
        tar -xf "$ENV_STAGE_DIR/$TAR_NAME" -C "$LOCAL_ENV"

        # 2c. Cleanup tarball to save space
        rm "$ENV_STAGE_DIR/$TAR_NAME"

        # 2d. Fix paths using conda-unpack
        echo "Running conda-unpack..."
        source "$LOCAL_ENV/bin/activate"
        conda-unpack
    else
        source "$LOCAL_ENV/bin/activate"
    fi
    env_end=$(date +%s)


    # --- 3. CONFIGURE VLLM ---
    if [ -z "${HF_TOKEN:-}" ]; then
        echo "Error: HF_TOKEN not set. Please export it and pass with qsub -v HF_TOKEN"
        exit 1
    fi
    export HF_TOKEN
    export HF_HOME="/tmp"
    export HF_DATASETS_CACHE="/flare/AuroraGPT/model-weights"
    export RAY_TMPDIR="/tmp"
    export TMPDIR="/tmp"

    export ZE_FLAT_DEVICE_HIERARCHY=FLAT
    unset CCL_PROCESS_LAUNCHER
    export CCL_PROCESS_LAUNCHER=None
    export VLLM_WORKER_MULTIPROC_METHOD=spawn
    export FI_MR_CACHE_MONITOR=userfaultfd
    export TORCH_COMPILE_DISABLE=1
    export OMP_NUM_THREADS=16
    export TORCH_XPU_ALLOC_CONF=expandable_segments:True

    # --- 4. RUN VLLM ENGINES ---
    echo "Starting vLLM engines..."

    declare -a VLLM_PIDS
    declare -a TAIL_PIDS

    ZE_AFFINITY_MASK=0,1 \
    vllm serve openai/gpt-oss-120b \
    --port 8080 \
    --disable-custom-all-reduce \
    --enforce-eager \
    --distributed-executor-backend mp \
    --tensor-parallel-size 2 \
    --dtype bfloat16 > vllm_8080.log 2>&1 &
    VLLM_PIDS+=($!)
    tail -f vllm_8080.log &
    TAIL_PIDS+=($!)

    ZE_AFFINITY_MASK=2,3 \
    vllm serve openai/gpt-oss-120b \
    --port 8081 \
    --disable-custom-all-reduce \
    --enforce-eager \
    --distributed-executor-backend mp \
    --tensor-parallel-size 2 \
    --dtype bfloat16 > vllm_8081.log 2>&1 &
    VLLM_PIDS+=($!)
    tail -f vllm_8081.log &
    TAIL_PIDS+=($!)

    ZE_AFFINITY_MASK=4,5 \
    vllm serve openai/gpt-oss-120b \
    --port 8082 \
    --disable-custom-all-reduce \
    --enforce-eager \
    --distributed-executor-backend mp \
    --tensor-parallel-size 2 \
    --dtype bfloat16 > vllm_8082.log 2>&1 &
    VLLM_PIDS+=($!)
    tail -f vllm_8082.log &
    TAIL_PIDS+=($!)

    ZE_AFFINITY_MASK=6,7 \
    vllm serve openai/gpt-oss-120b \
    --port 8083 \
    --disable-custom-all-reduce \
    --enforce-eager \
    --distributed-executor-backend mp \
    --tensor-parallel-size 2 \
    --dtype bfloat16 > vllm_8083.log 2>&1 &
    VLLM_PIDS+=($!)
    tail -f vllm_8083.log &
    TAIL_PIDS+=($!)

    ZE_AFFINITY_MASK=8,9 \
    vllm serve openai/gpt-oss-120b \
    --port 8084 \
    --disable-custom-all-reduce \
    --enforce-eager \
    --distributed-executor-backend mp \
    --tensor-parallel-size 2 \
    --dtype bfloat16 > vllm_8084.log 2>&1 &
    VLLM_PIDS+=($!)
    tail -f vllm_8084.log &
    TAIL_PIDS+=($!) 

    ZE_AFFINITY_MASK=10,11 \
    vllm serve openai/gpt-oss-120b \
    --port 8085 \
    --disable-custom-all-reduce \
    --enforce-eager \
    --distributed-executor-backend mp \
    --tensor-parallel-size 2 \
    --dtype bfloat16 > vllm_8085.log 2>&1 &
    VLLM_PIDS+=($!)
    tail -f vllm_8085.log &
    TAIL_PIDS+=($!) 

    wait_for_health() {
        local port=$1
        echo "Waiting for vLLM on port $port..."
        until curl -s -f http://localhost:${port}/health > /dev/null; do
            sleep 2
        done
        echo "vLLM on port $port is healthy."
    }

    # --- 5. WAIT FOR READINESS ---
    wait_for_health 8080
    wait_for_health 8081
    wait_for_health 8082
    wait_for_health 8083
    wait_for_health 8084
    wait_for_health 8085
    
    echo "All vLLM engines are ready."
    
    end_time=$(date +%s)
    if [ -z "$checkpoint_start" ]; then
        checkpoint_start=$end_time
    fi

   # --- 6. RUN BENCHMARKS ---
    echo "Starting benchmarks..."

    MODEL="openai/gpt-oss-120b"
    NUM_PROMPTS=100
    INPUT_LEN=3024
    OUTPUT_LEN=1024
    BASE_URL="http://localhost" # <--- FIX 1: Added http://

    # Arrays to store benchmark PIDs
    declare -a BENCH_PIDS

    vllm bench serve \
    --model $MODEL \
    --backend openai \
    --base-url ${BASE_URL}:8080 \
    --dataset-name random \
    --seed 12345 \
    --num-prompts $NUM_PROMPTS \
    --random-input-len $INPUT_LEN \
    --random-output-len $OUTPUT_LEN \
    > /home/ngetty/proj/vllm_gpt-oss/Aurora-Inferencing/cluster_scaling/bench_tp2/bench_8080.log 2>&1 &
    BENCH_PIDS+=($!)

    vllm bench serve \
    --model $MODEL \
    --backend openai \
    --base-url ${BASE_URL}:8081 \
    --dataset-name random \
    --seed 12345 \
    --num-prompts $NUM_PROMPTS \
    --random-input-len $INPUT_LEN \
    --random-output-len $OUTPUT_LEN \
    > /home/ngetty/proj/vllm_gpt-oss/Aurora-Inferencing/cluster_scaling/bench_tp2/bench_8081.log 2>&1 &
    BENCH_PIDS+=($!)

    vllm bench serve \
    --model $MODEL \
    --backend openai \
    --base-url ${BASE_URL}:8082 \
    --dataset-name random \
    --seed 12345 \
    --num-prompts $NUM_PROMPTS \
    --random-input-len $INPUT_LEN \
    --random-output-len $OUTPUT_LEN \
    > /home/ngetty/proj/vllm_gpt-oss/Aurora-Inferencing/cluster_scaling/bench_tp2/bench_8082.log 2>&1 &
    BENCH_PIDS+=($!)

    vllm bench serve \
    --model $MODEL \
    --backend openai \
    --base-url ${BASE_URL}:8083 \
    --dataset-name random \
    --seed 12345 \
    --num-prompts $NUM_PROMPTS \
    --random-input-len $INPUT_LEN \
    --random-output-len $OUTPUT_LEN \
    > /home/ngetty/proj/vllm_gpt-oss/Aurora-Inferencing/cluster_scaling/bench_tp2/bench_8083.log 2>&1 &
    BENCH_PIDS+=($!)

    vllm bench serve \
    --model $MODEL \
    --backend openai \
    --base-url ${BASE_URL}:8084 \
    --dataset-name random \
    --seed 12345 \
    --num-prompts $NUM_PROMPTS \
    --random-input-len $INPUT_LEN \
    --random-output-len $OUTPUT_LEN \
    > /home/ngetty/proj/vllm_gpt-oss/Aurora-Inferencing/cluster_scaling/bench_tp2/bench_8084.log 2>&1 &
    BENCH_PIDS+=($!)

    vllm bench serve \
    --model $MODEL \
    --backend openai \
    --base-url ${BASE_URL}:8085 \
    --dataset-name random \
    --seed 12345 \
    --num-prompts $NUM_PROMPTS \
    --random-input-len $INPUT_LEN \
    --random-output-len $OUTPUT_LEN \
    > /home/ngetty/proj/vllm_gpt-oss/Aurora-Inferencing/cluster_scaling/bench_tp2/bench_8085.log 2>&1 &
    BENCH_PIDS+=($!)

    # Wait only for the benchmarks, ignoring the tail -f processes
    for pid in "${BENCH_PIDS[@]}"; do
        wait "$pid"
    done
    
    echo "Benchmarks completed."
    
    # Optional: Kill the tail processes now that we are done
    kill "${TAIL_PIDS[@]}" 2>/dev/null


    # --- 7. REPORT METRICS ---
    env_time=$((env_end - env_start))
    vllm_init_time=$((checkpoint_start - env_end))
    weights_load_time=$((end_time - checkpoint_start))
    total_time=$((end_time - start_time))

    echo "----------------------------------------------------------------"
    echo "Performance Metrics (Single Node with cptotmp)"
    echo "----------------------------------------------------------------"
    echo "Weights Staging Time (Lustre -> /tmp): $weights_copy_time seconds"
    echo "Environment Setup Time (Copy + Untar + Unpack): $env_time seconds"
    echo "VLLM Init Time (Env Ready -> Loading Checkpoints): $vllm_init_time seconds"
    echo "Weights Loading Time (Loading Checkpoints -> Ready): $weights_load_time seconds"
    echo "Total Time: $total_time seconds"