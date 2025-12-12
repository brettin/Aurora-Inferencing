module load frameworks
pip install conda-pack
conda pack -p /lus/flare/projects/datasets/softwares/envs/conda_envs/RC1_vllm_0.11.x_triton_3.5.0+git1b0418a9_no_patch_oneapi_2025.2.0_numpy_2.3.4_python3.12.8 \
-o /flare/AuroraGPT/ngetty/envs/packed_envs/vllm_env.tar.gz --compress-level 0
