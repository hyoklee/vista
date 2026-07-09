#!/bin/bash
#SBATCH -J clio_ctl685
#SBATCH -p gg
#SBATCH -N 1
#SBATCH --ntasks-per-node 1
#SBATCH -t 00:20:00
#SBATCH -A IBN22011
#SBATCH -o /scratch/11623/hyoklee/miv/logs/ctl685-%j.out
#SBATCH -e /scratch/11623/hyoklee/miv/logs/ctl685-%j.err
#
# validate_controls_685.slurm — single-node CONTROLS for the #685 fix.
#  Phase A (SHM):  positive control. Proves the rebuilt libs + the DirectHash
#                  routing code path round-trip correctly (1 container => hash
#                  resolves local). write+read same process/node.
#  Phase B (TCP):  isolates the cross-node blocker. Same single node, but the
#                  client<->daemon channel forced to ZMQ/TCP. If this SEGVs like
#                  the 2-node run, the crash is in the TCP client transport
#                  (IpcCpu2CpuZmq::SendIn) and is unrelated to multi-node routing
#                  or the #685 chimod change.
set -uo pipefail
TEST_BIN=/work/11623/hyoklee/vista/bin/cte_roundtrip_test
mkdir -p /scratch/11623/hyoklee/miv/logs

echo "############### PHASE A: single-node SHM (positive control) ###############"
(
  unset CLIO_IPC_MODE
  source /work/11623/hyoklee/vista/bin/clio_env.sh
  export CLIO_IPC_MODE=SHM
  eval "$CLIO_RUNTIME_START"
  P="/scratch/11623/hyoklee/miv/ctlA_${SLURM_JOB_ID}.bin"
  echo "[A] run rw same-node under SHM"
  timeout 90 env LD_PRELOAD="$CLIO_POSIX_LIB" "$TEST_BIN" "$P" rw "PHASEA-SHM-${SLURM_JOB_ID}"
  echo "[A] test rc=$?"
  eval "$CLIO_RUNTIME_STOP"
)
echo

echo "############### PHASE B: single-node TCP (isolate blocker) ###############"
(
  source /work/11623/hyoklee/vista/bin/clio_env.sh
  export CLIO_IPC_MODE=TCP
  eval "$CLIO_RUNTIME_START"
  P="/scratch/11623/hyoklee/miv/ctlB_${SLURM_JOB_ID}.bin"
  echo "[B] run rw same-node under TCP"
  timeout 90 env LD_PRELOAD="$CLIO_POSIX_LIB" "$TEST_BIN" "$P" rw "PHASEB-TCP-${SLURM_JOB_ID}"
  echo "[B] test rc=$?"
  eval "$CLIO_RUNTIME_STOP"
)
echo "############### CONTROLS DONE ###############"
