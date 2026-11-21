#!/bin/bash
# Checks on the complete build tree. Every step logs to $OUT/<step>.log and its exit code to
# $OUT/<step>.rc. Lean runs in the no-network container with the build tree read-only.
# Environment:
#   TREE        the build tree (the hub worker's lean/ directory after the distributed build)
#   WORK        scratch directory for the export and Comparator runs
#   OUT         results directory
#   IMAGE       Apptainer image (container/sandbox.def)
#   TOOLCHAIN   Lean v4.33.1 toolchain;  TOOLCHAIN_436  Lean v4.36.0 toolchain (lake comparator)
#   TOOLS       directory with lean4export/ and lean4lean/, built with Lean v4.33.1
#   REPLAY      clone of rohanarun/alpoge-rh-replay (for its Audit.lean)
#   SOL         clone of Deicyde/riemann-hypothesis (for export-targets.txt)
#   CLEAN       clean clone of the project with Mathlib from `lake exe cache get`
#   CHALLENGE   challenge export (results/inputs/challenge-export.sha256)
#   JUDGE       directory with comparator-A.json, comparator-B.json, comparator-C.json
#   BWRAP       scripts/with-bwrap.sh, or unset where bubblewrap works directly
set -uo pipefail
T=$TREE
mkdir -p "$OUT" "$WORK/tmp" "$WORK/p2"
log() { printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$OUT/checks.log"; }

box() {
  apptainer exec --containall --no-home --userns --net --network none \
    --bind "$TOOLCHAIN:$TOOLCHAIN:ro" --bind "$T:$T:ro" --bind "$WORK/tmp:/tmp" \
    --bind "$WORK/p2:/p2" --bind "$TOOLS:/tools:ro" --bind "$REPLAY:/replay:ro" \
    --bind "$SOL:/sol:ro" --env "PATH=$TOOLCHAIN/bin:/usr/bin:/bin" --pwd "$T" "$IMAGE" "$@"
}
step() {  # step NAME CMD...
  local name=$1; shift
  log "start $name"
  "$@" > "$OUT/$name.log" 2>&1
  local rc=$?
  echo "$rc" > "$OUT/$name.rc"
  log "end $name rc=$rc"
}

step up-to-date box lake build --no-build +Main:olean
step deps-diff bash -c "diff $CLEAN/lake-manifest.json $T/lake-manifest.json; \
  cd $T/.lake/packages && find . -path '*/.lake/build/lib/lean/*.olean' -print0 | sort -z | xargs -0 sha256sum > $OUT/tree-packages.sha256; \
  cd $CLEAN/.lake/packages && find . -path '*/.lake/build/lib/lean/*.olean' -print0 | sort -z | xargs -0 sha256sum > $OUT/clean-packages.sha256; \
  diff $OUT/clean-packages.sha256 $OUT/tree-packages.sha256 && echo PACKAGES-IDENTICAL"

cat > "$WORK/p2/Axioms.lean" <<'LEAN'
import Main
#print axioms riemannHypothesis
#print axioms riemannZeta_eq_zero_re
#print axioms LFunction_ne_zero_of_half_lt_re
#print axioms LFunction_eq_zero_re
#print axioms LFunction_eq_zero_re_of_isPrimitive
LEAN
step axioms-own box lake env lean /p2/Axioms.lean
step axioms-replay box lake env lean /replay/Audit.lean

# Kernel replays and the export run at the same time.
step leanchecker box lake env leanchecker --fresh Main &
# lean4lean checks every module under these prefixes, each against its imports, multithreaded.
# (`lean4lean Main` alone checks only the declarations in Main.) With every root at once and the
# default thread count it peaked above 400 GB; set L4L_ROOTS to fewer roots per run on smaller hosts.
L4L_ROOTS=${L4L_ROOTS:-"Init Std Lean LeanSearchClient Qq Aesop Batteries ImportGraph Plausible ProofWidgets Mathlib
  BuildAid CompanionTheory Development Formalism GroundTheory Lemmata Main PositivityTheory
  ReciprocityTheory Statements Supplements"}
step lean4lean box lake env /tools/lean4lean/.lake/build/bin/lean4lean $L4L_ROOTS &
step export box bash -c 'lake env /tools/lean4export/.lake/build/bin/lean4export Main -- $(cat /sol/export-targets.txt) > /p2/solution.export'
sha256sum "$WORK/p2/solution.export" > "$OUT/solution.export.sha256"

# Comparator (Lean v4.36.0) with its own bubblewrap sandbox. A: Lean kernel + leanchecker-paranoid,
# B: + nanoda. C: con-leche and con-ron, which cannot read this project (reflexive member in a
# mutual block); a failure there means "cannot read", not a rejection.
judge() {  # judge A|B|C
  local d=$WORK/judge-$1; mkdir -p "$d/empty"
  cd "$d/empty" && PATH="$TOOLCHAIN_436/bin:/usr/bin:/bin:/usr/sbin:/sbin" ${BWRAP:-} \
    lake comparator --config "$JUDGE/comparator-$1.json" \
    --challenge-from-export "$CHALLENGE" --solution-from-export "$WORK/p2/solution.export"
}
# Each Comparator run peaks at about 70 GB next to the kernel replays, so the runs start one at a
# time, at least JUDGE_GAP seconds apart and only when JUDGE_MIN_GB of memory is available.
JUDGE_GAP=${JUDGE_GAP:-600}
JUDGE_MIN_GB=${JUDGE_MIN_GB:-200}
first=1
for c in A:comparator-A B:comparator-B C:con-leche-ron; do
  [ "$first" = 1 ] || sleep "$JUDGE_GAP"
  until [ "$(free -g | awk '/^Mem:/ {print $7}')" -ge "$JUDGE_MIN_GB" ]; do sleep 60; done
  step "${c#*:}" judge "${c%%:*}" &
  first=0
done
wait
log "checks done"
