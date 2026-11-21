# Independent verification of the Lean RH formalization

An independent check of the Lean 4 formalization that claims a proof of the Riemann Hypothesis and
of GRH for Dirichlet L-functions, announced by Levent Alpöge on 2026-11-20 at
<https://alpo.ge/remark.pdf>. Credit for the claimed proof belongs to its author. This repository
contains only our scripts and results, not the submission.

**Status: in progress.** The inputs are checked (below). The full build is running. No verdict yet.

"Independent" here means: we download the original archive ourselves, build all 175,187 modules
from it in one fresh run, and check the result with our own runs of the kernel and of independent
checkers. No build output made by anyone else is used, apart from Mathlib's official build cache,
which we also rebuild from source and compare.

## What is checked

| # | Check | Status |
|---|---|---|
| 1 | Archive: the 14 parts from alpo.ge, joined SHA-256 against the published value | **done, matches** |
| 2 | Sources: every module's SHA-256 against the replay index; archive vs the Deicyde mirror | **done, 175,187/175,187 match; mirror differs only by its own additions** |
| 3 | Toolchains: installed Lean v4.33.1 and v4.36.0, file by file against the official release archives | **done, identical** |
| 4 | Mathlib pin is the official `v4.33.1` tag | **done** |
| 5 | Static scan of the source | **done**, see [docs/static-scan.md](docs/static-scan.md) |
| 6 | Challenge export (the five statements, Mathlib only) rebuilt locally and compared with Deicyde's CI artifact | **done, byte-identical** |
| 7 | Fresh, sandboxed build of all 175,187 modules with Lean v4.33.1 (`+Module:olean`), no network | running |
| 8 | Compiled Mathlib in the build tree unchanged; Mathlib rebuilt from source and compared with the official cache | pending |
| 9 | Axiom audit of the five theorems: only `propext`, `Quot.sound`, `Classical.choice` | pending |
| 10 | Fresh kernel replay: `leanchecker --fresh Main` (Lean v4.33.1) | pending |
| 11 | Export with lean4export, judged by `lake comparator` (Lean v4.36.0): Lean kernel, `leanchecker-paranoid`, nanoda, con-leche, con-ron, with Comparator's own sandbox | pending |
| 12 | lean4lean replay of the compiled files | pending |

Results land in [results/](results/) as they are produced.

## The theorems

`Main.lean` states `riemannHypothesis` (Mathlib's `RiemannHypothesis`), `riemannZeta_eq_zero_re`,
`LFunction_ne_zero_of_half_lt_re`, `LFunction_eq_zero_re` and `LFunction_eq_zero_re_of_isPrimitive`.
The statements are compared with a challenge file that imports only Mathlib, so a proof of a
different statement, an extra axiom, or a `sorry` is rejected.

## Method

**Inputs** ([scripts/00-check-inputs.sh](scripts/00-check-inputs.sh)). Results in
[results/inputs/](results/inputs/).

**Build.** One build tree from our extraction of the archive, plus Mathlib from its official cache.
Every Lake invocation runs in an Apptainer container ([container/sandbox.def](container/sandbox.def))
with no network and the toolchain read-only, because compiling the submission runs its code.

The build is distributed over several machines without letting Lake rebuild anything twice
([scripts/dist/](scripts/dist/)). A scheduler holds the import graph and hands each worker
batches of modules whose imports are all already built, tallest dependency chains first. A worker
pulls the compiled imports it lacks from a hub worker, builds the batch, and pushes the results
back. The hub's tree ends up holding the complete build, and every later check runs on that tree.
The import graph is wide: about 160,000 modules sit at import depth below 100 with small import
closures, and only 355 sit above depth 150, so most of the work parallelizes well.

**Judging.** As in [Deicyde/riemann-hypothesis](https://github.com/Deicyde/riemann-hypothesis),
the solution is exported inside the sandbox and judged by Lean v4.36.0's `lake comparator`
against the challenge export, with the four external checkers split into two Comparator runs so
they can run at the same time. Comparator needs unprivileged bubblewrap. On machines whose root
filesystem is an initramfs `rootfs`, bubblewrap cannot `pivot_root`;
[scripts/with-bwrap.sh](scripts/with-bwrap.sh) moves a bind mount of `/` over the root in a private
mount namespace first (the `switch_root` trick, unprivileged), so Comparator can keep its sandbox.

## What a pass would and would not show

A pass shows that the five statements, as written, are accepted by several independent kernels
from exports of this build, using only the three standard axioms. It still trusts the checkers,
Mathlib's definitions, the exporter and the sandboxes. Comparator compares challenge and solution
against the same Mathlib, so a modified Mathlib would not be detected by Comparator itself; check 8
covers that. Lean v4.33.1 lacks some later kernel fixes, which is why the build's own kernel pass
is not counted as the verdict.

## Related work

- [Deicyde/riemann-hypothesis](https://github.com/Deicyde/riemann-hypothesis): mirror of the
  archive and a Comparator setup. We reuse its challenge file and Comparator config, and compare
  our results with theirs.
- [rohanarun/alpoge-rh-replay](https://github.com/rohanarun/alpoge-rh-replay): a distributed
  replay by many volunteers, module by module.

## License

The scripts in this repository are MIT licensed (see [LICENSE](LICENSE)). The submission belongs to
its author and was published without a license; it is not included here.
