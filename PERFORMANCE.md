# MiV-Simulator Case 6 on TACC Vista (ARM) — Performance Summary

End-to-end bring-up and benchmarking of **MiV-Simulator case 6 (gap junctions)**
on the TACC **Vista** supercomputer (NVIDIA Grace, ARM aarch64), comparing the
**IOWarp / clio-core Context Transfer Engine (CTE) POSIX adapter** against
**native parallel HDF5**. CPU-only (`gg` partition, Grace-Grace, 144 cores/node);
no GPUs, per the task.

Date: 2026-07-02 (updated 2026-07-06) · Allocation: `IBN22011` · Driver scripts: `bin/` in this repo.

> **Update 2026-07-06:** clio-core rebuilt from latest `dev` (`f9e7273d`, ~55
> commits newer than the initial build). Builds on Vista/ARM with ELF=ON +
> sysroot glibc-2.34 after reverting a `context-transport-primitives` thread/lock
> (cvrwlock/rwlock) + `unordered_map_ll` refactor that doesn't compile on aarch64
> (branch `vista-arm-build`, commit `f12bbbfd`). Case 6 re-verified 1- and 2-node,
> native + CTE: all rc=0, 2-node cluster forms over ib0, **CTE ≈ native within
> noise — no regression** (1n connected 46.4 vs 46.8 s; 2n connected 27.7 vs 28.0 s).

## Software stack (all built from source, natively on aarch64)

| Component | Version | Notes |
|-----------|---------|-------|
| NEURON | 9.0.1 | aarch64 wheel; mechanisms auto-compiled (`nrnivmodl`) |
| neuroh5 | 0.1.18 | local repo, C++ MPI+HDF5 + python bindings, built with gcc-14 |
| miv-simulator | 0.3.0 | local repo, branch `vista-arm-fix` (4 patches, below) |
| h5py | 3.16.0 | **parallel** (`HDF5_MPI=ON`) against `phdf5/1.14.6` |
| mpi4py | 4.1.2 | against `openmpi/5.0.5` |
| clio-core | `dev` | CTE built with `ELF=ON` → `libclio_cte_posix.so` (aarch64) |

Toolchain: `gcc/14.2.0` + `openmpi/5.0.5` + `phdf5/1.14.6` (parallel HDF5 built
under the same nvidia24/openmpi5 tree). Python venv under
`build/miv/.venv`; large HDF5 I/O under `/scratch/11623/hyoklee/miv`.

## Model (case 6, `Microcircuit_Small` + gap junctions)

- 187 cells: PYR 70, PVBC 53, OLM 44, STIM 10.
- Datasets generated from SWC morphologies via the `1-construction` pipeline
  (not downloaded): Cells 36.5 MB, Connections 8.9 MB (160,528 synaptic edges),
  GapJunctions 52 KB (**107 PYR↔PYR** gap-junction edges), h5types_gj 19 KB,
  STIM input spikes 247 KB. Published to `$SCRATCH/miv/datasets/Microcircuit_Small`.

## Result 1 — clio-core CTE vs native HDF5 (1 node, 4 ranks, tstop=50, 3 reps each)

Phase times are the stable, MiV-reported metric. Means over 3 replicates:

| Phase | Native HDF5 | IOWarp CTE | Δ |
|-------|------------:|-----------:|----:|
| created cells (read 36 MB) | 1.89 s | 2.20 s | +0.31 s |
| connected cells (read 8.9 MB + wire) | 45.17 s | 44.89 s | −0.6% |
| ran simulation (50 ms, pure compute) | 14.72 s | 14.75 s | +0.2% |

**No meaningful difference.** The I/O-inclusive "connected" phase and the
pure-compute "ran" phase are identical within run-to-run noise. The CTE POSIX
interceptor adds only a small fixed cost (~0.3 s) in the create phase (per-`open`
wrapper overhead). The CTE runtime daemon **did start and serve** (3 pools
composed, RAM tier `cte_ram_tier1`, server at 127.0.0.1) during the IOWarp runs.

**Why no I/O win — two independent reasons:**
1. **Compute-bound, read-once workload.** Synapse wiring (connected) + integration
   (ran) dominate; total application I/O is ~45 MB read once, with nothing for a
   RAM tier to accelerate.
2. **The adapter never sees the bulk reads.** This clio-core `dev` CTE POSIX
   adapter only routes paths carrying a literal `clio::` marker; everything else
   passes through to libc. neuroh5 reads the Cells/Connections datasets via
   **MPI-IO parallel HDF5**, which bypasses the intercepted `open`/`read`/`pread`
   path entirely. Transparent acceleration would require an **HDF5 MPI-IO / VFD**
   adapter, not blanket POSIX interception.

