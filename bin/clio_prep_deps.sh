#!/bin/bash
# clio_prep_deps.sh — populate the `iowarp` conda env with clio-core's
# build/host/run dependencies for TACC Vista (ARM aarch64).
#
# This wraps clio-core's CI/ci-deps.sh --only-deps: it renders the conda
# recipe and conda-installs the union of build/host/run deps into the
# active env (thallium, mercury, yaml-cpp, boost, hdf5, mpi, cereal, etc.).
# Network-bound (conda-forge). Safe to run on the Vista login node.
#
# Usage:  ./clio_prep_deps.sh            (release preset, iowarp env)
set -euo pipefail

REPO=/work/11623/hyoklee/clio-core
ENV_NAME=iowarp
PRESET="${1:-release}"

source "$HOME/miniconda3/etc/profile.d/conda.sh"
conda activate "$ENV_NAME"
echo "Active env: $CONDA_PREFIX"

cd "$REPO"
# Make sure submodules are present (chimaera transport primitives, etc.)
git submodule update --init --recursive 2>/dev/null || true

# --only-deps: install deps only, do NOT conda-build iowarp-core itself.
exec ./CI/ci-deps.sh --only-deps "$PRESET"
