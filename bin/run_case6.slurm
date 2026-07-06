#!/bin/bash
#SBATCH -J miv-case6
#SBATCH -p gg
#SBATCH -N 1
#SBATCH --ntasks-per-node 4
#SBATCH -t 01:00:00
#SBATCH -A IBN22011
#SBATCH -o /scratch/11623/hyoklee/miv/logs/case6-%j.out
#SBATCH -e /scratch/11623/hyoklee/miv/logs/case6-%j.err
#SBATCH --mail-type=end,fail
#SBATCH --mail-user=hyoklee@hdfgroup.org
#
# Run MiV-Simulator case 6 (gap junctions) on TACC Vista (CPU-only, gg).
# Compares native parallel HDF5 vs the IOWarp/clio-core CTE POSIX adapter.
#
# Override at submit time with --export, e.g.:
#   sbatch -N 2 --ntasks-per-node=4 --export=ALL,TSTOP=500,IOWARP=0 run_case6.slurm
#
# Env knobs:
#   TSTOP   simulated ms (default 50 for a quick validation run)
#   IOWARP  0 = native HDF5 baseline (default); 1 = LD_PRELOAD clio-core CTE
#   DT      integration timestep (default 0.01)

set -eo pipefail
source /work/11623/hyoklee/vista/bin/env_miv.sh

TSTOP=${TSTOP:-50}
DT=${DT:-0.01}
IOWARP=${IOWARP:-0}
NRANKS=${SLURM_NTASKS:-4}
NODES=${SLURM_JOB_NUM_NODES:-1}

DATASETS=$MIV_SCRATCH/datasets            # contains Microcircuit_Small/*.h5
RUN=$MIV_SCRATCH/run
RESULTS=$MIV_SCRATCH/results
CSV=$RESULTS/case6_timing.csv
mkdir -p "$RUN" "$RESULTS"

# --- prepare run directory (config, templates, compiled mechanisms) ----------
cd "$RUN"
cp -ru "$CASE6/config" .
cp -ru "$CASE6/templates" .
cp -ru "$CASE6/mechanisms" .
# Do NOT run `nrnivmodl mechanisms`: miv-simulator auto-compiles mechanisms into
# mechanisms/compiled/<hash>/; a manual build also creates ./aarch64 which NEURON
# auto-loads, double-registering mechanisms (Gfluct3 "already exists").
ln -sfn "$DATASETS" datasets
# Per-job results dir so a prior run's output HDF5 can't collide with this one
# (mkout aborts with "group already exists" if the results file persists).
RESULTS_RUN=results/runs/${SLURM_JOB_ID}
mkdir -p "$RESULTS_RUN"

echo "=== MiV case 6 : nodes=$NODES ranks=$NRANKS tstop=$TSTOP dt=$DT IOWARP=$IOWARP $(date) ==="
ls -la datasets/Microcircuit_Small/ 2>&1 | head

# --- optional: start clio-core CTE runtime + set LD_PRELOAD ------------------
# For >1 node use the distributed (InfiniBand ib0) 2-node cluster env; for 1
# node use the shared-memory single-node env. Both define CLIO_POSIX_LIB,
# CLIO_RUNTIME_START, CLIO_RUNTIME_STOP.
MPI_XFLAGS=()
PRELOAD=""
if [ "$IOWARP" = "1" ]; then
    if [ "$NODES" -gt 1 ]; then
        CLIO_ENV=/work/11623/hyoklee/vista/bin/clio_env_2node.sh
    else
        CLIO_ENV=/work/11623/hyoklee/vista/bin/clio_env.sh
    fi
    if [ -f "$CLIO_ENV" ]; then
        source "$CLIO_ENV"
        echo "clio env: $CLIO_ENV  POSIX lib: $CLIO_POSIX_LIB"
        [ -n "$CLIO_RUNTIME_START" ] && eval "$CLIO_RUNTIME_START"
        # Preload the interceptor on EVERY rank (incl. remote nodes): export it
        # and forward it (+ lib path + clio config) to remote ranks via mpirun -x.
        export LD_PRELOAD="$CLIO_POSIX_LIB"
        for v in LD_PRELOAD LD_LIBRARY_PATH CLIO_SERVER_CONF CLIO_REPO_PATH \
                 CLIO_HOSTFILE CLIO_IPC_MODE CHIMAERA_CONF; do
            [ -n "${!v}" ] && MPI_XFLAGS+=(-x "$v")
        done
    else
        echo "ERROR: IOWARP=1 but $CLIO_ENV not present" >&2; exit 2
    fi
fi

# --- run + time --------------------------------------------------------------
LABEL=$([ "$IOWARP" = "1" ] && echo iowarp || echo baseline)
LOG=$RESULTS/run_${LABEL}_N${NODES}_r${NRANKS}_t${TSTOP}_${SLURM_JOB_ID}.log

t0=$(date +%s.%N)
mpirun "${MPI_XFLAGS[@]}" -n "$NRANKS" run-network --verbose \
    --config-file=Microcircuit_Small.yaml \
    --config-prefix=config \
    --arena-id=A --stimulus-id=Diag \
    --template-paths=templates \
    --dataset-prefix=datasets \
    --results-path="$RESULTS_RUN" \
    --io-size=1 --dt "$DT" --tstop "$TSTOP" \
    --v-init=-75 --stimulus-onset=0.0 --results-write-time=60 \
    2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
t1=$(date +%s.%N)
total=$(echo "$t1 - $t0" | bc)

[ -n "$CLIO_RUNTIME_STOP" ] && eval "$CLIO_RUNTIME_STOP" || true

# --- extract phase timings from run-network output ---------------------------
created=$(grep -oiE 'created cells[^0-9]*([0-9.]+) s' "$LOG"   | grep -oE '[0-9.]+ s' | tail -1 | grep -oE '[0-9.]+' || true)
connected=$(grep -oiE 'connected cells[^0-9]*([0-9.]+) s' "$LOG" | grep -oE '[0-9.]+ s' | tail -1 | grep -oE '[0-9.]+' || true)
ran=$(grep -oiE 'ran simulation[^0-9]*([0-9.]+) s' "$LOG"        | grep -oE '[0-9.]+ s' | tail -1 | grep -oE '[0-9.]+' || true)

if [ ! -f "$CSV" ]; then
    echo "jobid,label,nodes,ranks,tstop,dt,created_s,connected_s,ran_s,total_s,rc" > "$CSV"
fi
echo "${SLURM_JOB_ID},${LABEL},${NODES},${NRANKS},${TSTOP},${DT},${created},${connected},${ran},${total},${rc}" >> "$CSV"

echo "=== result: label=$LABEL total=${total}s rc=$rc (created=$created connected=$connected ran=$ran) ==="
echo "=== CSV: $CSV ==="; tail -5 "$CSV"
exit $rc