This reproduces and extends the recurring finding from the Aurora/ares/jelly
studies in `NeuroFAIR/wiki` (POSIX adapter can't transparently accelerate
neuroh5's MPI-IO; the workload is compute-bound).

## Result 2 — native-HDF5 node scaling (tstop=50, 4 ranks/node)

Vista scales **cleanly 1→2→4 nodes** (contrast: earlier Aurora runs regressed at
4 nodes). Using the dominant parallel "connected cells" phase:

| Nodes (ranks) | connected | speedup | par. eff. | total wall |
|--------------:|----------:|--------:|----------:|-----------:|
| 1 (4)  | 45.17 s | 1.00× | 100% | 69.4 s* |
| 2 (8)  | 27.36 s | 1.65× | 83%  | 47.5 s |
| 4 (16) | 16.11 s | 2.80× | 70%  | 33.1 s |

\* First-ever 1-node run measured 99.5 s total because NEURON mechanisms
(~30 `.mod` files) compile once into the run dir on the cold run; warm reps
settle at ~69 s. Phase times are unaffected (compilation precedes them).

## Result 3 — 2-node distributed CTE cluster over InfiniBand vs native HDF5/MPI

A **2-node clio-core CTE cluster** was formed over Vista's fastest interconnect —
**InfiniBand** (`ib0`, device `mlx5_0`; the only non-loopback interface, IPoIB
`192.168.20.0/21`). The chimaera runtime bootstraps from an `ib0` hostfile
(node_id = line offset); one daemon per node is launched via
`srun --overlap --ntasks-per-node=1`, each binding its ZeroMQ ROUTER to its own
ib0 IP. Verified from the daemon logs during the MiV run (job 810961): node 0 at
`192.168.20.15:9413`, node 1 at `192.168.20.16:9413`, **bidirectional peer
connections over ib0**, `neighborhood=2` on both nodes. MiV ran across both nodes
under `LD_PRELOAD=libclio_cte_posix.so` (forwarded to remote ranks via
`mpirun -x`). Means over 3 replicates each (2 nodes, 8 ranks, tstop=50):

| Phase | Native HDF5 (MPI) | clio-core CTE (IB) | Δ |
|-------|------------------:|-------------------:|----:|
| created cells | 1.77 s | 1.68 s | −4.7% |
| connected cells | 26.45 s | 26.34 s | −0.4% |
| ran simulation | 9.24 s | 9.36 s | +1.3% |

**CTE ≈ native within run-to-run noise**, and — notably — **all 3 clio reps
completed with no deadlock** (rc=0), unlike the multi-node chimaera hangs seen in
the earlier Aurora/ares PBS runs. The distributed CTE runtime over IB neither
helps nor hurts case 6 for the same two reasons as the 1-node result: the
workload is compute-bound, and neuroh5's dataset reads use MPI-IO (bypassing the
POSIX interceptor). The CTE cluster's cross-node **shared-file** path is
additionally a no-op here — this `dev` build's CFS tag namespace is node-local
(`filesystem_runtime.cc` uses `PoolQuery::Local()`), so a `clio::` file written on
one node is not visible on the other; irrelevant for MiV (unprefixed MPI-IO
paths) but noted. Config `bin/chimaera_case6_2node.yaml`; launch
`bin/clio_env_2node.sh` + `clio_2node_{start,stop}.sh`. Jobs 810946/810960/810962
(native), 810947/810961/810963 (CTE).

## Patches (branch `vista-arm-fix` in MiV-Simulator; none needed in clio-core/neuroh5)

1. **`f2e6c7d`** ignore benign FP underflow — `np.seterr(all="raise")` turned
   scipy 1.17 RBF-interpolation matmul underflow (subnormal flush-to-zero) into a
   fatal `FloatingPointError` on aarch64. Keep raising divide/over/invalid.
2. **`620c338`** restore config-based input feature / spike-train generation — a
   prior WIP commit gutted `input_features.py`/`input_spike_trains.py`/`stimulus.py`/
   `env.py` while leaving every consumer on the old signature; restored to their
   last coherent state + a namespace-lookup fix. Produces the STIM
   `Input Spikes A Diag` dataset.
3. **`341fc24`** compile+load mechanisms in `generate-gapjunctions` — it built an
   `Env` but never `compile_and_load(env.mechanisms_path)` (unlike run-network),
   so `insert ch_Navaxonp` in `PoolosPyramidalCell.hoc` hit an undefined mechanism
   and NEURON aborted. Added the load.
4. **`a981da1`** alias `env.dataset_name` to `datasetName` — the restored `env.py`
   uses `datasetName`; `utils/io.py:mkout` reads `dataset_name`.

clio-core `dev` built on aarch64 with **no source patches** — environment-only:
`ELF=ON` (produces the POSIX adapter; upstream defaults OFF), add `elfutils`+`zlib`
to the deps env, and pin `sysroot_linux-aarch64=2.34` (the conda gcc-15 toolchain
otherwise bakes GLIBC_2.38 into binaries that Vista's glibc 2.34 can't load).

## Reproduce

```bash
# 1. build the MiV stack (once)
sbatch bin/build_miv_stack.slurm
# 2. build clio-core CTE (once): login-node prep, then build
bin/clio_prep_deps.sh && sbatch bin/build_clio_core.slurm
# 3. generate + stage datasets (once)
sbatch bin/gen_datasets.slurm
# 4. run case 6 — native baseline and IOWarp CTE, any node count
sbatch -N 1 --ntasks-per-node=4 --export=ALL,TSTOP=50,IOWARP=0 bin/run_case6.slurm
sbatch -N 1 --ntasks-per-node=4 --export=ALL,TSTOP=50,IOWARP=1 bin/run_case6.slurm
```

Raw timings: `/scratch/11623/hyoklee/miv/results/case6_timing.csv`.
Logs: `/scratch/11623/hyoklee/miv/logs/`.
