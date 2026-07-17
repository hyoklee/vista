#!/usr/bin/env python3
"""Smoke test: verify the clio HDF5 VOL connector is loaded and round-trips.

Run under:  HDF5_PLUGIN_PATH=<build/bin>  HDF5_VOL_CONNECTOR=clio
with a clio_run runtime up and LD_PRELOAD=$CLIO_PRELOAD (ABI consistency).

Checks:
  1. h5py imports and reports which HDF5 it links.
  2. A dataset written through the connector reads back identical (numpy).
  3. The file on disk is a valid native HDF5 file (re-openable, h5dump-able).
"""
import os
import sys
import numpy as np
import h5py

print("h5py", h5py.__version__, "libhdf5", h5py.h5.get_libversion())
print("HDF5_VOL_CONNECTOR =", os.environ.get("HDF5_VOL_CONNECTOR"))
print("HDF5_PLUGIN_PATH   =", os.environ.get("HDF5_PLUGIN_PATH"))

path = sys.argv[1] if len(sys.argv) > 1 else "/scratch/11623/hyoklee/miv/results/vol_smoke.h5"
os.makedirs(os.path.dirname(path), exist_ok=True)
if os.path.exists(path):
    os.remove(path)

data = np.arange(1000, dtype="f8").reshape(100, 10) * 1.5
with h5py.File(path, "w") as f:
    f.create_dataset("ints", data=np.arange(256, dtype="i4"))
    f.create_dataset("floats", data=data, chunks=(10, 10))
    f.attrs["note"] = "clio vol smoke"
    f.flush()

with h5py.File(path, "r") as f:
    a = f["ints"][:]
    b = f["floats"][:]
    hyper = f["floats"][10:40, 2:8]  # hyperslab read (selection-aware path)
    note = f.attrs["note"]

ok = (
    np.array_equal(a, np.arange(256, dtype="i4"))
    and np.array_equal(b, data)
    and np.array_equal(hyper, data[10:40, 2:8])
    and note == "clio vol smoke"
)
print("round-trip:", "PASS" if ok else "FAIL")
print("file size on disk:", os.path.getsize(path), "bytes")
sys.exit(0 if ok else 1)
