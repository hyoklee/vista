#!/bin/bash
# clio_env_2node.sh — environment for a 2-NODE distributed clio-core / IOWarp
# CTE cluster on TACC Vista over InfiniBand (ib0). Source from a >=2-node
# Slurm allocation's run job:
#   source /work/11623/hyoklee/vista/bin/clio_env_2node.sh
#
# Builds on the single-node clio_env.sh (same CLIO_POSIX_LIB, LD_LIBRARY_PATH,
# CLIO_REPO_PATH) but overrides the runtime config + start/stop for multi-node.
#
# Contract (same as single-node, used by run_case6.slurm):
#   CLIO_POSIX_LIB       LD_PRELOAD .so (unchanged)
#   CLIO_SERVER_CONF     2-node RAM-tier config (chimaera_case6_2node.yaml)
#   CHIMAERA_CONF        alias of CLIO_SERVER_CONF
#   CLIO_HOSTFILE        path to the per-allocation ib0 hostfile (generated at start)
#   CLIO_RUNTIME_START   eval'd to launch one daemon per node over ib0
#   CLIO_RUNTIME_STOP    eval'd to tear the cluster down + clean shm
#
# Peer discovery is by hostfile (ib0 IPs, node_id = line order); each daemon
# self-identifies via its local ib0 IP and binds its cross-node ROUTER there.

# Pull in the common single-node definitions first (CLIO_BIN, CLIO_POSIX_LIB,
# LD_LIBRARY_PATH, CLIO_REPO_PATH, logging paths).
source /work/11623/hyoklee/vista/bin/clio_env.sh

# --- multi-node overrides ----------------------------------------------------
export CLIO_SERVER_CONF="/work/11623/hyoklee/vista/bin/chimaera_case6_2node.yaml"
export CHIMAERA_CONF="$CLIO_SERVER_CONF"

# Per-allocation hostfile of ib0 IPs (shared on $SCRATCH so every daemon reads
# an identical node ordering).
export CLIO_HOSTFILE="${CLIO_HOSTFILE:-/scratch/11623/hyoklee/miv/logs/clio_hostfile_${SLURM_JOB_ID:-local}.txt}"

# Force TCP transport over ib0 (IPoIB). SHM/IPC modes are single-node only.
export CLIO_IPC_MODE="${CLIO_IPC_MODE:-TCP}"

# START / STOP delegate to helper scripts (keeps the eval'd string trivial and
# the multi-step srun logic maintainable/debuggable).
export CLIO_RUNTIME_START="bash /work/11623/hyoklee/vista/bin/clio_2node_start.sh"
export CLIO_RUNTIME_STOP="bash /work/11623/hyoklee/vista/bin/clio_2node_stop.sh"
