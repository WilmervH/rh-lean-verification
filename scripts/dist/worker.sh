#!/bin/bash
# Worker for the distributed independent build (scheduler: scheduler.py).
# Environment:
#   SHARED      directory shared with the scheduler (holds dist/ and the inputs below)
#   WORKER      this worker's name in workers.json;  HUB_HOST  ssh name of the hub worker's host
#   SCRATCH     fast local disk for the build tree;  ARCHIVE   extracted archive (lean/ directory)
#   PACKAGES    a .lake/packages directory from `lake exe cache get` in a clean clone
#   TOOLCHAIN   Lean v4.33.1 toolchain directory;     IMAGE     Apptainer image (container/sandbox.def)
#   THREADS     LEAN_NUM_THREADS (default: nproc)
# Tree: our extraction of the original archive + Mathlib from the clean clone's official cache.
# Fresh build: the hub starts with an empty .lake/build; no earlier build outputs are reused.
# One worker is the hub: its tree aggregates every module; other workers pull the imports a
# batch needs from it and push what they built back. Lake always runs in the no-network container.
set -uo pipefail
D=$SHARED/dist
ME=$WORKER
WD=$D/w/$ME
IMG=$IMAGE
TC=$TOOLCHAIN
IDLE_LIMIT=7200
mkdir -p "$WD"
log() { printf '[%(%F %T)T] %s\n' -1 "$*"; }
W=$SCRATCH
T=$W/lean
B=$T/.lake/build
THREADS=${THREADS:-$(nproc)}
log "$ME: tree $T, LEAN_NUM_THREADS=$THREADS"

rsync -a "$ARCHIVE/" "$T/" || exit 1
mkdir -p "$T/.lake" && rsync -a "$PACKAGES/" "$T/.lake/packages/" || exit 1

lake_box() {
  apptainer exec --containall --no-home --userns --net --network none \
    --bind "$TC:$TC:ro" --bind "$T:$T" --bind "$W/tmp:/tmp" \
    --env "PATH=$TC/bin:/usr/bin:/bin,LEAN_NUM_THREADS=$THREADS" --pwd "$T" "$IMG" lake "$@"
}
mkdir -p "$W/tmp"

if [ "$(jq -r --arg w "$ME" '.[$w].hub' "$WORKERS_JSON")" = true ]; then
  # Fresh build: no reused build files. Every module is compiled in this run from our own
  # extraction of the original archive.
  log "hub: fresh build tree (no seed)"
  mkdir -p "$B"; : > "$D/hub-initial.txt"
  echo "$HUB_HOST:$B" > "$D/hub_path.tmp" && mv "$D/hub_path.tmp" "$D/hub_path"
  HUB=1
else
  HUB=0
  until [ -s "$D/hub_path" ]; do sleep 30; done
  HUBB=$(cut -d: -f2 "$D/hub_path")
  mkdir -p "$B"
fi
log "ready"

idle=0
while [ $idle -lt $IDLE_LIMIT ]; do
  touch "$WD/alive"
  [ -f "$D/ALL_BUILT" ] && break
  next=$(ls "$WD"/batch-*.json 2>/dev/null | grep -v result | sort -t- -k2 -n | while read -r f; do
           [ -f "${f%.json}.result.json" ] || { echo "$f"; break; }; done)
  if [ -z "$next" ]; then sleep 10; idle=$((idle + 10)); continue; fi
  idle=0
  n=$(basename "$next" .json); base=${next%.json}
  t0=$(date +%s.%N)
  if [ $HUB = 0 ] && [ -s "$base.pull.txt" ]; then
    rsync -a --ignore-missing-args --files-from="$base.pull.txt" "$HUB_HOST:$HUBB/" "$B/" \
      || { log "$n pull failed"; sleep 30; continue; }
  fi
  t1=$(date +%s.%N)
  touch "$W/stamp"
  lake_box build $(cat "$base.targets.txt") > "$W/$n.log" 2>&1
  rc=$?
  t2=$(date +%s.%N)
  # built = targets whose trace was written by this run
  python3 -I - "$base.json" "$B" "$W/stamp" "$W/$n.log" > "$W/$n.built" <<'PY'
import json, os, re, sys
batch, build, stamp, logf = sys.argv[1:5]
since = os.path.getmtime(stamp)
mods = json.load(open(batch))["modules"]
built = [m for m in mods if os.path.exists(f"{build}/lib/lean/{m.replace('.', '/')}.trace")
         and os.path.getmtime(f"{build}/lib/lean/{m.replace('.', '/')}.trace") >= since]
log = re.sub(r"\x1b\[[0-9;]*m", "", open(logf, errors="replace").read())
failed = sorted(set(re.findall(r"✖ \[\d+/\d+\] Building (\S+)", log)) & set(mods))
print(json.dumps({"built": built, "failed": failed}))
PY
  for m in $(python3 -I -c "import json,sys; print(' '.join(json.load(open(sys.argv[1]))['built']))" "$W/$n.built"); do
    rm -f "$B/ir/${m//.//}.setup.json"
  done
  if [ $HUB = 0 ]; then
    rsync -a --ignore-missing-args --files-from="$base.push.txt" "$B/" "$HUB_HOST:$HUBB/" \
      || { log "$n push failed; retrying"; sleep 30
           rsync -a --ignore-missing-args --files-from="$base.push.txt" "$B/" "$HUB_HOST:$HUBB/" || { log "$n push failed twice"; continue; }; }
  fi
  t3=$(date +%s.%N)
  [ $rc -eq 0 ] || { log "$n lake exit $rc"; grep -E "error|✖" "$W/$n.log" | head -n 5; cp "$W/$n.log" "$D/fail-$ME-$n.log"; }
  python3 -I - "$W/$n.built" "$next" "$t0" "$t1" "$t2" "$t3" > "$base.result.tmp" <<'PY'
import json, sys
built, batch, t0, t1, t2, t3 = sys.argv[1], sys.argv[2], *map(float, sys.argv[3:7])
r = json.load(open(built))
r["pulled"] = json.load(open(batch)).get("pulled", [])
r.update(secs=t3 - t0, pull_s=t1 - t0, build_s=t2 - t1, push_s=t3 - t2)
print(json.dumps(r))
PY
  mv "$base.result.tmp" "$base.result.json"
  log "$n: $(python3 -I -c "import json,sys; r=json.load(open(sys.argv[1])); print(len(r['built']), 'built', len(r['failed']), 'failed')" "$base.result.json")"
done
log "worker done"
# The hub keeps its allocation (and the full tree) for the verification phase.
if [ $HUB = 1 ]; then log "hub holding tree at $T for phase 2"; sleep infinity; fi
