#!/bin/bash
#SBATCH -J miv-case6-vol
#SBATCH -p gg
#SBATCH -N 1
#SBATCH --ntasks-per-node 4
#SBATCH -t 01:00:00
#SBATCH -A IBN22011
#SBATCH -o /scratch/11623/hyoklee/miv/logs/case6vol-%j.out
#SBATCH -e /scratch/11623/hyoklee/miv/logs/case6vol-%j.err
#SBATCH --mail-type=end,fail
#SBATCH --mail-user=hyoklee@hdfgroup.org
#
# Run MiV-Simulator case 6 (gap junctions) on TACC Vista (CPU-only, gg) through
# the clio-core HDF5 VOL connector. Unlike run_case6.slurm's POSIX-interceptor
# path (which neuroh5's MPI-IO reads bypass), the VOL connector intercepts at the
# HDF5 dataset-I/O layer, so it actually sees the simulator's HDF5 traffic.
#
# Modes (VOL env knob):
#   VOL=1  (default)  route HDF5 through the "clio" VOL connector (CTE mirror)
#   VOL=0             native HDF5 baseline (no connector) — same binary/config,
#                     for an apples-to-apples POSIX/native-vs-VOL comparison.
#
# Other knobs:
#   TSTOP   simulated ms (default 50)
#   DT      integration timestep (default 0.01)
#   TRACE   1 = enable CLIO_VOL_TRACE access telemetry (default 0)
#
# Example:
#   sbatch --export=ALL,VOL=1,TSTOP=50 bin/run_case6_vol.slurm
set -eo pipefail
source /work/11623/hyoklee/vista/bin/env_miv.sh

TSTOP=${TSTOP:-50}
DT=${DT:-0.01}
VOL=${VOL:-1}
TRACE=${TRACE:-0}
NRANKS=${SLURM_NTASKS:-4}
NODES=${SLURM_JOB_NUM_NODES:-1}

DATASETS=$MIV_SCRATCH/datasets
RUN=$MIV_SCRATCH/run
RESULTS=$MIV_SCRATCH/results
CSV=$RESULTS/case6_vol_timing.csv
mkdir -p "$RUN" "$RESULTS"

# --- prepare run directory (config, templates, mechanisms) -------------------
cd "$RUN"
cp -ru "$CASE6/config" .
cp -ru "$CASE6/templates" .
cp -ru "$CASE6/mechanisms" .
ln -sfn "$DATASETS" datasets
RESULTS_RUN=results/runs/${SLURM_JOB_ID}
mkdir -p "$RESULTS_RUN"

echo "=== MiV case 6 (VOL) : nodes=$NODES ranks=$NRANKS tstop=$TSTOP dt=$DT VOL=$VOL $(date) ==="
ls -la datasets/Microcircuit_Small/ 2>&1 | head

# --- optional: start clio-core runtime + enable the HDF5 VOL connector --------
MPI_XFLAGS=()
if [ "$VOL" = "1" ]; then
    source /work/11623/hyoklee/vista/bin/clio_vol_env.sh
    if [ ! -e "$CLIO_VOL_LIB" ]; then
        echo "ERROR: VOL=1 but $CLIO_VOL_LIB not found (build clio with -DCLIO_CTE_ENABLE_HDF5_VOL=ON)" >&2
        exit 2
    fi
    if [ "$TRACE" = "1" ]; then
        export CLIO_VOL_TRACE="$RESULTS/voltrace_${SLURM_JOB_ID}"
        mkdir -p "$CLIO_VOL_TRACE"
    fi
    # Start the CTE runtime daemon (single-node shared-memory IPC).
    eval "$CLIO_RUNTIME_START"
    # Force one consistent clio-core ABI across the app (CLIO_PRELOAD) — the VOL
    # .so dlopen()d by HDF5 pulls in the clio client libs, which must be THIS
    # build's, not the conda env's older iowarp-core (fixes #697 build-mixing).
    export LD_PRELOAD="${CLIO_PRELOAD:-}"
    # Forward the HDF5 plugin discovery + clio config to every MPI rank.
    for v in LD_PRELOAD LD_LIBRARY_PATH HDF5_PLUGIN_PATH HDF5_VOL_CONNECTOR \
             PYTHONPATH CLIO_SERVER_CONF CLIO_REPO_PATH CHIMAERA_CONF \
             CLIO_VOL_TRACE CLIO_VOL_CHUNK_SIZE; do
        [ -n "${!v:-}" ] && MPI_XFLAGS+=(-x "$v")
    done
    LABEL=vol
else
    LABEL=native
fi

# --- run + time --------------------------------------------------------------
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

[ -n "${CLIO_RUNTIME_STOP:-}" ] && eval "$CLIO_RUNTIME_STOP" || true

# --- extract phase timings ---------------------------------------------------
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
