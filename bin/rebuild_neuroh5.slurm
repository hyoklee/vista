#!/bin/bash
#SBATCH -J neuroh5_rebuild
#SBATCH -p gg
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -c 32
#SBATCH -t 01:00:00
#SBATCH -A IBN22011
#SBATCH -o /scratch/11623/hyoklee/miv/logs/neuroh5_rebuild_%j.out
#SBATCH -e /scratch/11623/hyoklee/miv/logs/neuroh5_rebuild_%j.err
#
# rebuild_neuroh5.slurm — rebuild + force-reinstall the neuroh5 python binding
# (io.so) from the local work tree into the MiV venv.
#
# WHY: the deployed io.so predates branch fix/vol-h5literate2, which replaces the
# deprecated HDF5 v1 iteration APIs (H5Literate1, H5Gget_objinfo) that HDF5
# forbids on a non-native VOL connector with their VOL-neutral v2 equivalents
# (H5Literate2, H5Lexists). Without this rebuild, MiV case 6 aborts under the
# clio HDF5 VOL connector in neuroh5 read_population_names.
set -euo pipefail
source /work/11623/hyoklee/vista/bin/env_miv.sh

export CMAKE_BUILD_PARALLEL_LEVEL=${SLURM_CPUS_PER_TASK:-16}
echo "=== neuroh5 branch/commit ==="
git -C "$MIV_ROOT/neuroh5" log --oneline -2
echo "=== HDF5 the binding will link: $(h5pcc -showconfig 2>/dev/null | awk -F': *' '/HDF5 Version/{print $2}') ==="

cd "$MIV_ROOT/neuroh5"
# Force a clean rebuild of the extension (drop cached build artifacts so the
# patched TUs actually recompile), then reinstall over the old wheel.
rm -rf build _skbuild dist ./*.egg-info 2>/dev/null || true
uv pip uninstall neuroh5 2>/dev/null || true
uv pip install -v --no-build-isolation --no-deps --force-reinstall . 2>&1 | tail -30

echo "=== verify import + installed path/date ==="
python -c "import neuroh5.io as io; print('neuroh5.io OK ->', io.__file__)"
ls -la "$MIV_VENV"/lib/python*/site-packages/neuroh5/io.so

echo "=== DONE $(date) ==="
