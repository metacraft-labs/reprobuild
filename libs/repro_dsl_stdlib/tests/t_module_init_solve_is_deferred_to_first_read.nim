## The module-scope finalize owes its solve to the first read of the answer,
## and the answer is the one the eager finalize would have produced.
##
## WHAT THIS PINS, and why the pairing is the test rather than a timing. The
## `package` macro emits a finalize at MODULE scope and also emits an `import`
## of every declared dependency's `repro.nim`, each of which is another
## `package` block with its own module-scope finalize. The pending dependency
## registry is CUMULATIVE, so a recipe whose transitive closure is N recipes
## drove N clingo solves before `main` — each over a strictly larger ASP
## program than the last, and each overwritten by the next
## (`Named-Lock-Files.md` §1.1: "N solves over 1, 2, … N packages … Only the
## last result is retained").
##
## `finalizeVariantsAtModuleInit` collapses that to at most one solve by owing
## it until something reads. The risk that creates is a SILENT one — a reader
## that does not trigger the owed solve gets an empty or stale answer — so
## every case below is a paired comparison: the same registrations driven once
## through the eager `finalizeVariants` and once through the module-init
## spelling, with the answer read back through the public accessors. An
## agreement is the contract; a divergence is the defect.
##
## THE TWO CARVE-OUTS ARE THE SAFETY ARGUMENT and each has a case here:
##
##   * a block that declared VARIANTS must solve at the finalize, because the
##     solved values are written back into the ambient context and popped
##     there. Probed through `.value`, which does NOT route through
##     `ensureUnifiedSolution` — if the deferral ever leaked into the variant
##     path, that read raises `EVariantNotResolved`.
##   * `REPRO_EMIT_SOLVER_INPUTS` must solve at the finalize, because
##     `repro lock refresh` compiles the recipe to a provider binary and runs
##     it PRECISELY for the module-init solve's emitted inputs
##     (`repro_cli_support.solverInputsFromCompiledProvider`: "Declaration-only
##     modules emit solver inputs during initialization"). Deferring there
##     would leave the emit file unwritten and the refresh would silently
##     report no inputs rather than fail. Probed by the file's existence
##     before any accessor read.
##
## Test-double policy: NO mocks, doubles, or fakes. Real registrations through
## `registerSolverDependency`, real lock files written by the real `repro_lock`
## writer and read back through the real `parseSolvedGraphLock` /
## `lockToSolution` pair, real clingo solves on both sides of every pairing.

import std/[os, tables, tempfiles, unittest]

import repro_dsl_stdlib/configurables/variants
import repro_dsl_stdlib/configurables/api
import repro_dsl_stdlib/configurables/types
import repro_dsl_stdlib/toolchain_policy
import repro_lock
import repro_solver

const LibFoo = "libfoo"
const LockedVersion = "1.4.0"
const DeclaredRange = ">=1.5"
const FreeResolution = "1.5.0"

proc writeLock(path: string; packages, variants: openArray[(string, string)]) =
  var sol = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
  for (name, version) in packages: sol.packages[name] = version
  for (name, value) in variants: sol.variants[name] = value
  let solved = solutionToLock(sol, currentPlatformId(), "")
  writeFile(path, serializeLockedDependencies(lockedDepsFromSolved(solved)))

proc governWith(lockPath: string) =
  let solution = lockToSolution(parseSolvedGraphLock(readFile(lockPath)))
  putEnv(LockPinsEnvVar, renderLockPins(solution.packages, solution.variants))
  putEnv(LockPathEnvVar, lockPath)

proc ungovern() =
  delEnv(LockPinsEnvVar)
  delEnv(LockPathEnvVar)

template withScenario(body: untyped) =
  ## Wrapped in a `block` so a single test case can run two scenarios — which
  ## every pairing below does, one eager and one deferred.
  block:
    let scratch {.inject.} = createTempDir("repro-defer-solve-", "")
    ungovern()
    resetVariantState()
    try:
      body
    finally:
      resetVariantState()
      ungovern()
      removeDir(scratch)

template makeStringVariant(name, default: string): Configurable[string] =
  let info = instantiationInfo(fullPaths = true)
  let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
  declareVariant[string](
    defaultValue = default,
    scopeName = name,
    description = "",
    explicitId = "",
    descriptionFile = "",
    descriptionLine = 0,
    descriptionColumn = 0,
    site = site)

proc registerUnsatisfiable() =
  ## Two parents whose ranges on one dependency share no version: a
  ## package-only registry no model satisfies.
  registerSolverDependency("appAlpha", LibFoo, LibFoo & " >=2.0")
  registerSolverDependency("appBeta", LibFoo, LibFoo & " <1.0")

