#!/usr/bin/env python3
"""Assemble the canonical Microcircuit_Small Cells + Connections HDF5 files.

Mirrors the final assembly cells of MiV-Simulator-Cases/1-construction/
constructing_a_network_model.ipynb. Run from the datasets directory (all
intermediate files must already exist there):

    cd $SCRATCH/miv/datasets/Microcircuit_Small && \
        python assemble_datasets.py

Produces:
  MiV_Cells_Microcircuit_Small_20220410.h5
  MiV_Connections_Microcircuit_Small_20220410.h5
"""
import os
import pathlib
import h5py

h5types_file = "MiV_Small_h5types.h5"
MiV_cells_file = "MiV_Cells_Microcircuit_Small_20220410.h5"
MiV_connections_file = "MiV_Connections_Microcircuit_Small_20220410.h5"
MiV_coordinate_file = "Microcircuit_Small_coords.h5"

MiV_populations = ["PYR", "OLM", "PVBC", "STIM"]
MiV_EXT_populations = ["STIM"]

input_coordinate_ns = "Generated Coordinates"
coordinate_namespaces = {p: input_coordinate_ns for p in MiV_populations}
coordinate_files = {p: MiV_coordinate_file for p in MiV_populations}

forest_files = {
    "PYR": "PYR_forest_Small.h5",
    "PVBC": "PVBC_forest_Small.h5",
    "OLM": "OLM_forest_Small.h5",
}
forest_syns_files = dict(forest_files)
connectivity_files = {
    "PYR": "Microcircuit_Small_connections.h5",
    "PVBC": "Microcircuit_Small_connections.h5",
    "OLM": "Microcircuit_Small_connections.h5",
}
vecstim_dict = {"Input Spikes A Diag": "Microcircuit_Small_input_spikes.h5"}


def h5_copy_dataset(f_src, f_dst, dset_path):
    print(f"  copy {dset_path}  {f_src.filename} -> {f_dst.filename}")
    target_path = str(pathlib.Path(dset_path).parent)
    f_src.copy(f_src[dset_path], f_dst[target_path])


def sh(cmd):
    print(cmd)
    rc = os.system(cmd)
    if rc != 0:
        raise SystemExit(f"command failed (rc={rc}): {cmd}")


# ---- Cells file -------------------------------------------------------------
print("== building", MiV_cells_file)
with h5py.File(MiV_cells_file, "w") as f:
    with h5py.File(h5types_file, "r") as inp:
        h5_copy_dataset(inp, f, "/H5Types")

with h5py.File(MiV_cells_file, "a") as f_dst:
    grp = f_dst.create_group("Populations")
    for p in MiV_populations:
        grp.create_group(p)
    for p in MiV_populations:
        coords_ns = coordinate_namespaces[p]
        with h5py.File(coordinate_files[p], "r") as f_src:
            h5_copy_dataset(f_src, f_dst, f"/Populations/{p}/{coords_ns}")
            h5_copy_dataset(f_src, f_dst, f"/Populations/{p}/Arc Distances")

for p in MiV_populations:
    if p in forest_files:
        fp = f"/Populations/{p}/Trees"
        sp = f"/Populations/{p}/Synapse Attributes"
        sh(f"h5copy -p -s '{fp}' -d '{fp}' -i {forest_files[p]} -o {MiV_cells_file}")
        sh(f"h5copy -p -s '{sp}' -d '{sp}' -i {forest_syns_files[p]} -o {MiV_cells_file}")

for vecstim_ns, vecstim_file in vecstim_dict.items():
    for p in MiV_EXT_populations:
        vp = f"/Populations/{p}/{vecstim_ns}"
        sh(f"h5copy -p -s '{vp}' -d '{vp}' -i {vecstim_file} -o {MiV_cells_file}")

p = "STIM"
sh(f"h5copy -p -s '/Populations/{p}/Generated Coordinates' "
   f"-d '/Populations/{p}/Coordinates' -i {MiV_cells_file} -o {MiV_cells_file}")

# ---- Connections file -------------------------------------------------------
print("== building", MiV_connections_file)
with h5py.File(MiV_connections_file, "w") as f:
    with h5py.File(h5types_file, "r") as inp:
        h5_copy_dataset(inp, f, "/H5Types")

for p in MiV_populations:
    if p in connectivity_files:
        pp = f"/Projections/{p}"
        sh(f"h5copy -p -s {pp} -d {pp} -i {connectivity_files[p]} -o {MiV_connections_file}")

print("== done")
