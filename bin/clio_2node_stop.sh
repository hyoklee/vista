#!/bin/bash
# clio_2node_stop.sh — tear down the 2-node clio-core CTE cluster + clean shm.
# Invoked via  eval "$CLIO_RUNTIME_STOP".
set -uo pipefail
[ -n "${CLIO_BIN:-}" ] || source /work/11623/hyoklee/vista/bin/clio_env_2node.sh
NN="${SLURM_NNODES:-2}"

echo "[2node-stop] stopping cluster on all $NN nodes"
# Ask each node's runtime to stop cleanly, then hard-kill stragglers and wipe
# per-user shared-memory segments / memfd symlinks on every node.
srun --overlap --ntasks-per-node=1 --nodes="$NN" \
     bash -c "\"$CLIO_BIN/clio_run\" stop >/dev/null 2>&1 || true; \
              pkill -9 -f 'clio_run runtime start' 2>/dev/null; \
              rm -rf /tmp/clio_\${USER}/* /tmp/clio/* /dev/shm/clio_* 2>/dev/null; true" \
     2>/dev/null || true

# Kill the backgrounded daemon srun step launched by clio_2node_start.sh.
if [ -f "$CLIO_PIDFILE" ]; then
  kill "$(cat "$CLIO_PIDFILE")" 2>/dev/null || true
  rm -f "$CLIO_PIDFILE"
fi
echo "[2node-stop] done ($(date))"
