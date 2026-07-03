#!/bin/bash
# clio_env.sh — environment for using the clio-core / IOWarp CTE POSIX adapter
# to accelerate MiV case-6 I/O via LD_PRELOAD on TACC Vista (ARM aarch64).
#
# Source this from a run job:  source /work/11623/hyoklee/vista/bin/clio_env.sh
#
# It defines (contract used by run_case6.slurm):
#   CLIO_POSIX_LIB       absolute path to the LD_PRELOAD .so
#   CLIO_RUNTIME_START   shell command string to start the CTE runtime daemon
#                        (run with:  eval "$CLIO_RUNTIME_START"  before the app)
#   CLIO_RUNTIME_STOP    shell command string to stop/clean up
#                        (run with:  eval "$CLIO_RUNTIME_STOP"   after the app)
#   CLIO_SERVER_CONF     path to the runtime config (RAM tier) it reads
#   CHIMAERA_CONF        alias of CLIO_SERVER_CONF (same file)
#
# Safe to source alongside the MiV venv: it does NOT run `conda activate`, does
# NOT touch PATH/python, and only prepends the clio-core + conda runtime libs to
# LD_LIBRARY_PATH so the daemon and the preload .so resolve their deps
# (libclio_run_cxx, zeromq, yaml-cpp, boost, libstdc++ from conda gcc-15, ...).
#
# The runtime was built with MPI OFF -> single-node uses shared-memory IPC, no
# openmpi module required. It does NOT need the MiV phdf5/openmpi modules, so
# this file deliberately does not load them (avoids toolchain conflicts).

# --- locations ---------------------------------------------------------------
export CLIO_CONDA_ENV="${CLIO_CONDA_ENV:-$HOME/miniconda3/envs/iowarp}"
export CLIO_BUILD_DIR="${CLIO_BUILD_DIR:-/work/11623/hyoklee/vista/build/clio-core}"
export CLIO_BIN="$CLIO_BUILD_DIR/bin"

# --- the LD_PRELOAD POSIX interceptor ----------------------------------------
export CLIO_POSIX_LIB="$CLIO_BIN/libclio_cte_posix.so"

# --- runtime config (RAM storage tier) ---------------------------------------
export CLIO_SERVER_CONF="/work/11623/hyoklee/vista/bin/chimaera_case6.yaml"
export CHIMAERA_CONF="$CLIO_SERVER_CONF"      # coordinator-facing alias
# The runtime dlopen's the chimod .so's (clio_bdev/cte/filesystem) from here:
export CLIO_REPO_PATH="$CLIO_BIN"

# --- runtime library resolution (no conda activate) --------------------------
# Prepend build bin (clio .so's) then conda env lib (zmq, yaml-cpp, boost,
# libstdc++, ...). Placed in front so the conda gcc-15 libstdc++ (which the
# preload lib needs) is preferred over the older system one.
export LD_LIBRARY_PATH="$CLIO_BIN:$CLIO_CONDA_ENV/lib:${LD_LIBRARY_PATH:-}"

# clio_run daemon logging / bookkeeping (per-job under $SCRATCH).
export CLIO_RUNTIME_LOG="${CLIO_RUNTIME_LOG:-/scratch/11623/hyoklee/miv/logs/clio_runtime_${SLURM_JOB_ID:-local}.log}"
export CLIO_PIDFILE="${CLIO_PIDFILE:-/scratch/11623/hyoklee/miv/logs/clio_runtime_${SLURM_JOB_ID:-local}.pid}"

# --- start / stop commands (eval'd by the run script) ------------------------
# START (single node): launch one daemon, background it, wait for it to come up.
# The daemon auto-composes the pools in $CLIO_SERVER_CONF (no separate compose).
# For >1 node you would launch one daemon per node (e.g. `srun --ntasks-per-node=1
# $CLIO_BIN/clio_run runtime start`) — but multi-node chimaera has shown
# deadlocks in prior runs, so single-node is the supported path here.
export CLIO_RUNTIME_START="mkdir -p \"\$(dirname \"\$CLIO_RUNTIME_LOG\")\"; \"$CLIO_BIN/clio_run\" runtime start > \"\$CLIO_RUNTIME_LOG\" 2>&1 & echo \$! > \"\$CLIO_PIDFILE\"; sleep 8"

# STOP: ask the runtime to stop cleanly, then hard-kill any stragglers and wipe
# the per-user shared-memory segments / memfd symlinks so a re-run starts clean.
export CLIO_RUNTIME_STOP="\"$CLIO_BIN/clio_run\" stop >/dev/null 2>&1 || true; [ -f \"\$CLIO_PIDFILE\" ] && kill \$(cat \"\$CLIO_PIDFILE\") 2>/dev/null; pkill -9 -f 'clio_run runtime start' 2>/dev/null; rm -rf /tmp/clio_\${USER}/* /tmp/clio/* /dev/shm/clio_* 2>/dev/null; true"

# Convenience: how the app is launched under the interceptor.
#   LD_PRELOAD=$CLIO_POSIX_LIB  <app ...>
# and any file the app should route through CTE must be named with a leading
# "clio::" marker on its path, e.g.  clio::/scratch/.../output.h5
export CLIO_LD_PRELOAD="$CLIO_POSIX_LIB"
