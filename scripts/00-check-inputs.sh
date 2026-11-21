#!/bin/bash
# Phase 0: inputs. Needs network.
# Downloads the original archive, verifies it, extracts it, compares it with a mirror checkout,
# checks every module's source digest against the replay index, runs a static scan, checks the
# Mathlib pin against the official tags.
# Environment: WORK (output dir), MIRROR (clean clone of Deicyde/riemann-hypothesis after
# `lake exe cache get`), REPLAY (clone of rohanarun/alpoge-rh-replay, for parts.sha256 and the index)
set -uo pipefail
O=$WORK/phase0
mkdir -p "$O/parts" "$WORK/archive"
log() { printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$O/phase0.log"; }

log "download 14 parts from alpo.ge"
for i in $(seq -w 1 14); do
  [ -s "$O/parts/lean.tar.gz.part$i" ] || curl -sSfL --retry 4 -o "$O/parts/lean.tar.gz.part$i" "https://alpo.ge/lean.tar.gz.part$i"
done
(cd "$O/parts" && sha256sum lean.tar.gz.part* > ../parts.sha256)
cat "$O"/parts/lean.tar.gz.part{01..14} > "$O/lean.tar.gz"
log "joined: $(stat -c %s "$O/lean.tar.gz") bytes $(sha256sum "$O/lean.tar.gz" | cut -d' ' -f1)"
echo "9631b4f020199e580ba86178cb56c6e9b09f690c2369a80dc4334aa93f49c7fc  $O/lean.tar.gz" | sha256sum -c | tee -a "$O/phase0.log"
log "compare part hashes with the replay repo's parts.sha256"
diff <(awk '{print $1}' "$REPLAY/parts.sha256" | sort) <(awk '{print $1}' "$O/parts.sha256" | sort) \
  && log "part hashes match replay repo" || log "WARNING: part hashes differ from replay repo"

log "extract"
tar -xzf "$O/lean.tar.gz" --no-same-owner -C "$WORK/archive"
log "byte-compare archive lean/ with the mirror at $(git -C "$MIRROR" rev-parse --short HEAD) (first commit = archive)"
git -C "$MIRROR" log --reverse --format=%H | head -n 1 > "$O/mirror-first-commit"
diff -rq --exclude=.git --exclude=.lake --exclude=.github \
  "$WORK/archive/lean" "$MIRROR" > "$O/archive-vs-mirror.diff" 2>&1
log "archive vs mirror: $(wc -l < "$O/archive-vs-mirror.diff") differing paths (expected: only the mirror's additions)"
log "per-module source digests vs the replay index"
python3 -I - "$WORK/archive/lean" "$REPLAY/tracker/modules.jsonl.gz" > "$O/source-digests.txt" <<'PY'
import gzip, hashlib, json, sys
root, index = sys.argv[1], sys.argv[2]
bad = n = 0
for line in gzip.open(index):
    r = json.loads(line)
    path = f"{root}/src/{r['module'].replace('.', '/')}.lean"
    h = hashlib.sha256(open(path, 'rb').read()).hexdigest()
    n += 1
    if h != r["source_sha256"]:
        bad += 1
        print("MISMATCH", r["module"])
print(f"{n} modules checked, {bad} mismatches")
PY
tail -n 1 "$O/source-digests.txt" | tee -a "$O/phase0.log"

log "static scan"
S=$WORK/archive/lean/src
for pat in '\baxiom\b' '\bsorry\b' '\badmit\b' 'native_decide' 'implemented_by' '@\[extern' '\bunsafe\b' '\bopaque\b' 'set_option debug' 'skipKernelTC' 'set_option[^\n]*kernel' 'decide +kernel' 'ofReduceBool' 'Lean.ofReduceBool' 'addDecl' 'elab_rules|macro_rules|\belab\b|\bmacro\b' 'initialize|builtin_initialize' 'IO\.' 'run_cmd|#eval'; do
  c=$(grep -rlE "$pat" "$S" 2>/dev/null | wc -l)
  printf '%-45s %s files\n' "$pat" "$c"
done | tee "$O/static-scan.txt" | tee -a "$O/phase0.log"
for pat in 'addDecl' 'elab_rules|macro_rules|\belab\b|\bmacro\b' 'initialize|builtin_initialize' 'run_cmd|#eval' 'IO\.'; do
  echo "## $pat"; grep -rlE "$pat" "$S" 2>/dev/null | sed "s#^$S/##" | head -n 20
done > "$O/static-scan-files.txt"

log "Mathlib pin: compare with official tags"
M=$MIRROR/.lake/packages/mathlib
git -C "$M" fetch -q --tags origin 2>/dev/null
{ echo "pin: $(git -C "$M" rev-parse HEAD)"
  echo "tag v4.33.1: $(git -C "$M" rev-parse 'v4.33.1^{commit}' 2>&1)"
  echo "tag v4.33.0: $(git -C "$M" rev-parse 'v4.33.0^{commit}' 2>&1)"
  echo "diff v4.33.0..pin:"; git -C "$M" diff --stat 'v4.33.0^{commit}' HEAD 2>&1 | tail -n 3
  git -C "$M" fetch -q origin master 2>/dev/null; git -C "$M" merge-base --is-ancestor 'v4.33.0^{commit}' FETCH_HEAD && echo "v4.33.0 is on master"
} | tee "$O/mathlib-pin.txt" | tee -a "$O/phase0.log"

log "PHASE0 DONE"
