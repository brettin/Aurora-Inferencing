#!/bin/bash
#PBS -l walltime=00:10:00
#PBS -A candle_aesp_CNDA
#PBS -q debug-scaling
#PBS -o output.log
#PBS -e error.log
#PBS -l select=4
#PBS -l filesystems=flare:home
#PBS -l place=scatter

SCRIPT_DIR="/lus/flare/projects/candle_aesp_CNDA/brettin/Aurora-Inferencing/serverless-test"

NN=$(cat $PBS_NODEFILE | wc -l)
NP=$(( NN * 12 ))
PPN=12
echo "mpiexec -np $NP -ppn $PPN ${SCRIPT_DIR}/gpu_tile_compact.sh ${SCRIPT_DIR}/simple_test.sh"
mpiexec -np $NP -ppn $PPN ${SCRIPT_DIR}/gpu_tile_compact.sh ${SCRIPT_DIR}/simple_test.sh
