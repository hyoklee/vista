# MiV case 6 on Vista — clio-core HDF5 **VOL** connector vs native HDF5 vs POSIX

End-to-end `run-network` benchmark of **case 6 (gap junctions)** on TACC **Vista**
(NVIDIA Grace, ARM aarch64, CPU-only `gg` partition, allocation `IBN22011`),
comparing three HDF5 I/O paths on the **same** clio-core `dev` build
(`b5c68c5e`):

1. **native** parallel HDF5 (`phdf5/1.14.6`) — baseline
2. **POSIX** — clio-core CTE POSIX interceptor (`libclio_cte_posix.so`, `LD_PRELOAD`)
3. **VOL** — clio-core **HDF5 VOL connector** (`libclio_hdf5_vol.so`,
   `HDF5_VOL_CONNECTOR=clio`) — the configuration `NeuroFAIR.md` asks for

All scripts are in `vista/bin/`: build `build_clio_vol.slurm`; run
`run_case6_vol.slurm` (VOL / native) and `run_case6.slurm` (POSIX); env
`clio_vol_env.sh` / `clio_env.sh`; VOL smoke `vol_smoke.{py,sh}`;
neuroh5 rebuild `rebuild_neuroh5.slurm`; h5py VOL shim `sitecustomize.py`.

## Headline

The clio **VOL** connector runs case 6 **end-to-end on Vista/ARM, including
writing the results file**, and its output is **bit-for-bit identical to native**
(`h5diff` = 0 differences, 167 881 bytes). Native, POSIX, and VOL perform **the
same within run-to-run noise** — case 6 is compute-bound and read-once, so a
caching tier has nothing to win back, as on every prior platform. Unlike POSIX
(which only routes paths carrying a literal `clio::` marker, so neuroh5's MPI-IO
reads bypass it), the **VOL intercepts neuroh5's HDF5 dataset I/O directly** and
mirrors whole-dataset atomic transfers to the CTE RAM tier — transparent and
correct, just not faster here.

This is a step past the Frontera VOL study
(`NeuroFAIR/wiki/miv_frontera_case6_vol.md`), which listed the results-file
write-open **and** multi-rank collective reads as *unresolved*: on Vista both
work (see fixes below).

## 1 node, 4 ranks, tstop=50 (mean; current dev build)

| Phase | native (3 reps) | POSIX (2) | VOL (3) |
|-------|----------------:|----------:|--------:|
| created cells (read ~36 MB) | 2.01 s | 2.13 s | 1.95 s |
| connected cells (read + wire) | 45.66 s | 46.38 s | 46.02 s |
| ran simulation (50 ms, pure compute) | 14.78 s | 14.99 s* | 14.99 s |
| **total wall** | **70.10 s** | **71.21 s** | **70.88 s** |

Δ vs native on the read-heavy *connected* phase: **POSIX +1.57 %, VOL +0.79 %**;
total **POSIX +1.59 %, VOL +1.11 %** — all inside the ~1–2 % run-to-run noise.
(\*POSIX *ran* mean 14.62 s; the difference is noise, the sim is identical.)

Jobs: native 837944/838383/838385, VOL 838332/838384/838386, POSIX 838390/838391.

## Multi-rank collective reads through the VOL

| config | connected | ran | total | rc |
|--------|----------:|----:|------:|---:|
| VOL, 1 node × 4 ranks | 46.02 s (mean) | 14.99 s | 70.88 s | 0 |
| VOL, 1 node × 8 ranks | 27.20 s | 9.66 s | 46.88 s | 0 |

neuroh5's projection reads are MPI-collective (all ranks participate). At both 4
and 8 ranks the VOL arm completes cleanly (`io-size=1`, OpenMPI 5.0.5) — the
NR=8 collective-read deadlock reported on Frontera (MPICH container) does **not**
reproduce on Vista. Job 838399 (8 ranks).

## Two VOL-incompatibilities in the MiV stack — found, fixed, neither a connector bug

HDF5 enforces both restrictions **above** the connector (in its public-API / VOL
dispatch layer), so the clio connector cannot fix them and stays pristine.

### 1. neuroh5 used deprecated version-1 HDF5 iteration APIs

HDF5 forbids the *version-1* link/group iteration APIs (`H5Literate1`,
`H5Literate_by_name1`, `H5Gget_objinfo`) on any **non-native** VOL connector —
the block happens before the connector is invoked. Proven with a C probe against
the actual Cells file: through the connector `H5Literate2`, `H5Gget_info`, and
`H5Gget_num_objs` all return rc=0 and iterate correctly, but `H5Literate1` /
`H5Literate_by_name1` return rc=−1. The deployed `neuroh5/io.so` predated the
fix and aborted in `read_population_names`.

**Fix** — neuroh5 branch `fix/vol-h5literate2` (rebuilt + reinstalled via
`bin/rebuild_neuroh5.slurm`): `H5Literate`→`H5Literate2` (commit 28b6d83) and
`H5Gget_objinfo`→VOL-neutral `H5Lexists` (commit b62051b, this session).
`H5Gget_num_objs` works through the VOL and was left unchanged.

### 2. h5py `File(path, "a")` create-fallback skipped through the VOL

`h5py.File(path, "a")` opens read-write and, on failure, creates the file — but
only when the failure surfaces as `FileNotFoundError`, which h5py derives from
the top HDF5 error frame. Through a non-native VOL, HDF5's H5VL layer wraps the
underlying `errno=2` as a generic *"Virtual Object Layer / Can't open object"*
error, so h5py raises plain `OSError`, skips the create-fallback, and
`File(path, "a")` fails on a not-yet-existing file — breaking MiV's `mkout`
(results file) and ~10 other `h5py.File(..., "a")` sites.

**Fix** — `bin/sitecustomize.py`, a VOL-compatibility shim auto-imported at
interpreter startup (via `PYTHONPATH=vista/bin`, added by `clio_vol_env.sh` and
forwarded to MPI ranks). When mode is `"a"` and the file is absent it creates
with `"x"` (a lost create race falls back to append). It is a **no-op unless
`HDF5_VOL_CONNECTOR` is set**, so native/POSIX runs are completely unaffected.

## Correctness

`h5diff` native-vs-VOL results file → **0 differences**; identical byte size;
`h5ls`/`h5dump` (connector off) read the VOL-written file as a valid, standard
native HDF5 file (H5Types, LFP electrodes, per-population spike + intracellular
datasets). The native file is always authoritative; CTE mirroring is additive.

## Conclusion

- Case 6 **builds and runs end-to-end on Vista/ARM through the clio HDF5 VOL
  connector**, writing correct, bit-identical output.
- native ≈ POSIX ≈ VOL within noise — compute-bound, read-once workload; no I/O
  speedup expected or seen, consistent with all prior MiV studies.
- The VOL is the more meaningful adapter for MiV (it actually sees neuroh5's
  HDF5 reads, unlike the `clio::`-only POSIX interceptor), and is now a working
  read+write path at 4 and 8 ranks on Vista.

Raw timings: `/scratch/11623/hyoklee/miv/results/case6_vol_timing.csv`
(native/VOL) and `case6_timing.csv` (POSIX). clio-core stays pristine dev
`b5c68c5e`; fixes live in neuroh5 (`fix/vol-h5literate2`) and a MiV-side
`sitecustomize.py` shim.
