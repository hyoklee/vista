#!/bin/bash
#SBATCH -J miv-build
#SBATCH -p gg
#SBATCH -N 1
#SBATCH --ntasks-per-node 1
#SBATCH -c 144
#SBATCH -t 03:00:00
#SBATCH -A IBN22011
#SBATCH -o /scratch/11623/hyoklee/miv/logs/miv-build-%j.out
#SBATCH -e /scratch/11623/hyoklee/miv/logs/miv-build-%j.err
#SBATCH --mail-type=end,fail
#SBATCH --mail-user=hyoklee@hdfgroup.org
#
# Build the MiV-Simulator stack (mpi4py, parallel h5py, NEURON, neuroh5,
# miv-simulator) into a uv venv under $MIV_VENV on TACC Vista (ARM aarch64).
# Uses local repos at $MIV_ROOT/{neuroh5,MiV-Simulator} so their sources can be
# patched. Runs on the CPU-only gg partition; Vista compute nodes have internet.
#
# The script is IDEMPOTENT: each stage checks whether its artifact already
# imports/exists and skips if so, so a re-run after a mid-way failure is cheap.

set -eo pipefail
source /work/11623/hyoklee/vista/bin/env_miv.sh

echo "===== MiV stack build $(date) on $(hostname) ($(uname -m)) ====="
echo "CC=$CC CXX=$CXX  mpicc -> $(mpicc -show 2>/dev/null)"
echo "mpicc gcc: $(mpicc --version 2>&1 | head -1)"
echo "HDF5_DIR=$HDF5_DIR"
h5pcc -showconfig 2>/dev/null | grep -iE 'Parallel HDF5|Installation point|HDF5 Version' || true
echo "cores: $(nproc)"

# NB: coreutils `nproc` misreports 1 on Vista Grace nodes (cgroup cpu.max quota),
# even though CPU affinity covers all cores. Use the Slurm allocation instead.
JOBS=${SLURM_CPUS_ON_NODE:-$(nproc --all)}; [ "$JOBS" -gt 48 ] && JOBS=48
export MAKEFLAGS="-j${JOBS}"
export CMAKE_BUILD_PARALLEL_LEVEL=$JOBS

py() { python -c "$1"; }
have() { python -c "$1" >/dev/null 2>&1; }

# --- 1. venv -----------------------------------------------------------------
mkdir -p "$MIV_BUILD/miv"
if [ ! -f "$MIV_VENV/bin/activate" ]; then
    uv venv "$MIV_VENV" --python 3.12
fi
# shellcheck disable=SC1091
source "$MIV_VENV/bin/activate"
# Build-time deps for --no-build-isolation builds (h5py needs pkgconfig+cython).
uv pip install --upgrade pip setuptools wheel "cython<3.1" "numpy<2" pkgconfig hatchling

# --- 2. mpi4py (against openmpi/5.0.5, gcc-14) -------------------------------
echo "===== mpi4py ====="
if have "from mpi4py import MPI"; then
    echo "mpi4py already installed; skip"
else
    uv pip install --no-binary=mpi4py --no-build-isolation mpi4py
fi
py "from mpi4py import MPI; print('mpi4py', MPI.Get_library_version().splitlines()[0])"

# --- 3. parallel h5py (against phdf5/1.14.6, gcc-14) -------------------------
echo "===== h5py (parallel) ====="
if have "import h5py; assert h5py.get_config().mpi"; then
    echo "parallel h5py already installed; skip"
else
    HDF5_MPI=ON CC=mpicc HDF5_DIR="$HDF5_DIR" \
        uv pip install --no-binary=h5py --no-build-isolation h5py
fi
py "import h5py; print('h5py', h5py.__version__, 'mpi=', h5py.get_config().mpi)"

# --- 4. NEURON (aarch64 wheel exists for 9.0.1) ------------------------------
echo "===== NEURON ====="
if have "import neuron"; then
    echo "neuron already installed; skip"
else
    uv pip install "neuron==9.0.1"
fi
py "import neuron; print('NEURON', neuron.__version__)"

