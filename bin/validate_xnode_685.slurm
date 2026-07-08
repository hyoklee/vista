#!/bin/bash
#SBATCH -J clio_xnode
#SBATCH -p gg
#SBATCH -N 2
#SBATCH --ntasks-per-node 1
#SBATCH -t 00:25:00
#SBATCH -A IBN22011
#SBATCH -o /scratch/11623/hyoklee/miv/logs/xnode685-%j.out
#SBATCH -e /scratch/11623/hyoklee/miv/logs/xnode685-%j.err
#
# validate_xnode_685.slurm — cross-node validation for the CFS tag-namespace fix
# (iowarp/clio-core#685). Brings up a 2-node CTE cluster over ib0, then:
#   1. writes a run-unique payload through the POSIX interceptor on node A
#   2. reads it back on node B (the pre-fix behavior is ENOENT on B)
#   3. same-node sanity: write A / read A on a second path
# PASS = the node-B reader reads back exactly what the node-A writer wrote.
set -uo pipefail

source /work/11623/hyoklee/vista/bin/clio_env_2node.sh

TEST_BIN=/work/11623/hyoklee/vista/bin/cte_roundtrip_test
LOGDIR=/scratch/11623/hyoklee/miv/logs
mkdir -p "$LOGDIR"

# Distinct node names for the writer / reader steps.
mapfile -t HOSTS < <(scontrol show hostnames "$SLURM_NODELIST")
NODE_A="${HOSTS[0]}"
NODE_B="${HOSTS[1]}"
echo "=== nodes: A=$NODE_A  B=$NODE_B  job=$SLURM_JOB_ID $(date) ==="

# Run-unique payloads + paths so a stale tag from a previous run can't mask a
# real ENOENT (pre-fix) or a real hit (post-fix).
XPATH="/scratch/11623/hyoklee/miv/xnode_${SLURM_JOB_ID}.bin"
XPAYLOAD="XNODE-685-${SLURM_JOB_ID}-A2B-payload"
SPATH="/scratch/11623/hyoklee/miv/samenode_${SLURM_JOB_ID}.bin"
SPAYLOAD="SAMENODE-685-${SLURM_JOB_ID}-payload"

# --- bring up the 2-node cluster --------------------------------------------
eval "$CLIO_RUNTIME_START"
# Give the daemons a moment to finish cross-node peer (ROUTER) handshakes over
# ib0 before driving traffic through the interceptor.
sleep 10

# Drive the interceptor. LD_PRELOAD + LD_LIBRARY_PATH are set INSIDE the task
# shell (the --export=ALL,VAR= merge form proved unreliable here: the preload
# was silently dropped, so open("clio::...") fell through to the real FS ->
# ENOENT). --export=ALL still forwards CLIO_SERVER_CONF / CLIO_HOSTFILE /
# CLIO_REPO_PATH / CLIO_IPC_MODE / CHIMAERA_CONF so the interceptor's client can
# reach the local daemon.
run_step() {  # <node> <mode> <path> <payload> <label>
  local node="$1" mode="$2" path="$3" payload="$4" label="$5"
  echo "----- [$label] node=$node mode=$mode path=clio::$path -----"
  # CLIO_PRELOAD (this build's clio libs) MUST precede the interceptor so the
  # whole process uses one consistent clio-core ABI (else the conda-installed
  # iowarp-core is mixed in and the client SIGSEGVs — #697).
  timeout 120 srun --overlap --nodes=1 --ntasks=1 -w "$node" --export=ALL \
    bash -c "export LD_PRELOAD='${CLIO_PRELOAD:-}$CLIO_POSIX_LIB'; \
             export LD_LIBRARY_PATH='$LD_LIBRARY_PATH'; \
             exec '$TEST_BIN' '$path' '$mode' '$payload'"
  local rc=$?
  echo "----- [$label] srun rc=$rc -----"
  return $rc
}

echo "########## TEST 1: cross-node  write@A -> read@B ##########"
run_step "$NODE_A" w "$XPATH" "$XPAYLOAD" "xnode-write-A"
W_RC=$?
run_step "$NODE_B" r "$XPATH" "$XPAYLOAD" "xnode-read-B"
XNODE_RC=$?

echo "########## TEST 2: same-node  write@A -> read@A ##########"
run_step "$NODE_A" w "$SPATH" "$SPAYLOAD" "samenode-write-A"
run_step "$NODE_A" r "$SPATH" "$SPAYLOAD" "samenode-read-A"
SAME_RC=$?

# --- tear down ---------------------------------------------------------------
eval "$CLIO_RUNTIME_STOP"

echo "================= SUMMARY (job $SLURM_JOB_ID) ================="
echo "cross-node write@A rc = $W_RC"
echo "cross-node read@B  rc = $XNODE_RC   (0 = PASS: B read what A wrote)"
echo "same-node  read@A  rc = $SAME_RC    (0 = PASS)"
if [ "$XNODE_RC" -eq 0 ] && [ "$SAME_RC" -eq 0 ]; then
  echo "OVERALL: PASS"
else
  echo "OVERALL: FAIL"
fi
echo "=============================================================="
