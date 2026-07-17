#!/bin/bash
# vol_smoke.sh — end-to-end smoke test of the clio HDF5 VOL connector with h5py.
# Starts the CTE runtime, runs vol_smoke.py through the "clio" connector, stops
# the runtime. Usable on a login node (quick) or inside a slurm job.
#
#   bash /work/11623/hyoklee/vista/bin/vol_smoke.sh [out.h5]
set -uo pipefail
HERE=/work/11623/hyoklee/vista/bin
source "$HERE/env_miv.sh"          # venv (h5py) + phdf5/1.14.6 module
source "$HERE/clio_vol_env.sh"     # runtime machinery + HDF5_PLUGIN_PATH/VOL_CONNECTOR

OUT=${1:-/scratch/11623/hyoklee/miv/results/vol_smoke.h5}
export CLIO_RUNTIME_LOG=${CLIO_RUNTIME_LOG:-/scratch/11623/hyoklee/miv/logs/clio_runtime_smoke.log}
export CLIO_PIDFILE=${CLIO_PIDFILE:-/scratch/11623/hyoklee/miv/logs/clio_runtime_smoke.pid}

echo "=== starting CTE runtime ==="
eval "$CLIO_RUNTIME_START"
echo "runtime log tail:"; tail -5 "$CLIO_RUNTIME_LOG" 2>/dev/null

echo "=== running vol_smoke.py under the clio VOL connector ==="
LD_PRELOAD="${CLIO_PRELOAD:-}" python "$HERE/vol_smoke.py" "$OUT"
rc=$?

echo "=== stopping CTE runtime ==="
eval "$CLIO_RUNTIME_STOP" || true

echo "=== validate native file with h5dump (independent of connector) ==="
# Unset the connector so h5dump reads the file with the native VOL only — proves
# the on-disk file is a valid, standard HDF5 file.
env -u HDF5_VOL_CONNECTOR -u HDF5_PLUGIN_PATH h5dump -H -A "$OUT" 2>&1 | head -25

echo "=== smoke rc=$rc ==="
exit $rc
