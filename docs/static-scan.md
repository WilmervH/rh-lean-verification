# Static scan

A text search over all 175,187 source files of the archive. It finds what the build could run or
what could weaken the check. A text search is not a proof; the axiom audit and the kernel replays
are.

## Not present

No `axiom`, `sorry`, `admit`, `native_decide`, `implemented_by`, `@[extern]`, `unsafe`, `opaque`,
`set_option debug.*`, `skipKernelTC`, `ofReduceBool`, `decide +kernel`, `initialize` or
`builtin_initialize`. The 24 files that mention `IO.` use a namespace named `IO` from the project
(for example `IO.sqrt_d_pos`), not Lean's `IO` monad.

## Code that runs at build time

| What | Where | Effect |
|---|---|---|
| `run_cmd` adding one name to the library-suggestion deny list | `BuildAid/D1.lean` … `D5.lean` | Changes tactic suggestions only |
| `elab "cpt_copy_thms"`, calling `addDecl` | `Formalism/HermitianCurvature/HermitianCurvatureProofs/CutCptCopy.lean` | Copies declarations under new names; the kernel checks every copy |
| `elab "kexactB"` | `Formalism/LocalToGlobal/IndefiniteReal/HeckeNonvanishing/Imports.lean` | Like `exact`, but assigns the elaborated term to the goal without the elaborator's definitional-equality check |
| `elab "kcopy"`, `elab "#kcopy_probe"` | `Formalism/LocalToGlobal/NumberFieldFamilies/OwnStruct.lean` | Builds a term of the goal's type by copying structures field by field; the probe only logs |
| 22 tactic `macro`s | 19 files | Abbreviations that expand to standard tactics |

`kexactB` and `kcopy` appear on about 238 lines. They are not mentioned in Deicyde's notes, which
list the first two rows. Neither can make an invalid proof pass: both only produce proof terms,
and the kernel type-checks every declaration that contains them, as do the independent checkers.
They do mean that in those places the elaborator's own checks are skipped and only the kernel
stands between a wrong term and acceptance, which is one reason the kernel replays matter here.

## Tactic macros

`fin_index_simp`, `lbt`, `jet_tac`, `fin_order`, `fin_order'`, `meq`, `zz`, `evs` (two
definitions), `ztac`, `fin_tac`, `change_aux_intm`, `distrib_module`, `pos_tac`, `onele_tac`,
`integ`, `nbt`, `lvo`, `fIwasawa_omega`, `exists_prescribed_local_data`, `secTac`, `ones`. Each
expands to a combination of `simp`, `omega`, `rw`, `first`, `repeat` and similar standard tactics.
