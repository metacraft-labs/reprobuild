## ``repro_solver/solver_api`` — high-level public surface for the
## Spec-Implementation M2 ASP-based concretizer.
##
## M2a (this file) defines the *placeholder* shape of the API: a
## ``Solver`` record carrying nothing yet, a ``Solution`` record
## carrying nothing yet, and a ``Constraint`` variant capturing the
## three constraint shapes M2b/M2c will need to encode. ``solve`` is a
## stub that returns an empty ``Solution`` so callers can already
## reference the public surface without compile errors.
##
## **What M2b–M2e add on top of this scaffold**
##
## * **M2b — variant encoder**: walk the
##   ``libs/repro_dsl_stdlib/configurables/variants.nim`` registry,
##   emit ASP atoms (one per variant value) + priorities + the
##   ``requires:`` / ``conflicts:`` / ``propagates:`` rules. ``Solver``
##   grows a ``variants: seq[VariantDecl]`` field; ``Solution`` grows
##   ``variantAssignments: Table[string, string]``.
## * **M2c — version-constraint encoder**: lift the version-range
##   constraints out of the package model and onto the same control.
##   Spack's ``asp.py`` ``concretize.lp`` is the reference encoding.
## * **M2d — variant-conditioned ``uses:``**: feed the resolved variant
##   assignments back through the M1 ``finalizeVariants()`` path so the
##   conditional ``uses:`` arms come alive during graph emission.
## * **M2e — explanation paths**: walk the unsat core
##   (``clingo_solve_handle_core``) and the model atoms to produce
##   structured "why X chosen" / "why unsatisfiable" diagnostics.
##
## **Out of M2a scope:** every encoding decision above. M2a deliberately
## stops at the typed surface so the review agent has a small diff to
## sign off on.

import std/tables

import clingo_bindings

export clingo_bindings

# --------------------------------------------------------------------
# Constraint surface (placeholder)
# --------------------------------------------------------------------

type
  ConstraintKind* = enum
    ## The three constraint shapes the variant addendum in
    ## ``Configurable-System.md`` §"Solver-Participating Configurables
    ## (Variants)" introduces. M2b's encoder dispatches on this tag.
    ckRequires        ## ``requires: variantA = "x" -> packageB`` etc.
    ckConflicts       ## ``conflicts: variantA = "x" with variantB = "y"``
    ckPropagates      ## ``propagates: variantA -> variantB`` (value carry)

  Constraint* = object
    ## Placeholder constraint record. M2b grows this into the typed
    ## expression tree the encoder consumes. The string ``raw`` field
    ## is here so M2a-era callers can stamp a debug label without
    ## committing to a tree shape.
    case kind*: ConstraintKind
    of ckRequires:
      requiresRaw*: string
    of ckConflicts:
      conflictsRaw*: string
    of ckPropagates:
      propagatesRaw*: string

# --------------------------------------------------------------------
# Solver / Solution (placeholder)
# --------------------------------------------------------------------

type
  Solver* = object
    ## Placeholder solver handle. M2b grows this into a real record
    ## carrying the variant registry, the package version-range index,
    ## the ASP encoding buffer, and the clingo control pointer. M2a
    ## ships the bare type so downstream lib code can reference it.
    constraints*: seq[Constraint]

  Solution* = object
    ## Placeholder solution record. M2b grows ``variantAssignments``;
    ## M2c grows a ``packageVersions`` table; M2d grows the lookup map
    ## ``finalizeVariants()`` consumes; M2e grows the explanation
    ## surface. M2a ships the bare type plus an ``isEmpty`` indicator.
    isEmpty*: bool
    variantAssignments*: Table[string, string]

# --------------------------------------------------------------------
# Public API (stub)
# --------------------------------------------------------------------

proc newSolver*(): Solver =
  ## M2a constructor: returns a Solver with no constraints. M2b will
  ## extend this with a variant-registry pull from
  ## ``libs/repro_dsl_stdlib/configurables/variants.nim``.
  Solver(constraints: @[])

proc addConstraint*(solver: var Solver; c: Constraint) =
  ## M2a accumulation hook so M2b's encoder has a single chokepoint to
  ## intercept. Today the constraint is stored verbatim; M2b will
  ## translate it into ASP rules as it lands.
  solver.constraints.add(c)

proc solve*(solver: Solver): Solution {.exportc.} =
  ## M2a stub. Returns an empty ``Solution`` ready for M2b's encoder
  ## to fill in. The ``{.exportc.}`` pragma is here so M2d's
  ## variant.value finalize path can call into the solver across the
  ## (eventual) dynamic-library boundary used by the runtime DSL DLL.
  ## M2a's stub is intentionally pure-Nim with no clingo call so that
  ## this scaffold compiles cleanly on systems where ``libclingo.so``
  ## hasn't been pulled in yet (build-time visibility of the binding
  ## doesn't imply load-time presence of the shared library).
  Solution(isEmpty: true, variantAssignments: initTable[string, string]())