template makeBoolVariant(name: string): Configurable[bool] =
  let info = instantiationInfo(fullPaths = true)
  let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
  declareVariant[bool](
    defaultValue = true,
    scopeName = name,
    description = "",
    explicitId = "",
    descriptionFile = "",
    descriptionLine = 0,
    descriptionColumn = 0,
    site = site)

suite "the deferred module-init solve answers what the eager solve answered":

  test "one package: the deferred answer equals the eager answer":
    var eager = ""
    withScenario:
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariants()
      eager = chosenVersion(LibFoo)
    check eager == FreeResolution
    withScenario:
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariantsAtModuleInit()
      check chosenVersion(LibFoo) == eager

  test "a cumulative registry: N deferred finalizes then one read == N eager":
    ## Each `finalizeVariantsAtModuleInit` here stands for one imported
    ## recipe's module scope, and the assertion is that collapsing N solves
    ## into one loses nothing: the answer a reader gets is the answer the LAST
    ## module-init solve would have produced, because the registry only grows.
    var eager = initTable[string, string]()
    withScenario:
      for i in 0 ..< 6:
        registerSolverDependency("appAlpha", "pkg" & $i, "pkg" & $i & " >=1.0")
        finalizeVariants()
      eager = lastSolverSolution().packages
    check eager.len > 0
    withScenario:
      for i in 0 ..< 6:
        registerSolverDependency("appAlpha", "pkg" & $i, "pkg" & $i & " >=1.0")
        finalizeVariantsAtModuleInit()
      let deferred = lastSolverSolution().packages
      check deferred.len == eager.len
      for name, version in eager:
        check name in deferred
        check deferred[name] == version

  test "hasSolverSolution() pays the owed solve rather than reporting false":
    ## The dangerous failure mode if it did not: a reader that answers "no
    ## solution" falls through to a lattice or host default silently.
    withScenario:
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariantsAtModuleInit()
      check hasSolverSolution()

  test "an empty registry: deferred agrees with eager that there is nothing":
    withScenario:
      finalizeVariants()
      check not hasSolverSolution()
    withScenario:
      finalizeVariantsAtModuleInit()
      check not hasSolverSolution()

suite "a block that declared variants keeps its eager solve":

  test "a declared variant resolves at the module-init finalize alone":
    withScenario:
      let v = makeBoolVariant("flagA")
      finalizeVariantsAtModuleInit()
      # `.value` does not route through `ensureUnifiedSolution`; if the
      # deferral reached the variant path this raises EVariantNotResolved.
      check v.value == true

  test "a later explicit finalizeVariants supersedes a pending debt":
    withScenario:
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariantsAtModuleInit()
      let v = makeBoolVariant("flagB")
      finalizeVariants()
      check v.value == true
      check chosenVersion(LibFoo) == FreeResolution

suite "REPRO_EMIT_SOLVER_INPUTS keeps the module-init solve eager":

  test "with the variable set the inputs are emitted before any read":
    withScenario:
      let emitPath = scratch / "solver-inputs.explain"
      putEnv(SolverInputsEmitEnvVar, emitPath)
      try:
        registerSolverDependency("appAlpha", LibFoo,
                                 LibFoo & " " & DeclaredRange)
        finalizeVariantsAtModuleInit()
        check fileExists(emitPath)
        check readFile(emitPath).len > 0
      finally:
        delEnv(SolverInputsEmitEnvVar)

  test "without it nothing has been solved when the finalize returns":
    ## The negative control for the case above. Without it, a carve-out that
    ## never actually deferred would pass the whole suite.
    withScenario:
      let emitPath = scratch / "solver-inputs.explain"
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariantsAtModuleInit()
      check not fileExists(emitPath)

