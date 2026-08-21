## The ONE place a solved graph is read to pick a toolchain.
##
## Named-Lock-Files NLF-M7, design §4.4. Before this module there were **two**
## parallel paths that read the solved variants to choose a toolchain, and the
## second conceded the duplication in its own doc comment:
##
##   * `resolveToolchain()` / `resolveCrossTarget()` in `active_context.nim`,
##     which fill the `BuildContext` slots; and
##   * `currentCompiler()` in `operations/toolchain.nim`, which bypassed
##     `BuildContext` entirely and is what `operations/compile.nim` dispatches
##     on.
##
## Both looked variant names up as plain strings in
## `lastSolverSolution().variants` (`"targetTriple"`, `"compiler"`). §4.4 names
## unifying them a **prerequisite** for the lock-file slot, and says why in
## terms sharper than tidiness: "A lock-file slot added to only one of them
## would be honoured by some typed-tool calls and silently ignored by others —
## precisely the §4.9 failure shape, and worse because it would be
## intermittent."
##
## So this module owns every read of a solved graph's variant table that is
## made for toolchain purposes, and both former paths call it. The property to
## preserve when editing: **`lastSolverSolution()` must not be read for a
## toolchain decision anywhere else.** A test asserts it by grepping the
## stdlib source (`t_one_toolchain_resolution_path`), because the invariant is
## about where a call appears and no run-time assertion can see that.
##
## ## The lock-file slot enters HERE, once
##
## §4.4 puts the lock file on `PackageBuildState` as a fifth slot beside
## `toolchain` / `crossTarget`. What that slot *does* is select which solved
## graph the lookups below consult: an edge emitted under `hostTools` reads
## `hostTools`'s solved graph, and an edge emitted under `targetRuntime` reads
## `targetRuntime`'s. Because there is one lookup site, the slot is honoured by
## every typed-tool call or by none — which is the whole point of the
## unification.
##
## A workspace that declares nothing registers nothing, `activeSolvedVariants`
## falls through to `lastSolverSolution()`, and every lookup answers exactly
## what it answered before. That is NLF-STAT-3's property at this layer.

import std/[strutils, tables]

import repro_lock_files
import repro_project_dsl

import ./configurables/variants

type
  ToolchainSelection* = object
    ## What a solved graph says about the toolchain, read once.
    targetTriple*: string
      ## The resolved `targetTriple` variant, or `""` when the graph does not
      ## assign one. `"native"` is a value, not an absence.
    compiler*: string
      ## The resolved `compiler` variant, or `""` when unassigned.
    lockFileName*: string
      ## The lock file whose solved graph answered. Diagnostics only — it is
      ## a handle (§6.2) and never enters a key.

var solvedGraphsByLockFile {.threadvar.}: Table[string, Table[string, string]]
  ## Per-lock-file solved variant assignments, registered by whoever solved
  ## them. Empty for a workspace that declares no lock files, which is why
  ## adding this table moves nothing: `activeSolvedVariants` falls through.

proc registerSolvedVariantsFor*(lockFileName: string;
                                variants: Table[string, string]) =
  ## Record the variant assignments of `lockFileName`'s solved graph.
  ##
  ## Called by whatever produced the graph — the CLI after a per-lock-file
  ## solve, or a test that constructs one. Deliberately NOT called from
  ## `finalizeVariants()`: the ordinary single-solve path has no lock-file
  ## name to register under, and inventing `default` for it would make the
  ## table non-empty for every workspace and put this code on the default
  ## path, which NLF-STAT-3 forbids.
  if solvedGraphsByLockFile.len == 0:
    solvedGraphsByLockFile = initTable[string, Table[string, string]]()
  solvedGraphsByLockFile[lockFileName] = variants

proc resetSolvedVariantRegistrations*() =
  ## Drop every registration. Test-facing: a test that registers a graph must
  ## not leak it into the next one.
  solvedGraphsByLockFile = initTable[string, Table[string, string]]()

proc activeSolvedVariants*(): ToolchainSelection =
  ## The variant assignments governing the ACTIVE build region.
  ##
  ## Order, and it is the §4.3 precedence chain seen from the consuming end:
  ##
  ##   1. the solved graph registered for the lock file the active build
  ##      region is under, if one is registered;
  ##   2. otherwise `lastSolverSolution()` — the single-solve path every
  ##      pre-NLF-M7 workspace takes.
  let name = activeLockFileName()
  if name.len > 0 and solvedGraphsByLockFile.hasKey(name):
    let assigned = solvedGraphsByLockFile[name]
    result.lockFileName = name
    result.targetTriple = assigned.getOrDefault("targetTriple", "")
    result.compiler = assigned.getOrDefault("compiler", "")
    return
  if hasSolverSolution():
    let sol = lastSolverSolution()
    result.lockFileName = name
    if "targetTriple" in sol.variants:
      result.targetTriple = sol.variants["targetTriple"]
    if "compiler" in sol.variants:
      result.compiler = sol.variants["compiler"]

proc isCrossTriple*(triple: string): bool =
  ## A triple names a cross build when it is present and is not `native`.
  ## Written once so the two former paths cannot drift on the spelling of
  ## "not cross" — they already had two copies of this test.
  triple.len > 0 and triple.toLowerAscii() != "native"
