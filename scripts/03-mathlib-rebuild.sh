#!/bin/bash
# Rebuild Mathlib and its dependencies from source, with no network, and compare every compiled
# .olean with the official build cache used by the main build tree.
# Environment:
#   CLEAN       clean clone of the project with Mathlib from `lake exe cache get`
#   SCRATCH     local disk for the copy;  OUT  results directory
#   IMAGE       Apptainer image (container/sandbox.def);  TOOLCHAIN  Lean v4.33.1 toolchain
set -uo pipefail
T=$SCRATCH/clean
mkdir -p "$OUT" "$SCRATCH/tmp"
log() { printf '[%(%F %T)T] %s\n' -1 "$*"; }
rsync -a --exclude '/.lake/packages/*/.lake/build/' --exclude '/.lake/build/' "$CLEAN/" "$T/" || exit 1
log "oleans left after removing build dirs: $(find "$T/.lake/packages" -name '*.olean' | wc -l)"
apptainer exec --containall --no-home --userns --net --network none \
  --bind "$TOOLCHAIN:$TOOLCHAIN:ro" --bind "$T:$T" --bind "$SCRATCH/tmp:/tmp" \
  --env "PATH=$TOOLCHAIN/bin:/usr/bin:/bin,LEAN_NUM_THREADS=$(nproc)" --pwd "$T" "$IMAGE" \
  lake build Mathlib > "$OUT/build.log" 2>&1
log "build rc=$?"
(cd "$T/.lake/packages" && find . -path '*/.lake/build/lib/lean/*.olean' -print0 | sort -z | xargs -0 sha256sum) > "$OUT/rebuilt.sha256"
(cd "$CLEAN/.lake/packages" && find . -path '*/.lake/build/lib/lean/*.olean' -print0 | sort -z | xargs -0 sha256sum) > "$OUT/cache.sha256"
diff "$OUT/cache.sha256" "$OUT/rebuilt.sha256" > "$OUT/diff.txt"
log "oleans: cache $(wc -l < "$OUT/cache.sha256"), rebuilt $(wc -l < "$OUT/rebuilt.sha256"), differing lines $(grep -c '^[<>]' "$OUT/diff.txt")"
