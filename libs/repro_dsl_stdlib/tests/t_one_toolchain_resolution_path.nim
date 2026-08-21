## Exactly one toolchain-resolution path remains.
##
## Named-Lock-Files NLF-M7. Design §4.4, and NLF-M7's exit criterion "Exactly
## one toolchain-resolution path remains".
##
## §4.4 records the hazard this test is the regression for:
##
## > There are already **two parallel paths** that read the solved variants to
## > pick a toolchain, and the second concedes the duplication in its own doc
## > comment … Both look variant names up as plain strings in
## > `lastSolverSolution().variants` (`"targetTriple"`, `"compiler"`). A
## > lock-file slot added to only one of them would be honoured by some
## > typed-tool calls and silently ignored by others — precisely the §4.9
## > failure shape, and worse because it would be intermittent.
##
## ## The two halves, and why neither alone is the test
##
## The BEHAVIOURAL half asserts that the lock-file designation reaches BOTH
## consumers: the `BuildContext`'s toolchain slot and `currentCompiler()`, the
## dispatcher `operations/compile.nim` switches on. That is the property that
## actually matters, and it is what fails before the unification — the
## dispatcher answered from `lastSolverSolution()` and could not see a
## per-lock-file graph at all.
##
## The STRUCTURAL half asserts that only `toolchain_policy.nim` reads a solved
## graph for a toolchain decision. It is here because the behavioural half is
## satisfiable by a SECOND path that happens to agree today: someone adding a
## third consumer with its own `lastSolverSolution()` read would keep every
## assertion below green while reintroducing exactly the intermittent
## divergence §4.4 describes. "Exactly one" is a statement about where a call
## appears, and no run-time assertion can see that.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## The build frame is a real `beginBuildBlock` frame, the toolchain is the
## real stdlib adapter the real `resolveToolchain` picks, and
## `currentCompiler()` is the real dispatcher entry point. The solved variant
## assignments are FIXTURE DATA — a table this test registers rather than one
## clingo produced — which is what the registration API exists for and is what
## a per-lock-file solve hands it in production. That bounds the conclusion:
## this file concludes that a registered graph reaches both consumers, not
## anything about how the solver produces one.

import std/[algorithm, os, strutils, tables, unittest]

import repro_dsl_stdlib/active_context
import repro_dsl_stdlib/operations/toolchain
import repro_lock_files
import repro_project_dsl

proc stdlibSourceDir(): string =
  currentSourcePath().parentDir().parentDir() / "src" / "repro_dsl_stdlib"

proc modulesResolvingAToolchain(): seq[string] =
  ## Every stdlib module whose CODE names one of the two variants a toolchain
  ## decision is made from — `"targetTriple"` or `"compiler"` — relative to
  ## the stdlib source root.
  ##
  ## Those two literals are the right probe rather than `lastSolverSolution`,
  ## and §4.4 is what says so: the hazard it names is that "both look variant
  ## names up as plain strings in `lastSolverSolution().variants`
  ## (`"targetTriple"`, `"compiler"`)". Other modules legitimately read the
  ## same solution for other decisions — `operations/buildtype.nim` reads the
  ## build type, `adapters/solver_feature_set.nim` reads features — and
  ## folding those into "a toolchain-resolution path" would make the count
  ## wrong in the direction that produces a test nobody can keep green.
  ##
  ## Doc-comment lines are stripped before matching, so a module may still
  ## DESCRIBE the lookup — this file's own subject module does — without
  ## being counted as making one.
  result = @[]
  let root = stdlibSourceDir()
  for path in walkDirRec(root):
    if not path.endsWith(".nim"): continue
    let rel = path.relativePath(root)
    for raw in readFile(path).splitLines():
      let line = raw.strip()
      if line.startsWith("#"): continue
      if "\"targetTriple\"" in line or "\"compiler\"" in line:
        result.add(rel.replace('\\', '/'))
        break
  result.sort()

suite "NLF-M7 exactly one toolchain-resolution path":

  setup:
    resetLockFileScopes()
    resetSolvedVariantRegistrations()
    setCompilerOverride("")

  teardown:
    resetLockFileScopes()
    resetSolvedVariantRegistrations()
    setCompilerOverride("")

  test "only toolchain_policy resolves a toolchain from a solved graph":
    check modulesResolvingAToolchain() == @["toolchain_policy.nim"]

  test "a per-lock-file graph reaches the context slot AND the dispatcher":
    # The designation names a graph in which the compiler is clang. Before the
    # unification the context slot honoured it and `currentCompiler()` did
    # not — the intermittent divergence §4.4 predicts.
    registerSolvedVariantsFor("hostTools",
      {"compiler": "clang"}.toTable())
    let state = beginBuildBlock("mytool", "executable", "tablegen")
    try:
      withLockFile "hostTools":
        check currentBuildContext().toolchain.name == "clang-toolchain"
        check currentBuildContext().toolchain.compilerFamily == "clang"
        check currentCompiler() == cfClang
    finally:
      endBuildBlock(state)

  test "two regions of one build body resolve to two toolchains":
    # §4.4's whole point: "a lock file field that can differ between two
    # regions of one build body". If the dispatcher read a process-wide
    # solution it could not differ between regions at all, so this is the
    # assertion that a single global read cannot pass.
    registerSolvedVariantsFor("hostTools", {"compiler": "clang"}.toTable())
    registerSolvedVariantsFor("targetRuntime", {"compiler": "gcc"}.toTable())
    let state = beginBuildBlock("mytool", "executable", "app")
    try:
      withLockFile "hostTools":
        check currentCompiler() == cfClang
      withLockFile "targetRuntime":
        check currentCompiler() == cfGcc
      # And the slot follows the region, not the frame.
      withLockFile "hostTools":
        check currentBuildContext().lockFile == "hostTools"
      check currentBuildContext().lockFile == "default"
    finally:
      endBuildBlock(state)

  test "a workspace that registers nothing resolves exactly as before":
    # NLF-STAT-3 at this layer: the unification must not move the default
    # path. With no registration and no designation the resolver falls
    # through to the single-solve path and answers the stdlib default.
    let state = beginBuildBlock("mytool")
    try:
      check currentBuildContext().toolchain.name == "gcc-toolchain"
      check currentCompiler() == cfGcc
      check currentBuildContext().lockFile == "default"
    finally:
      endBuildBlock(state)

  test "the fixture override still wins over everything":
    # `setCompilerOverride` is the one lookup that outranks the context, and
    # it must keep doing so or every existing operation fixture changes
    # meaning.
    registerSolvedVariantsFor("hostTools", {"compiler": "gcc"}.toTable())
    setCompilerOverride("clang")
    let state = beginBuildBlock("mytool")
    try:
      withLockFile "hostTools":
        check currentCompiler() == cfClang
    finally:
      endBuildBlock(state)
