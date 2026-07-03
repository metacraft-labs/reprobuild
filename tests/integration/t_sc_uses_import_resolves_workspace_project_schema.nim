## Cross-Repo-Source-Consumption SC-9 — ``usesImportCode`` resolves a ``uses:``
## selector naming a WORKSPACE PROJECT to that producer's exported CLI schema
## module and imports it, so the consumer can name ``producer.tool(args)`` as a
## TYPED call that type-checks against the producer's schema AT CONSUMER MACRO
## EXPANSION.
##
## Spec: ``Cross-Repo-Source-Consumption.md`` §9.2 (extend ``usesImportCode`` to
## import a workspace project's CLI schema) + §9.3 (reuse the accessor /
## ``toolActionWrapperCode`` machinery, widened from same-file to workspace).
## Milestone: ``Cross-Repo-Source-Consumption.milestones.org`` §SC-9.
##
## Before SC-9, ``usesImportCode`` (``macros_a.nim``) resolved a ``uses:``
## selector's schema module ONLY from the hardcoded bundled-stdlib list and an
## explicit local ``usesImportPath`` — it had NO workspace-project resolution,
## so a sibling project ``scprod9exe``'s ``executable scprod9exe: cli:`` could
## not be typed-consumed as ``scprod9exe.serve(...)`` in EITHER mode. SC-9 adds
## exactly that: for a ``uses:`` selector naming an on-disk workspace sibling
## (``../<selector>/repro.nim`` anchored on the CONSUMER's own source file), the
## producer's ``repro.nim`` module is imported, bringing its ``const
## scprod9exe = ...`` + the per-command wrapper procs (``serve``, ``status`` —
## emitted by the EXISTING ``toolActionWrapperCode``) into the consumer's scope.
##
## The producer fixtures live one level up from THIS test file, at
## ``../scprod9exe/repro.nim`` and ``../scprod9lib/repro.nim`` (relative to
## ``tests/integration/`` → ``tests/scprod9exe`` / ``tests/scprod9lib``), so the
## SC-9 sibling discovery (anchored on ``lineInfoObj().filename``) finds them.
## The imports and the typed calls below are resolved at COMPILE time; reaching
## the ``suite`` at all means the SC-9 extension imported the schema and the
## typed call type-checked. MODE-AGNOSTIC — no repro binary, no develop
## override, no lock; the schema import happens purely at consumer macro
## expansion.
##
## Falsifiability: reverting the SC-9 ``usesImportCode`` extension makes
## ``scprod9exe`` an undeclared identifier (assertion ``exeConstDeclared``
## flips to false and ``serveCompiles`` to false) — the file would then fail to
## carry the typed surface. The negative controls (a MISTYPED command name is a
## compile error; a bundled-stdlib ``uses: "sh"`` is unaffected) pin the
## behaviour is schema-checked and additive.

import std/unittest

import repro_project_dsl

# ---------------------------------------------------------------------------
# The CONSUMER package. ``uses: "scprod9exe"`` names the sibling workspace
# EXECUTABLE producer and ``uses: "scprod9lib"`` the sibling LIBRARY producer;
# ``uses: "sh"`` is a bundled-stdlib selector (the additive control). The SC-9
# ``usesImportCode`` extension imports both sibling producers' ``repro.nim``
# schema modules, so the typed call in the ``build:`` block type-checks against
# ``scprod9exe``'s exported ``serve`` command (§9.5 worked example).
# ---------------------------------------------------------------------------
package sc9consumer:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "scprod9exe"
    "scprod9lib"

  build:
    # Typed call over the sibling producer's exported ``executable scprod9exe``
    # — ``serve`` + its ``socket`` flag are checked against the IMPORTED schema
    # (SC-9). Without the SC-9 import this line is an ``undeclared identifier``.
    discard scprod9exe.serve(socket = "/tmp/sc9.sock")
    discard scprod9exe.status(verbose = "1")

# ---------------------------------------------------------------------------
# Compile-time observability. Because the SC-9 import brings the producer's
# ``const scprod9exe`` + wrapper procs into THIS module's scope, ``declared``
# and ``compiles`` observe whether the schema was imported and typed-checked.
# ---------------------------------------------------------------------------

# (1) The producer const is in scope — the schema module was imported.
when declared(scprod9exe):
  const exeConstDeclared = true
else:
  const exeConstDeclared = false

# (2) The exported ``serve`` command with its typed ``socket`` flag compiles.
when compiles(scprod9exe.serve(socket = "/x")):
  const serveCompiles = true
else:
  const serveCompiles = false

# (3) The exported ``status`` command compiles.
when compiles(scprod9exe.status(verbose = "1")):
  const statusCompiles = true
else:
  const statusCompiles = false

# (4) NEGATIVE — a MISTYPED command name is NOT a valid typed call: ``scprod9exe``
#     exports no ``bogusverb`` command, so the wrapper proc does not exist.
when compiles(scprod9exe.bogusverb(socket = "/x")):
  const bogusCommandCompiles = true
else:
  const bogusCommandCompiles = false

# (5) NEGATIVE — a MISTYPED flag on a real command is rejected: ``serve`` has no
#     ``nosuchflag`` parameter.
when compiles(scprod9exe.serve(nosuchflag = "/x")):
  const bogusFlagCompiles = true
else:
  const bogusFlagCompiles = false

# (6) The sibling LIBRARY producer's package const is in scope too (its schema
#     module was imported by the same SC-9 branch).
when declared(scprod9lib):
  const libConstDeclared = true
else:
  const libConstDeclared = false

# (7) ADDITIVE CONTROL — the bundled-stdlib ``sh`` selector still imports
#     unchanged (its package const is in scope via the pre-SC-9 stdlib path).
when declared(sh):
  const shConstDeclared = true
else:
  const shConstDeclared = false

suite "SC-9: usesImportCode resolves a workspace project's CLI schema":

  test "t_sc_uses_import_resolves_workspace_project_schema":
    # (1) The workspace producer's exported schema was IMPORTED — its package
    #     const is declared in the consumer's scope. This is the SC-9 core: a
    #     ``uses:`` selector naming a workspace project resolves to that
    #     producer's exported CLI schema module (beyond the bundled-stdlib list
    #     + local ``usesImportPath``).
    check exeConstDeclared

    # (2)/(3) The producer's exported per-command typed wrappers (``serve`` with
    #     its ``socket`` flag, ``status`` with ``verbose``) type-check against
    #     the imported schema — the EXISTING ``toolActionWrapperCode`` machinery
    #     widened from same-file to workspace (no new emitter).
    check serveCompiles
    check statusCompiles

    # (4)/(5) NEGATIVE — a mistyped command name and a mistyped flag are COMPILE
    #     errors: the typed call is schema-checked at macro expansion, not run
    #     time (§9.5). ``scprod9exe.bogusverb(...)`` / a bogus flag do not
    #     compile because the producer exports no such command/param.
    check not bogusCommandCompiles
    check not bogusFlagCompiles

    # (6) The sibling LIBRARY producer's contract was imported by the SAME SC-9
    #     branch (a library producer is a workspace project too).
    check libConstDeclared

    # (7) ADDITIVE — a bundled-stdlib ``uses: "sh"`` still imports unchanged
    #     (byte-identical behaviour for every existing stdlib selector; the SC-9
    #     branch fires ONLY for selectors that name an on-disk workspace sibling
    #     and are not already bundled-stdlib / local-import covered).
    check shConstDeclared
