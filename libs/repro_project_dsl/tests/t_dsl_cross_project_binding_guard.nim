## Regression: cross-project build bindings whose RHS is NOT resolvable at
## module scope must not break the ``package`` macro.
##
## The M5 cross-project-edge feature lifts every top-level ``let``/``var`` in
## a ``build:`` block to a module-level storage var typed ``typeof(<rhs>)``.
## That ``typeof`` is evaluated at MODULE scope, where helpers defined inside
## the ``build:`` block (templates, procs) and sibling build-local bindings
## are NOT visible. Before the ``when compiles(typeof(rhs))`` guard in
## ``cross_project.nim`` the macro emitted the storage var unconditionally, so
## two shapes that CodeTracer's ``reprobuild.nim`` uses heavily failed to
## compile with ``undeclared identifier``:
##
##   1. ``let x = ctNimJs(...)``     — RHS calls a template defined inside the
##                                     same ``build:`` block.
##   2. ``var a = @[frontendUiJs]``  — RHS references a sibling build-local
##                                     binding.
##
## This file reproduces both. That it COMPILES AT ALL is the primary
## regression assertion (the bug was a hard compile error). The runtime
## checks pin the guard's graceful-degradation contract: a module-resolvable
## binding stays exposed as ``<pkg>.build.<binding>`` (its init flag is
## declared), while a non-resolvable binding is silently left as a plain
## build-local ``let`` (no storage, no init flag, no accessor) instead of
## aborting the whole compilation.
##
## The M5 smoke test (``t_dsl_m5_composition_smoke.nim``) only ever exercised
## a module-resolvable RHS (``toyAdapter.compile(...)``), which is exactly why
## it did not catch this — this file fills that gap.

import std/unittest

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types

type
  ToyHandle = object
    path: string

# ---------------------------------------------------------------------------
# Adapter package: a CLI-only typed-tool surface. ``toyAdapter.compile(...)``
# is a module-level wrapper proc, so its ``typeof`` DOES resolve at module
# scope — the "good" case the storage var can be typed against.
# ---------------------------------------------------------------------------
package toyAdapter:
  executable toyEdge:
    cli:
      subcmd "compile":
        flag source is string
        flag binary is string
        outputs result is ToyHandle, binary

# ---------------------------------------------------------------------------
# Producer package mixing the broken shapes with the working one.
# ---------------------------------------------------------------------------
package crossGuard:
  build:
    # A helper template defined INSIDE the build block. It is visible to the
    # lowered builder proc, but NOT at module scope, where the cross-project
    # storage var's ``typeof(...)`` is evaluated.
    template viaTemplate(src, bin: string): untyped =
      toyAdapter.compile(source = src, binary = bin)

    # (1) RHS calls the build-local template.
    #     Pre-fix: ``undeclared identifier: 'viaTemplate'`` at module scope.
    let localTemplateEdge = viaTemplate("a.nim", "build/a")

    # (3) Module-resolvable RHS (a module-level typed-tool wrapper). This one
    #     CAN and SHOULD remain a cross-project binding.
    let directEdge = toyAdapter.compile(source = "b.nim", binary = "build/b")

    # (2) RHS references a sibling build-local binding.
    #     Pre-fix: ``undeclared identifier: 'directEdge'`` at module scope.
    let siblingRefEdge = @[directEdge]

    discard localTemplateEdge
    discard siblingRefEdge

# Whether each binding was exposed is observable through the existence of its
# generated init-flag (``composeBindingInit_<pkg>_<binding>``); the guard
# emits one only for bindings it could back with a module-level storage var.
when declared(composeBindingInit_crossGuard_directEdge):
  const directExposed = true
else:
  const directExposed = false

when declared(composeBindingInit_crossGuard_localTemplateEdge):
  const localTemplateExposed = true
else:
  const localTemplateExposed = false

when declared(composeBindingInit_crossGuard_siblingRefEdge):
  const siblingRefExposed = true
else:
  const siblingRefExposed = false

suite "Project-DSL cross-project binding guard":

  test "the package macro compiles with non-module-resolvable bindings":
    # Reaching this test at all means the file compiled — i.e. the macro no
    # longer emits a ``typeof(<rhs>)`` storage var that can't be typed.
    check true

  test "a module-resolvable binding stays exposed as a cross-project edge":
    check directExposed
    # Same shape as the M5 smoke test: the init flag exists and is false
    # before the producer's build block runs.
    check not composeBindingInit_crossGuard_directEdge

  test "a binding whose RHS calls a build-local template is NOT exposed":
    check not localTemplateExposed

  test "a binding whose RHS references a sibling binding is NOT exposed":
    check not siblingRefExposed

  test "the prelude namespace for the producer is still constructible":
    let b = PackageBuild["crossGuard"]()
    discard b
    check true
