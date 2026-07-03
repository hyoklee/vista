#!/bin/bash
# env_miv.sh - shared environment for MiV-Simulator case 6 on TACC Vista (ARM aarch64).
# Source this from build and run jobs:  source /work/11623/hyoklee/vista/bin/env_miv.sh
#
# Toolchain notes (Vista):
#  - phdf5/1.14.6 is built under nvidia24 + openmpi/5.0.5, so we keep that MPI so
#    h5py / neuroh5 / mpi4py link against the same parallel HDF5 the module ships.
#  - The C/C++ compiler used by mpicc/mpicxx is GCC 14 (loaded below); openmpi's
#    wrappers pick up whichever gcc/g++ is first on PATH via OMPI_CC/OMPI_CXX.
#  - CPU-only: gap-junction / NEURON simulation runs on Grace cores, no GPU.

# --- paths -------------------------------------------------------------------
export MIV_ROOT=/work/11623/hyoklee
export VISTA=/work/11623/hyoklee/vista
export MIV_BUILD=$VISTA/build
export MIV_VENV=$MIV_BUILD/miv/.venv
export MIV_SCRATCH=/scratch/11623/hyoklee/miv
export CASES=$MIV_ROOT/Miv-Simulator-Cases
export CASE6=$CASES/6-gapjunctions

# --- modules -----------------------------------------------------------------
module purge 2>/dev/null
module load gcc/14.2.0            2>/dev/null
module load openmpi/5.0.5         2>/dev/null
module load phdf5/1.14.6          2>/dev/null
module load cmake/4.1.1           2>/dev/null

# Make openmpi wrappers use gcc-14 explicitly.
export OMPI_CC=gcc
export OMPI_CXX=g++
export CC=mpicc
export CXX=mpicxx
# Vista login/compute nodes lack the knem device; silence the OpenMPI warning.
export OMPI_MCA_smsc=^knem

# --- uv ----------------------------------------------------------------------
export PATH=$HOME/.local/bin:$PATH
export UV_PROJECT_ENVIRONMENT=$MIV_VENV

# --- parallel-HDF5 build hints for h5py / neuroh5 ----------------------------
export HDF5_MPI=ON
# HDF5_DIR resolved from the h5pcc wrapper on PATH (phdf5 module).
if command -v h5pcc >/dev/null 2>&1; then
    _h5prefix=$(h5pcc -showconfig 2>/dev/null | awk -F': *' '/Installation point/{print $2}')
    [ -n "$_h5prefix" ] && export HDF5_DIR=$_h5prefix
fi

# Activate the venv if it exists (run jobs); build job creates it first.
if [ -f "$MIV_VENV/bin/activate" ]; then
    # shellcheck disable=SC1091
    source "$MIV_VENV/bin/activate"
fi
