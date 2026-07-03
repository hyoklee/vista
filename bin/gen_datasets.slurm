#!/bin/bash
#SBATCH -J miv-gendata
#SBATCH -p gg
#SBATCH -N 1
#SBATCH --ntasks-per-node 16
#SBATCH -t 02:00:00
#SBATCH -A IBN22011
#SBATCH -o /scratch/11623/hyoklee/miv/logs/gendata-%j.out
#SBATCH -e /scratch/11623/hyoklee/miv/logs/gendata-%j.err
#SBATCH --mail-type=end,fail
#SBATCH --mail-user=hyoklee@hdfgroup.org
#
# Generate the case-6 Microcircuit_Small datasets (Cells, Connections,
# GapJunctions, h5types, input spikes) from morphologies, following
# MiV-Simulator-Cases/1-construction. Large HDF5 outputs land in
# $SCRATCH/miv/datasets/Microcircuit_Small (task: keep big files on scratch).

set -eo pipefail
source /work/11623/hyoklee/vista/bin/env_miv.sh

CONSTRUCT=$CASES/1-construction
GEN=$MIV_SCRATCH/gen
OUT=$MIV_SCRATCH/datasets/Microcircuit_Small
mkdir -p "$GEN" "$OUT"
cd "$GEN"

# --- stage inputs from the (proven-together) 1-construction case -------------
cp -r "$CONSTRUCT/config" .
cp -r "$CONSTRUCT/templates" .
cp -r "$CONSTRUCT/mechanisms" .
mkdir -p datasets morphology
cp "$CONSTRUCT"/datasets/*.swc morphology/ 2>/dev/null || true
cp /work/11623/hyoklee/vista/bin/assemble_datasets.py datasets/

CFG="--config=Microcircuit_Small.yaml --config-prefix=config"

# NOTE: do NOT run `nrnivmodl mechanisms` here. Modern miv-simulator auto-compiles
# the mechanisms into mechanisms/compiled/<hash>/ and loads that. A manual
# nrnivmodl also creates ./aarch64, which NEURON auto-loads on import, so the
# same mechanism (e.g. Gfluct3) is registered twice ->
# "hoc_execerror: The user defined name already exists: Gfluct3".

echo "===== make-h5types ====="
make-h5types --config-prefix config -c Microcircuit_Small.yaml \
    --output-path datasets/MiV_Small_h5types.h5

echo "===== generate-soma-coordinates ====="
generate-soma-coordinates -v $CFG \
    --types-path=datasets/MiV_Small_h5types.h5 \
    --output-path=datasets/Microcircuit_Small_coords.h5 \
    --output-namespace='Generated Coordinates'

echo "===== measure-distances ====="
mpirun -np 1 measure-distances -v -i PYR -i PVBC -i OLM -i STIM $CFG \
    --coords-path=datasets/Microcircuit_Small_coords.h5

echo "===== neurotrees_import + h5copy H5Types ====="
neurotrees_import PVBC datasets/PVBC_tree.h5 morphology/PVBC.swc
neurotrees_import PYR  datasets/PYR_tree.h5  morphology/PYR.swc
neurotrees_import OLM  datasets/OLM_tree.h5  morphology/OLM.swc
for p in PVBC PYR OLM; do
    h5copy -p -s '/H5Types' -d '/H5Types' \
        -i datasets/MiV_Small_h5types.h5 -o datasets/${p}_tree.h5
done

echo "===== neurotrees_copy --fill (grow forests) ====="
neurotrees_copy --fill --output datasets/PYR_forest_Small.h5  datasets/PYR_tree.h5  PYR 10
neurotrees_copy --fill --output datasets/PVBC_forest_Small.h5 datasets/PVBC_tree.h5 PVBC 90
neurotrees_copy --fill --output datasets/OLM_forest_Small.h5  datasets/OLM_tree.h5  OLM 143

echo "===== distribute-synapse-locs ====="
for p in PYR PVBC OLM; do
    mpirun -np 1 distribute-synapse-locs --template-path templates $CFG \
        --populations $p \
        --forest-path=./datasets/${p}_forest_Small.h5 \
        --output-path=./datasets/${p}_forest_Small.h5 \
        --distribution=poisson --io-size=1 --write-size=0 -v
done

echo "===== generate-distance-connections ====="
for p in PYR PVBC OLM; do
    mpirun -np 4 generate-distance-connections $CFG \
        --forest-path=datasets/${p}_forest_Small.h5 \
        --connectivity-path=datasets/Microcircuit_Small_connections.h5 \
        --connectivity-namespace=Connections \
        --coords-path=datasets/Microcircuit_Small_coords.h5 \
        --coords-namespace='Generated Coordinates' \
        --io-size=1 --cache-size=20 --write-size=100 -v
done

echo "===== input features + spike trains ====="
mpirun -np 1 generate-input-features -p STIM $CFG \
    --coords-path=datasets/Microcircuit_Small_coords.h5 \
    --output-path=datasets/Microcircuit_Small_input_features.h5 -v
mpirun -np 2 generate-input-spike-trains $CFG \
    --selectivity-path=datasets/Microcircuit_Small_input_features.h5 \
    --output-path=datasets/Microcircuit_Small_input_spikes.h5 \
    --n-trials=3 -p STIM -v

echo "===== assemble Cells + Connections ====="
( cd datasets && python assemble_datasets.py )

# --- gap junctions (case-6 specific) -----------------------------------------
echo "===== gap junctions ====="
cp -r "$CASE6/config" case6_config
make-h5types --gap-junctions -c Microcircuit_Small.yaml \
    --config-prefix case6_config --output-path datasets/MiV_h5types_gj.h5
mpirun -np 4 generate-gapjunctions \
    --config=case6_config/Microcircuit_Small.yaml \
    --types-path=datasets/MiV_h5types_gj.h5 \
    --forest-path=datasets/MiV_Cells_Microcircuit_Small_20220410.h5 \
    --connectivity-path=datasets/MiV_gapjunctions_20230408.h5 \
    --connectivity-namespace="Gap Junctions" \
    --coords-path=datasets/MiV_Cells_Microcircuit_Small_20220410.h5 \
    --coords-namespace="Generated Coordinates" \
    --io-size=4 -v

# --- publish final datasets to $SCRATCH/.../Microcircuit_Small ---------------
echo "===== publish to $OUT ====="
cp -v datasets/MiV_Cells_Microcircuit_Small_20220410.h5 \
      datasets/MiV_Connections_Microcircuit_Small_20220410.h5 \
      datasets/MiV_gapjunctions_20230408.h5 \
      datasets/MiV_h5types_gj.h5 \
      datasets/Microcircuit_Small_input_spikes.h5 "$OUT/"
ls -la "$OUT"
echo "===== gen_datasets complete $(date) ====="
