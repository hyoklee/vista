#!/usr/bin/env bash
# clio_fix_rpath.sh — enforce a single, consistent clio-core build at load time.
#
# ROOT CAUSE (issue #714): the clio-core build-tree libraries are linked with
#   DT_RPATH = "<conda-iowarp>/lib : <build>/bin"   (conda FIRST)
# DT_RPATH is searched BEFORE LD_LIBRARY_PATH, so every NEEDED libclio_*.so
# resolves to the OLDER iowarp-core shipped in the conda env, NOT to this build.
# When processes end up mixing the two builds, their Task/PoolQuery wire layout
# differs by a few bytes; a shorter-layout ClientConnect handshake then makes the
# receiving daemon read past the end of the archive during deserialization
# (GlobalDeserialize::read_binary "beyond end of data") -> std::terminate ->
# the daemon Aborts. When that abort coincides with a cross-node CFS GetBlob, the
# read returns 0 bytes — the "cross-node blob data gap" reported in #714. Blob
# routing/storage itself is correct; the gap is a symptom of the daemon crash.
#
# FIX (deployment-side; clio-core source stays pristine): rewrite DT_RPATH on
# every clio ELF object + the clio_run binary + the POSIX interceptor so the
# build bin is searched FIRST and the conda prefix SECOND (conda still supplies
# non-clio deps: zeromq, yaml-cpp, boost, libstdc++ from gcc-15, elfutils...).
# After this, NO stale conda clio lib can ever win, on any node, with or without
# LD_PRELOAD — the mixing is eliminated at its source.
#
# Idempotent: safe to re-run. Requires `patchelf` (present in the miniconda3 base).
set -euo pipefail

BUILD_DIR="${CLIO_BUILD_DIR:-/work/11623/hyoklee/vista/build/clio-core}"
BIN="$BUILD_DIR/bin"
CONDA_LIB="${CLIO_CONDA_ENV:-$HOME/miniconda3/envs/iowarp}/lib"
PATCHELF="$(command -v patchelf || echo "$HOME/miniconda3/bin/patchelf")"

[ -x "$PATCHELF" ] || { echo "ERROR: patchelf not found" >&2; exit 1; }
[ -d "$BIN" ]      || { echo "ERROR: build bin not found: $BIN" >&2; exit 1; }

NEW_RPATH="$BIN:$CONDA_LIB"
echo "clio_fix_rpath: setting DT_RPATH = $NEW_RPATH"
echo "  on all clio ELF objects + clio_run in $BIN"

n=0
# Real ELF files only (skip the .so / .so.1 symlinks — patchelf follows them, but
# patching the concrete .so.1.0.0 / plain .so objects once is enough & clearer).
for f in "$BIN"/libclio_*.so "$BIN"/libclio_*.so.1.0.0 "$BIN"/clio_run; do
    [ -e "$f" ] || continue
    [ -L "$f" ] && continue           # skip symlinks
    # Only touch real ELF files.
    if head -c4 "$f" 2>/dev/null | grep -q $'\x7fELF'; then
        "$PATCHELF" --set-rpath "$NEW_RPATH" "$f"
        n=$((n+1))
    fi
done
echo "clio_fix_rpath: patched $n objects"

# Verify a couple.
echo "clio_fix_rpath: verify libclio_run_cxx.so.1.0.0 -> $("$PATCHELF" --print-rpath "$BIN/libclio_run_cxx.so.1.0.0")"
echo "clio_fix_rpath: verify clio_run              -> $("$PATCHELF" --print-rpath "$BIN/clio_run")"
