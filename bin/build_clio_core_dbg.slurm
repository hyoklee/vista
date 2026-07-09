#!/bin/bash
#SBATCH -J clio_dbg
#SBATCH -p gg
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 03:00:00
#SBATCH -A IBN22011
#SBATCH -o /scratch/11623/hyoklee/miv/logs/clio_build_%j.out
#SBATCH -e /scratch/11623/hyoklee/miv/logs/clio_build_%j.err
#
# build_clio_core.slurm — native ARM (aarch64) build of clio-core / IOWarp CTE
# on TACC Vista, producing the POSIX LD_PRELOAD interception adapter.
#
# Prereq: the `iowarp` conda env must already contain clio-core's deps
# (run bin/clio_prep_deps.sh once on the login node) PLUS `elfutils`
# (installed here if missing — needed because we build with ELF=ON, which
# upstream leaves OFF so libelf is not in the conda recipe).
#
# KEY difference vs the Frontera build: -DCLIO_CORE_ENABLE_ELF=ON so the
# POSIX interceptor (libclio_cte_posix.so) is actually built.
set -euo pipefail

REPO=/work/11623/hyoklee/clio-core
BUILD_DIR=/work/11623/hyoklee/vista/build/clio-core-dbg
ENV_NAME=iowarp

echo "=== Node: $(hostname)  arch: $(uname -m)  date: $(date) ==="

source "$HOME/miniconda3/etc/profile.d/conda.sh"
conda activate "$ENV_NAME"
export CONDA_PREFIX
echo "CONDA_PREFIX=$CONDA_PREFIX"

# Make conda's pkg-config files discoverable (libelf.pc, zlib.pc, ...).
export PKG_CONFIG_PATH="$CONDA_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# ELF support: ensure libelf (elfutils) + zlib (libelf.pc Requires zlib) and
# their pkg-config files are present. Upstream leaves ELF OFF so neither the
# elfutils nor the zlib *dev* package (with .pc) is in the conda recipe.
if ! pkg-config --exists libelf 2>/dev/null; then
    echo "=== libelf not found; conda-installing elfutils + zlib ==="
    conda install -y -c conda-forge elfutils zlib
fi
echo "libelf: $(pkg-config --modversion libelf 2>/dev/null || echo MISSING)"
echo "zlib:   $(pkg-config --modversion zlib 2>/dev/null || echo MISSING)"

# GLIBC compatibility: the conda gcc's default sysroot ships glibc 2.39, which
# bakes GLIBC_2.38 symbol versions into the binaries. Vista compute nodes run
# system glibc 2.34, so those binaries fail to load ("GLIBC_2.38 not found").
# Pin the conda sysroot to 2.34 so all artifacts (incl. the LD_PRELOAD
# libclio_cte_posix.so) link against symbols present in the system glibc.
_SYSROOT_VER="$(conda list 2>/dev/null | awk '/^sysroot_linux-aarch64/{print $2}')"
if [ "$_SYSROOT_VER" != "2.34" ]; then
    echo "=== pinning sysroot_linux-aarch64=2.34 (was ${_SYSROOT_VER:-none}) ==="
    conda install -y -c conda-forge "sysroot_linux-aarch64=2.34"
fi
echo "sysroot: $(conda list 2>/dev/null | awk '/^sysroot_linux-aarch64/{print $2}')"

# Use the conda toolchain (aarch64-conda-linux-gnu) if present.
CC_BIN="$(ls "$CONDA_PREFIX"/bin/*-conda-linux-gnu-cc 2>/dev/null | head -1 || true)"
CXX_BIN="$(ls "$CONDA_PREFIX"/bin/*-conda-linux-gnu-c++ 2>/dev/null | head -1 || true)"
CC_ARG=(); if [ -n "$CC_BIN" ]; then CC_ARG=(-DCMAKE_C_COMPILER="$CC_BIN" -DCMAKE_CXX_COMPILER="$CXX_BIN"); fi
echo "C compiler: ${CC_BIN:-<cmake default>}"

CMAKE="$(command -v cmake)"
echo "cmake: $CMAKE ($($CMAKE --version | head -1))"

mkdir -p "$BUILD_DIR"

"$CMAKE" -S "$REPO" -B "$BUILD_DIR" -G "Unix Makefiles" \
  "${CC_ARG[@]}" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O2 -g -fno-omit-frame-pointer" -DCMAKE_C_FLAGS_RELWITHDEBINFO="-O2 -g -fno-omit-frame-pointer" -DCMAKE_PREFIX_PATH="$CONDA_PREFIX" \
  -DCLIO_CORE_ENABLE_RUNTIME=ON -DCLIO_CORE_ENABLE_CTE=ON -DCLIO_CORE_ENABLE_CAE=ON \
  -DCLIO_CORE_ENABLE_CEE=ON -DCLIO_CORE_ENABLE_TESTS=ON \
  -DCLIO_CORE_ENABLE_ELF=ON \
  -DCLIO_CTE_ENABLE_COMPRESS=OFF -DCLIO_CORE_ENABLE_GRAY_SCOTT=OFF \
  -DCLIO_CTE_ENABLE_ADIOS2_ADAPTER=OFF -DCLIO_CORE_ENABLE_CONDA=OFF \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DCLIO_CORE_ENABLE_ASAN=OFF \
  -DCLIO_CORE_ENABLE_PYTHON=ON -DCLIO_CORE_ENABLE_COVERAGE=OFF

echo "=== Configure done; building ==="
"$CMAKE" --build "$BUILD_DIR" -j "$(nproc)" 2>&1

echo "=== Build finished. Locating POSIX interceptor + runtime ==="
find "$BUILD_DIR" -name 'libclio_cte_posix*.so' -o -name 'clio_run' -o \
     -name 'libclio_cte_filesystem*.so' -o -name 'libclio_cte_core_runtime.so' 2>/dev/null

echo "=== DONE $(date) ==="
