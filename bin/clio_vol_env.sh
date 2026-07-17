#!/bin/bash
# clio_vol_env.sh — environment for using the clio-core HDF5 VOL connector to
# transparently mirror MiV case-6 HDF5 I/O into the IOWarp CTE on TACC Vista.
#
# Source this from a run job:  source /work/11623/hyoklee/vista/bin/clio_vol_env.sh
#
# Unlike the POSIX interceptor path (clio_env.sh, LD_PRELOAD + "clio::" path
# markers), the VOL connector is loaded by HDF5 itself via the standard plugin
# mechanism and intercepts at the HDF5 dataset-I/O layer — no path renaming, no
# LD_PRELOAD of an interceptor. Every H5Fopen/H5Fcreate the app does routes
# through the "clio" connector, which delegates to the native VOL (authoritative
# file on disk) and additionally mirrors whole-dataset atomic transfers to CTE.
#
# It reuses clio_env.sh for the runtime daemon machinery (CLIO_RUNTIME_START /
# _STOP), the single-consistent-build CLIO_PRELOAD glob, and LD_LIBRARY_PATH, then
# layers the two HDF5 plugin env vars on top.
#
# Contract used by run_case6_vol.slurm:
#   CLIO_VOL_LIB          absolute path to libclio_hdf5_vol.so
#   HDF5_PLUGIN_PATH      dir HDF5 dlopen()s the connector from (= $CLIO_BIN)
#   HDF5_VOL_CONNECTOR    "clio" (under-VOL defaults to native)
#   CLIO_PRELOAD          this-build clio libs, force-loaded for ABI consistency
#   CLIO_RUNTIME_START / CLIO_RUNTIME_STOP   daemon start/stop (from clio_env.sh)

# Pull in the runtime machinery + CLIO_BIN + CLIO_PRELOAD + LD_LIBRARY_PATH.
# (clio_env.sh does NOT conda-activate or touch python/PATH, so it is safe to
# source alongside the MiV venv + phdf5 module.)
source /work/11623/hyoklee/vista/bin/clio_env.sh

# --- the HDF5 VOL connector --------------------------------------------------
export CLIO_VOL_LIB="$CLIO_BIN/libclio_hdf5_vol.so"

# HDF5 plugin discovery: on the first H5Fopen/H5Fcreate, HDF5 dlopen()s plugins
# on HDF5_PLUGIN_PATH and matches by connector name.
export HDF5_PLUGIN_PATH="$CLIO_BIN"
export HDF5_VOL_CONNECTOR="clio"

# VOL-compatibility shim: put bin/ on PYTHONPATH so bin/sitecustomize.py is
# auto-imported at interpreter startup. It makes h5py's mode-"a" file open
# VOL-robust (h5py's create-fallback is skipped through a non-native VOL because
# the "file not found" errno is masked by an H5VL "Can't open object" error).
# It is a NO-OP unless HDF5_VOL_CONNECTOR is set, so native runs are untouched.
export PYTHONPATH="/work/11623/hyoklee/vista/bin:${PYTHONPATH:-}"

# Optional access telemetry (per-access JSONL + per-file summary). Set
# CLIO_VOL_TRACE=<dir> to enable; left unset here (zero overhead when unset).
# export CLIO_VOL_TRACE="/scratch/11623/hyoklee/miv/results/voltrace"

echo "clio VOL: lib=$CLIO_VOL_LIB  HDF5_PLUGIN_PATH=$HDF5_PLUGIN_PATH  HDF5_VOL_CONNECTOR=$HDF5_VOL_CONNECTOR"