suite "a refusal survives the deferral":

  test "a lock contradicting a declared range is refused at the first read":
    ## The refusal moves from module-init time to first-read time. What must
    ## NOT move is whether there is one: a deferral that swallowed the
    ## conflict would re-solve to 1.5.0 and build a graph the lock never
    ## named, which is the defect `Named-Lock-Files.md` §1.2 describes.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {LibFoo: LockedVersion}, [])
      governWith(lockPath)
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariantsAtModuleInit()
      expect ELockConflict:
        discard chosenVersion(LibFoo)

  test "a lock that satisfies the range is honoured through the deferral":
    # The negative control: the refusal must be driven by the contradiction,
    # not by the presence of a lock.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {LibFoo: "1.7.0"}, [])
      governWith(lockPath)
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariantsAtModuleInit()
      check chosenVersion(LibFoo) == "1.7.0"

  test "a read after a refused read reports the refusal is not retried":
    ## RECORDED BEHAVIOUR, not an endorsement of it. `ensureUnifiedSolution`
    ## clears the debt BEFORE running the solve, so a solve that raised is
    ## never retried and the second read reports `EPackageNotResolved`
    ## instead of the conflict. It is written down because the alternative —
    ## discovering it from a confusing diagnostic later — is worse, and
    ## because nothing in the tree catches one of these and reads again:
    ## eagerly, the raise happened at module init and killed the process
    ## before a second read existed.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {LibFoo: LockedVersion}, [])
      governWith(lockPath)
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariantsAtModuleInit()
      var first = "no exception"
      try:
        discard chosenVersion(LibFoo)
      except ELockConflict: first = "ELockConflict"
      except EPackageNotResolved: first = "EPackageNotResolved"
      var second = "no exception"
      try:
        discard chosenVersion(LibFoo)
      except ELockConflict: second = "ELockConflict"
      except EPackageNotResolved: second = "EPackageNotResolved"
      check first == "ELockConflict"
      check second == "EPackageNotResolved"

suite "a registration made after the finalize reaches the deferred solve":

  test "the deferred solve sees a dependency the eager one could not":
    ## RECORDED BEHAVIOUR. `packaging/runtime_contract.registerPackageNativeTool`
    ## calls `registerSolverDependency` from inside a `build:` body — that is,
    ## AFTER module init. The eager module-init solve could not see it and
    ## `chosenVersion` raised for it; the deferred solve runs after it and
    ## resolves it. The deferred answer is a widening, never a narrowing: the
    ## registry is monotonic, so every package the eager solve saw is still
    ## there.
    withScenario:
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariants()
      registerSolverDependency("appAlpha", "latetool", "latetool >=1.0")
      expect EPackageNotResolved:
        discard chosenVersion("latetool")
    withScenario:
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariantsAtModuleInit()
      registerSolverDependency("appAlpha", "latetool", "latetool >=1.0")
      check chosenVersion("latetool").len > 0
      # The widening does not cost the answer the eager solve did give.
      check chosenVersion(LibFoo) == FreeResolution

suite "a toolchain read pays no owed solve that cannot answer it":
  ## Reprobuild-pm issue
  ## `2026-11-07-test-binaries-pay-minutes-of-module-init-before-any-case-runs`,
  ## option A1. A `build:` body runs at module init in every non-provider
  ## binary and reaches `activeSolvedVariants`. When nothing the owed solve
  ## reads declares `targetTriple` or `compiler`, the solve cannot assign
  ## either, so the read is skipped. Solves are COUNTED
  ## (`unifiedSolveCount`), not timed: every case below that claims "no
  ## solve" has a paired read in the same scenario that does solve, so a
  ## counter that never moved would fail it.

  test "nothing declares them: defaults, and the solve stays owed":
    withScenario:
      resetUnifiedSolveMemo()
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariantsAtModuleInit()
      let selected = activeSolvedVariants()
      check selected.targetTriple == targetTripleFromEnv()
      check selected.compiler == ""
      check unifiedSolveCount() == 0
      # The control: the debt is still owed and the counter sees it paid.
      check chosenVersion(LibFoo) == FreeResolution
      check unifiedSolveCount() == 1

  test "the --target env still reaches the skipped read":
    withScenario:
      resetUnifiedSolveMemo()
      let saved = getEnv(VariantEnvVar)
      putEnv(VariantEnvVar, "targetTriple=aarch64-unknown-linux-gnu")
      try:
        registerSolverDependency("appAlpha", LibFoo,
                                 LibFoo & " " & DeclaredRange)
        finalizeVariantsAtModuleInit()
        check activeSolvedVariants().targetTriple ==
          "aarch64-unknown-linux-gnu"
        check unifiedSolveCount() == 0
      finally:
        if saved.len > 0: putEnv(VariantEnvVar, saved)
        else: delEnv(VariantEnvVar)

  test "a block that declared targetTriple solved and its answer is read":
    ## The recipe-shaped case: the root recipe's own block declares the
    ## variant, so its finalize solves eagerly and the read is a lookup.
    withScenario:
      resetUnifiedSolveMemo()
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      discard makeStringVariant("targetTriple", "riscv64-unknown-linux-gnu")
      finalizeVariantsAtModuleInit()
      check unifiedSolveCount() == 1
      check activeSolvedVariants().targetTriple == "riscv64-unknown-linux-gnu"
      check unifiedSolveCount() == 1

  test "an open declaration of compiler makes the owed solve answer it":
    ## The skip's other arm: a solve is owed AND the inputs it would read
    ## declare `compiler`, so the read must pay it and return the solver's
    ## value rather than the default.
    withScenario:
      resetUnifiedSolveMemo()
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariantsAtModuleInit()
      discard makeStringVariant("compiler", "clang")
      check activeSolvedVariants().compiler == "clang"
      check unifiedSolveCount() == 1

  test "a governing lock keeps the read, so its refusal stays in the body":
    ## A lock that contradicts a declared range is refused by the read. A
    ## build body that reads nothing but the toolchain must still be refused,
    ## so a governing lock is one of the things that "could answer".
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {LibFoo: LockedVersion}, [])
      governWith(lockPath)
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariantsAtModuleInit()
      expect ELockConflict:
        discard activeSolvedVariants()

