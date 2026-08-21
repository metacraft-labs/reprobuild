## DSL-port M9.R.2b — Layer-2 toolchain dispatch helper.
##
## The mid-level operation overloads (``compile``, ``link``,
## ``archive``, ``strip`` under ``operations/``) call ``currentCompiler()``
## to pick the per-compiler implementation.
##
## ## What NLF-M7 changed here, and why it had to
##
## This module used to make its OWN read of ``lastSolverSolution().variants``
## for the ``compiler`` variant, in parallel with ``active_context.nim``'s
## ``resolveToolchain`` / ``resolveCrossTarget``. Its former doc comment
## conceded the duplication in terms ("The variant-read path mirrors
## ``active_context.nim``'s ``resolveToolchain``").
##
## `Named-Lock-Files.md` §4.4 names removing that duplication a
## **prerequisite** for the lock-file slot, and the reason is not tidiness:
##
## > Both look variant names up as plain strings in
## > ``lastSolverSolution().variants`` … A lock-file slot added to only one of
## > them would be honoured by some typed-tool calls and silently ignored by
## > others — precisely the §4.9 failure shape, and worse because it would be
## > intermittent.
##
## So ``currentCompiler`` now resolves through the ACTIVE BUILD CONTEXT — the
## same ``Toolchain`` the ``compile`` / ``link`` helpers would reach through
## ``currentBuildContext().toolchain`` — and falls back to the single shared
## resolver in ``toolchain_policy.nim`` when no build block is active. There
## is exactly one place left in the stdlib that reads a solved graph to make a
## toolchain decision, and ``t_one_toolchain_resolution_path`` asserts it by
## construction.

import std/strutils

import repro_project_dsl

import ../active_context
import ../toolchain_policy

type
  CompilerFamily* = enum
    ## The three compiler families v1 dispatches across. ``cfMsvc`` is
    ## declared but not yet implemented — recipes that resolve the
    ## ``compiler`` variant to ``"msvc"`` raise from the per-operation
    ## dispatcher (``operations/compile.nim`` etc.) until a real msvc
    ## implementation lands.
    cfGcc
    cfClang
    cfMsvc

var
  compilerOverride {.threadvar.}: string
    ## Thread-local override for test fixtures that need to drive the
    ## dispatcher without running the variant solver. Empty means
    ## "no override; read the resolved toolchain".

proc setCompilerOverride*(name: string) =
  ## Test-fixture helper. Pass ``""`` to clear the override and fall
  ## back to the resolved toolchain (or the ``cfGcc`` default).
  compilerOverride = name

proc parseCompilerFamily*(name: string): CompilerFamily =
  ## Map a ``compiler.value`` string onto the enum. Unknown values
  ## fall back to ``cfGcc`` — the dispatcher is forgiving so a recipe
  ## with a typo doesn't crash at graph-emission time; the per-tool
  ## wrappers downstream will surface the missing-binary error.
  case name.toLowerAscii()
  of "gcc": cfGcc
  of "clang": cfClang
  of "msvc", "cl": cfMsvc
  else: cfGcc

proc currentCompiler*(): CompilerFamily =
  ## Resolve the active compiler family. Lookup order:
  ##
  ##   1. Thread-local override (test fixtures use this).
  ##   2. The ACTIVE BUILD CONTEXT's resolved ``Toolchain``, whose family the
  ##      adapter declares. This is the unification: the dispatcher and the
  ##      context now agree by construction rather than by two lookups that
  ##      happen to read the same variant.
  ##   3. The shared resolver, for calls made outside any ``build:`` block.
  ##   4. Default ``cfGcc``.
  if compilerOverride.len > 0:
    return parseCompilerFamily(compilerOverride)
  if tryCurrentBuildState() != nil:
    let family = currentBuildContext().toolchain.compilerFamily
    if family.len > 0:
      return parseCompilerFamily(family)
  parseCompilerFamily(activeSolvedVariants().compiler)
