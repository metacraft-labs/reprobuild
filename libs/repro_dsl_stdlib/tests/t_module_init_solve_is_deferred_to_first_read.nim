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
