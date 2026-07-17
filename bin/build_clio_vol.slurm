#!/bin/bash
#SBATCH -J clio_vol_build
#SBATCH -p gg
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 03:00:00
#SBATCH -A IBN22011
#SBATCH -o /scratch/11623/hyoklee/miv/logs/clio_vol_build_%j.out
#SBATCH -e /scratch/11623/hyoklee/miv/logs/clio_vol_build_%j.err
#
# build_clio_vol.slurm — native ARM (aarch64) build of clio-core / IOWarp CTE on
# TACC Vista, producing BOTH the POSIX LD_PRELOAD interceptor AND the HDF5 VOL
# connector (libclio_hdf5_vol.so).
#
# Same proven recipe as build_clio_core.slurm (conda `iowarp` toolchain + deps,
# glibc-2.34 sysroot pin, ELF=ON) with two additions:
#   -DCLIO_CTE_ENABLE_HDF5_VOL=ON
#   -DHDF5_DIR=<module phdf5/1.14.6 cmake dir>   (force the SAME HDF5 that
#                                                 h5py / neuroh5 / MiV link:
#                                                 parallel 1.14.6, soname 310 —
#                                                 NOT the conda env's 2.1.0)
#
# The VOL connector is ABI-coupled to the libhdf5 of the app that dlopen()s it
# (h5py). Linking anything other than phdf5/1.14.6 makes HDF5 refuse the plugin.
# We therefore load the openmpi/5.0.5 + phdf5/1.14.6 modules so the parallel
# HDF5 cmake config's MPI requirement resolves to the module MPI, while the
# clio C/C++ TUs still compile with the pinned conda toolchain.
set -euo pipefail

REPO=/work/11623/hyoklee/clio-core
BUILD_DIR=/work/11623/hyoklee/vista/build/clio-core
ENV_NAME=iowarp
HDF5_CMAKE_DIR=/home1/apps/gcc14/openmpi5/phdf5/1.14.6/cmake

echo "=== Node: $(hostname)  arch: $(uname -m)  date: $(date) ==="

source "$HOME/miniconda3/etc/profile.d/conda.sh"
conda activate "$ENV_NAME"
export CONDA_PREFIX
echo "CONDA_PREFIX=$CONDA_PREFIX"

# --- module HDF5 (same as the MiV stack) + its MPI ---------------------------
# Load AFTER conda activate; compilers are pinned via -DCMAKE_*_COMPILER below
# so module gcc/mpicc on PATH does not hijack the clio TU compilation. We only
# want the module to expose parallel HDF5 1.14.6 + openmpi 5.0.5 to find_package.
module load gcc/14.2.0     2>/dev/null || true
module load openmpi/5.0.5  2>/dev/null || true
module load phdf5/1.14.6   2>/dev/null || true
echo "h5pcc: $(command -v h5pcc || echo MISSING)  -> $(h5pcc -showconfig 2>/dev/null | awk -F': *' '/HDF5 Version/{print $2}')"

# Make conda's pkg-config files discoverable (libelf.pc, zlib.pc, ...).
export PKG_CONFIG_PATH="$CONDA_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# ELF support deps (see build_clio_core.slurm).
if ! pkg-config --exists libelf 2>/dev/null; then
    echo "=== libelf not found; conda-installing elfutils + zlib ==="
    conda install -y -c conda-forge elfutils zlib
fi
echo "libelf: $(pkg-config --modversion libelf 2>/dev/null || echo MISSING)"

# GLIBC compatibility: pin the conda sysroot to 2.34 (Vista compute nodes run
# system glibc 2.34) so all artifacts load. See build_clio_core.slurm.
_SYSROOT_VER="$(conda list 2>/dev/null | awk '/^sysroot_linux-aarch64/{print $2}')"
if [ "$_SYSROOT_VER" != "2.34" ]; then
    echo "=== pinning sysroot_linux-aarch64=2.34 (was ${_SYSROOT_VER:-none}) ==="
    conda install -y -c conda-forge "sysroot_linux-aarch64=2.34"
fi
echo "sysroot: $(conda list 2>/dev/null | awk '/^sysroot_linux-aarch64/{print $2}')"

# Use the conda toolchain (aarch64-conda-linux-gnu) for the clio TUs.
CC_BIN="$(ls "$CONDA_PREFIX"/bin/*-conda-linux-gnu-cc 2>/dev/null | head -1 || true)"
CXX_BIN="$(ls "$CONDA_PREFIX"/bin/*-conda-linux-gnu-c++ 2>/dev/null | head -1 || true)"
CC_ARG=(); if [ -n "$CC_BIN" ]; then CC_ARG=(-DCMAKE_C_COMPILER="$CC_BIN" -DCMAKE_CXX_COMPILER="$CXX_BIN"); fi
echo "C compiler: ${CC_BIN:-<cmake default>}"

CMAKE="$(command -v cmake)"
echo "cmake: $CMAKE ($($CMAKE --version | head -1))"

# Clean reconfigure: dev moved a lot since the last (Jul-9) build, and the
# memory lesson is to always wipe the tree after pulling dev (stale CMake cache
# from an older commit caused a misdiagnosed 'ARM bug'). Fresh tree = 1 build.
echo "=== wiping $BUILD_DIR for a clean reconfigure ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

"$CMAKE" -S "$REPO" -B "$BUILD_DIR" -G "Unix Makefiles" \
  "${CC_ARG[@]}" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$CONDA_PREFIX" \
  -DCLIO_CORE_ENABLE_RUNTIME=ON -DCLIO_CORE_ENABLE_CTE=ON -DCLIO_CORE_ENABLE_CAE=ON \
  -DCLIO_CORE_ENABLE_CEE=ON -DCLIO_CORE_ENABLE_TESTS=ON \
  -DCLIO_CORE_ENABLE_ELF=ON \
  -DCLIO_CTE_ENABLE_HDF5_VOL=ON -DHDF5_DIR="$HDF5_CMAKE_DIR" \
  -DCLIO_CTE_ENABLE_COMPRESS=OFF -DCLIO_CORE_ENABLE_GRAY_SCOTT=OFF \
  -DCLIO_CTE_ENABLE_ADIOS2_ADAPTER=OFF -DCLIO_CORE_ENABLE_CONDA=OFF \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DCLIO_CORE_ENABLE_ASAN=OFF \
  -DCLIO_CORE_ENABLE_PYTHON=ON -DCLIO_CORE_ENABLE_COVERAGE=OFF

echo "=== Configure done. Verifying HDF5 the VOL will link ==="
grep -E "HDF5_VERSION|HDF5_DIR|HDF5_C_LIBRARY|Building HDF5 VOL" "$BUILD_DIR/CMakeCache.txt" 2>/dev/null | head || true

echo "=== Building (full) ==="
"$CMAKE" --build "$BUILD_DIR" -j "$(nproc)" 2>&1

echo "=== Build finished. Locating VOL + POSIX interceptor + runtime ==="
find "$BUILD_DIR" -name 'libclio_hdf5_vol*.so' -o -name 'libclio_cte_posix*.so' \
     -o -name 'clio_run' 2>/dev/null

VOL_SO="$(find "$BUILD_DIR" -name 'libclio_hdf5_vol.so' 2>/dev/null | head -1)"
if [ -n "$VOL_SO" ]; then
    echo "=== ldd $VOL_SO | grep hdf5 (MUST be phdf5/1.14.6, soname 310) ==="
    ldd "$VOL_SO" | grep -i hdf5 || echo "  (no libhdf5 in ldd — check link)"
fi

echo "=== DONE $(date) ==="