suite "an unsatisfiable package-only solve is still reported":
  ## The caveat A1 settles. Before A1 an unsatisfiable package-only registry
  ## was refused by the first `build:` body that reached
  ## `activeSolvedVariants`. After it, that read does not solve, and the
  ## refusal is raised by the first read of the solved answer instead —
  ## with the same message, which carries the unsat core
  ## (`Locking-And-Solver.md`: "An unsatisfiable solve names what it could not
  ## satisfy, on every entry point"). The spec fixes WHAT the refusal says,
  ## not at which read it surfaces.

  test "eager: refused at the finalize":
    withScenario:
      registerUnsatisfiable()
      expect EUnsatisfiable:
        finalizeVariants()

  test "deferred: not refused by the toolchain read, refused at first read":
    var eagerMsg = ""
    withScenario:
      registerUnsatisfiable()
      try:
        finalizeVariants()
      except EUnsatisfiable as e:
        eagerMsg = e.msg
    check eagerMsg.len > 0
    withScenario:
      resetUnifiedSolveMemo()
      registerUnsatisfiable()
      finalizeVariantsAtModuleInit()
      let selected = activeSolvedVariants()
      check selected.compiler == ""
      check unifiedSolveCount() == 0
      var deferredMsg = ""
      try:
        discard lastSolverSolution()
      except EUnsatisfiable as e:
        deferredMsg = e.msg
      check deferredMsg == eagerMsg

  test "deferred: chosenVersion reports it too":
    withScenario:
      registerUnsatisfiable()
      finalizeVariantsAtModuleInit()
      discard activeSolvedVariants()
      expect EUnsatisfiable:
        discard chosenVersion(LibFoo)

suite "identical solves run clingo once":
  ## Option A2: `runUnifiedSolve` is memoised in-process on the ASP program
  ## it would hand clingo, which is a pure function of every input the solve
  ## reads.

  test "an identical re-solve is a memo hit with the same answer":
    withScenario:
      resetUnifiedSolveMemo()
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariants()
      let first = lastSolverSolution()
      # An include-shim copy of the same recipe: same edge again, deduplicated
      # by the registry, so the re-armed solve sees identical inputs.
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariants()
      check unifiedSolveCount() == 1
      check unifiedSolveMemoHitCount() == 1
      check lastSolverSolution().packages == first.packages
      check lastSolverSolution().variants == first.variants

  test "a grown registry re-solves":
    withScenario:
      resetUnifiedSolveMemo()
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariants()
      registerSolverDependency("appAlpha", "libbar", "libbar >=2.0")
      finalizeVariants()
      check unifiedSolveCount() == 2
      check unifiedSolveMemoHitCount() == 0
      check chosenVersion("libbar") == "2.0.0"

  test "a changed variant input re-solves and answers the new value":
    var first = ""
    withScenario:
      resetUnifiedSolveMemo()
      let v = makeStringVariant("compiler", "gcc")
      finalizeVariants()
      first = v.value
    withScenario:
      let v = makeStringVariant("compiler", "clang")
      finalizeVariants()
      check first == "gcc"
      check v.value == "clang"
      check unifiedSolveCount() == 2

  test "a lock pin is part of the key":
    ## Same registrations, one governed by a lock: the pin changes the
    ## program, so the governed solve is not served the free answer.
    withScenario:
      resetUnifiedSolveMemo()
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariants()
      check chosenVersion(LibFoo) == FreeResolution
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {LibFoo: "1.7.0"}, [])
      governWith(lockPath)
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariants()
      check chosenVersion(LibFoo) == "1.7.0"
      check unifiedSolveCount() == 2

  test "a refused solve is not memoised":
    withScenario:
      resetUnifiedSolveMemo()
      registerUnsatisfiable()
      expect EUnsatisfiable:
        finalizeVariants()
      expect EUnsatisfiable:
        finalizeVariants()
      check unifiedSolveCount() == 2
      check unifiedSolveMemoHitCount() == 0