# --- 5a. neuroh5 python bindings (local repo) --------------------------------
echo "===== neuroh5 python bindings (local) ====="
export HDF5_ROOT="$HDF5_DIR"
export HDF5_IS_PARALLEL=TRUE
if have "import neuroh5.io"; then
    echo "neuroh5.io already installed; skip"
else
    cd "$MIV_ROOT/neuroh5"
    CC=mpicc CXX=mpicxx HDF5_ROOT="$HDF5_DIR" \
        uv pip install -v --no-build-isolation --no-deps .
fi
py "import neuroh5.io; print('neuroh5.io OK ->', neuroh5.io.__file__)"

# --- 5b. neuroh5 C++ CLI binaries (neurotrees_import, ...) -------------------
# These are the default cmake 'all' target (the python binding is
# EXCLUDE_FROM_ALL), so build them separately and install into the venv bin.
echo "===== neuroh5 CLI binaries (C++) ====="
NH5_BUILD="$MIV_BUILD/miv/neuroh5-cli-build"
if [ ! -x "$NH5_BUILD/bin/neurotrees_import" ]; then
    mkdir -p "$NH5_BUILD"
    cd "$NH5_BUILD"
    cmake "$MIV_ROOT/neuroh5" \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_C_COMPILER=mpicc -DCMAKE_CXX_COMPILER=mpicxx \
        -DHDF5_ROOT="$HDF5_DIR" -DHDF5_IS_PARALLEL=TRUE \
        -DBUILD_PYTHON_BINDINGS=OFF -DBUILD_TESTS=OFF
    cmake --build . --target all -j "$JOBS"
fi
ls -1 "$NH5_BUILD/bin" 2>/dev/null
# Symlink the CLI binaries onto the venv PATH.
for b in "$NH5_BUILD"/bin/*; do
    [ -x "$b" ] && ln -sf "$b" "$MIV_VENV/bin/$(basename "$b")"
done
command -v neurotrees_import && echo "neurotrees_import on PATH OK"

# --- 6. miv-simulator (local repo) -------------------------------------------
echo "===== miv-simulator (local) ====="
if have "import miv_simulator"; then
    echo "miv_simulator already installed; skip deps"
else
    # Pure-Python deps (everything except the already-built native pkgs).
    uv pip install \
        "spike_encoder@git+https://github.com/iraikov/neural_spike_encoding.git" \
        "treverhines-rbf@git+https://github.com/treverhines/RBF" \
        click pyyaml pydantic matplotlib quantities machinable networkx "scipy>=1.13" "numpy<2"
    cd "$MIV_ROOT/MiV-Simulator"
    uv pip install --no-deps --no-build-isolation .
fi

# --- 7. verify all success criteria -----------------------------------------
echo "===== VERIFY success criteria ====="
set +e
py "from mpi4py import MPI"                          && echo "PASS 1 mpi4py"        || echo "FAIL 1 mpi4py"
py "import h5py; assert h5py.get_config().mpi"       && echo "PASS 2 h5py-parallel" || echo "FAIL 2 h5py-parallel"
py "import neuron"                                    && echo "PASS 3 neuron"        || echo "FAIL 3 neuron"
py "import neuroh5.io"                                && echo "PASS 4a neuroh5.io"   || echo "FAIL 4a neuroh5.io"
command -v neurotrees_import >/dev/null              && echo "PASS 4b neurotrees_import" || echo "FAIL 4b neurotrees_import"
for c in run-network make-h5types generate-gapjunctions generate-soma-coordinates distribute-synapse-locs generate-distance-connections; do
    $c --help >/dev/null 2>&1 && echo "PASS 5 $c --help" || echo "FAIL 5 $c --help"
done
echo "===== installed versions ====="
uv pip list 2>/dev/null | grep -iE '^(miv|neuroh5|neuron|h5py|mpi4py|numpy|scipy) ' || \
    python -c "import neuron,h5py,mpi4py,numpy; print('neuron',neuron.__version__,'h5py',h5py.__version__,'mpi4py',mpi4py.__version__,'numpy',numpy.__version__)"
echo "===== build complete $(date) ====="
