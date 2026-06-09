## ``repro_solver`` — Spec-Implementation M2 ASP-based solver library.
##
## Reprobuild's M2 milestone is full Spack-shaped unification: a single
## clingo-driven concretizer that solves variant selections AND package
## version constraints together in one ASP encoding. M2 is too large for
## a single agent run, so it is sub-divided:
##
## * **M2a (this scaffold)** — clingo Nim bindings, Spack as reference
##   checkout at ``../spack``, smoke test, scaffold for ``Solver`` /
##   ``Solution`` / ``Constraint`` placeholder types. No encoder yet.
## * **M2b** — ASP encoder for variants (variant priorities,
##   ``requires:`` / ``conflicts:`` / ``propagates:``).
## * **M2c** — ASP encoder for package version constraints.
## * **M2d** — integration with ``variant.value`` and the
##   variant-conditioned ``uses:`` arms surfaced in M1.
## * **M2e** — diagnostic / explanation paths ("why X chosen",
##   "unsat reasons").
##
## Studying Spack's ``lib/spack/spack/solver/`` (especially
## ``asp.py``, ``concretize.lp``, ``core.py``, ``heuristic.lp``) at the
## reference checkout is the M2b–M2e starting point. Reprobuild writes
## its OWN ASP encoding — Spack is reference-only, not a runtime
## dependency.
##
## Public surface is intentionally minimal at M2a:
##
## * ``clingo_bindings`` — hand-written subset of the clingo C API
##   dlopen'd via ``{.dynlib.}`` + ``{.cdecl, importc.}``.
## * ``solver_api`` — placeholder ``Solver``, ``Solution``, ``Constraint``
##   types and a stub ``solve`` that returns an empty solution but
##   compiles cleanly. M2b grows these into real types.

import repro_solver/clingo_bindings
import repro_solver/solver_api
import repro_solver/variant_encoder
import repro_solver/version_constraints
import repro_solver/version_encoder

export clingo_bindings
export solver_api
export variant_encoder
export version_constraints
export version_encoder
