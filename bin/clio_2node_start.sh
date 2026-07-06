#!/bin/bash
# clio_2node_start.sh — bring up a 2-node clio-core CTE cluster over ib0.
# Invoked via  eval "$CLIO_RUNTIME_START"  from a run job that has already
# sourced clio_env_2node.sh (env is inherited; we re-source defensively).
set -uo pipefail
[ -n "${CLIO_BIN:-}" ] || source /work/11623/hyoklee/vista/bin/clio_env_2node.sh

NN="${SLURM_NNODES:-2}"
mkdir -p "$(dirname "$CLIO_RUNTIME_LOG")"

echo "[2node-start] allocation nodes: ${SLURM_NODELIST:-?} (NN=$NN)"

# 1) Build the hostfile: each node's ib0 (IPoIB) address, one per line, in a
#    deterministic order (sorted by IP) so every daemon assigns the same
#    node_ids. --overlap lets this step share the nodes with the daemon step.
srun --overlap --ntasks-per-node=1 --nodes="$NN" \
     bash -c 'ip -4 -o addr show ib0 2>/dev/null | awk "{print \$4}" | cut -d/ -f1' \
  | grep -E '^[0-9]+\.' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | uniq > "$CLIO_HOSTFILE"
echo "[2node-start] ib0 hostfile ($CLIO_HOSTFILE):"
cat "$CLIO_HOSTFILE" | sed 's/^/  node -> /'
NHOSTS=$(wc -l < "$CLIO_HOSTFILE")
if [ "$NHOSTS" -lt 2 ]; then
  echo "[2node-start] ERROR: expected >=2 ib0 IPs, got $NHOSTS" >&2
fi

# 2) Launch one daemon per node, bound to that node's ib0 IP (via the hostfile
#    self-identification). Background the whole srun step so the daemons keep
#    running while the app step runs; --overlap so a concurrent app srun can
#    co-schedule on the same nodes. --label prefixes each line with the task id.
srun --overlap --ntasks-per-node=1 --nodes="$NN" --kill-on-bad-exit=0 --label \
     --export=ALL \
     "$CLIO_BIN/clio_run" runtime start > "$CLIO_RUNTIME_LOG" 2>&1 &
echo $! > "$CLIO_PIDFILE"
echo "[2node-start] daemon srun pid=$(cat "$CLIO_PIDFILE"), log=$CLIO_RUNTIME_LOG"

# 3) Wait for the cluster to form (each daemon waits up to wait_for_restart for
#    its peer). Poll the log for the per-node "All N pools created" + peer-up.
for i in $(seq 1 40); do
  ready=$(grep -ac "pools created successfully" "$CLIO_RUNTIME_LOG" 2>/dev/null || echo 0)
  if [ "${ready:-0}" -ge "$NN" ]; then
    echo "[2node-start] $ready/$NN nodes composed pools"
    break
  fi
  sleep 2
done
echo "[2node-start] startup wait done ($(date))"
