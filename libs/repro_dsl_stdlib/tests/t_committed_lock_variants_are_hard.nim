## A locked VARIANT assignment is a constraint, not a preference: it survives a
## model that scores better on the `#minimize` objective.
##
## Named-Lock-Files NLF-M3. Design reference: `Named-Lock-Files.md` §1.2, which
## measures the variant half of the defect — the CLI injected the committed
## lock's variant assignments as ordinary `prSet` contributions, "which the
## encoder renders as `#minimize` weights, not hard constraints", so "the
## variant half is a soft preference that a sufficiently attractive alternative
## model can outvote".
##
## THE PREMISE IS MEASURED, NOT ASSERTED, and that is what makes this file a
## regression rather than a restatement. The fixture is built so a
## soft contribution of the locked value LOSES: three bool variants, coupled
## through variant-gated version arms of one dependency whose ranges are
## mutually exclusive, so `enableA=true` forces `enableB` and `enableC` off.
## With the default band weighting an uncontributed value strictly worse than a
## contributed one, the objective prefers `A=false, B=true, C=true` (three
## contributions honoured) over `A=true, B=false, C=false` (one honoured), and
## it still prefers it when `A=true` is raised a whole priority band to `prSet`
## — the exact band `--variant` and the old lock injection use. The second case
## below runs that arm and confirms the loss on the real solver, so the third
## case's pin is demonstrably holding against a model the objective prefers,
## and not merely agreeing with one.
##
## Test-double policy: NO mocks, doubles, or fakes. The lock is a real
## `reprobuild.solved-graph-lock.v2` file produced by the real `repro_lock`
## writer and read back through the real `parseSolvedGraphLock` /
## `lockToSolution` pair the CLI's loader uses; the soft arm uses the real
## `REPRO_VARIANTS` surface `--variant` writes; every answer comes from a real
## clingo solve through `finalizeVariants()`. Running the real solver is the
## point: "scores better on `#minimize`" is a claim about clingo's optimum and
## nothing short of clingo can settle it.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_dsl_stdlib/configurables/variants
import repro_dsl_stdlib/configurables/api
import repro_dsl_stdlib/configurables/types
import repro_lock
import repro_solver

const LibFoo = "libfoo"
const NewMajor = "2.0.0"
const OldMajor = "1.0.0"

proc writeLock(path: string; variants: openArray[(string, string)]) =
  var sol = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
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
  delEnv("REPRO_VARIANTS")

proc declareGraph() =
  ## Three bool variants, coupled through one dependency.
  ##
  ## `enableA`'s arm wants `libfoo >=2.0`; `enableB`'s and `enableC`'s want
  ## `[1.0, 2.0)`. One version is chosen for `libfoo`, so `enableA` cannot be
  ## on at the same time as either of the others. The declared defaults make
  ## the majority position — A off, B and C on — the objective's favourite.
  discard variantImpl[bool](false, "enableA", captureSite(ckDefault))
  discard variantImpl[bool](true, "enableB", captureSite(ckDefault))
  discard variantImpl[bool](true, "enableC", captureSite(ckDefault))
  registerSolverDependency("appAlpha", LibFoo, LibFoo & " >=2.0",
                           "enableA", "true")
  registerSolverDependency("appAlpha", LibFoo, LibFoo & " >=1.0 <2.0",
                           "enableB", "true")
  registerSolverDependency("appAlpha", LibFoo, LibFoo & " >=1.0 <2.0",
                           "enableC", "true")

template withScenario(body: untyped) =
  let scratch {.inject.} = createTempDir("repro-nlf-m3-var-", "")
  ungovern()
  resetVariantState()
  try:
    body
  finally:
    resetVariantState()
    ungovern()
    removeDir(scratch)

proc declOf(decls: seq[VariantDecl]; name: string): VariantDecl =
  for d in decls:
    if d.name == name:
      return d
  raise newException(ValueError,
    "no VariantDecl named " & name & " in " & $decls.len & " declarations")

suite "the objective outvotes a soft assignment":
  ## The premise. Both cases here hold before and after the fix — they exist to
  ## establish that the third suite's pin is winning a fight, not walking over.

  test "control: the objective prefers enableA off":
    withScenario:
      declareGraph()
      finalizeVariants()
      let sol = lastSolverSolution()
      check sol.variants["enableA"] == "false"
      check sol.variants["enableB"] == "true"
      check sol.variants["enableC"] == "true"
      check chosenVersion(LibFoo) == OldMajor

  test "a REPRO_VARIANTS assignment of enableA=true is outvoted":
    # `REPRO_VARIANTS` is exactly the transport the measured implementation
    # used for the lock's variants, and `--variant` still uses it. A `prSet`
    # contribution is a whole priority band above the declared default and it
    # STILL loses, because `#minimize` sums across variants and two honoured
    # defaults outweigh one honoured set.
    withScenario:
      putEnv("REPRO_VARIANTS", "enableA=true")
      declareGraph()
      finalizeVariants()
      check lastSolverSolution().variants["enableA"] == "false"

suite "a locked variant assignment is hard":

  test "the pin survives the better-scoring model":
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {"enableA": "true"})
      governWith(lockPath)
      declareGraph()
      finalizeVariants()
      let sol = lastSolverSolution()
      check sol.variants["enableA"] == "true"
      # And the rest of the graph moved to accommodate it: the two variants
      # whose arms conflict with A's are off, and the version that follows
      # from A's arm is the one selected. A pin that held while the graph
      # around it stayed put would mean the coupling had quietly stopped
      # working and the case had gone vacuous.
      check sol.variants["enableB"] == "false"
      check sol.variants["enableC"] == "false"
      check chosenVersion(LibFoo) == NewMajor

  test "the pinned variant contributes no assignment choice":
    # The encoder is where "constraint" and "preference" are actually
    # distinguishable: an asserted `variant_assigned` fact versus a
    # `{ ... } = 1` choice rule whose outcome the objective then decides.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {"enableA": "true"})
      governWith(lockPath)
      declareGraph()
      let enableA = declOf(currentSolverVariantDecls(), "enableA")
      check enableA.pinnedValue == "true"
      check encodeCardinality(enableA).len == 0
      check "variant_assigned(\"enableA\", \"true\")." in
        encodeUniverseFacts(enableA)

  test "an unlocked variant keeps its assignment choice":
    # The negative control: pinning is granted on the evidence of a lock entry,
    # never by default.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {"enableA": "true"})
      governWith(lockPath)
      declareGraph()
      let enableB = declOf(currentSolverVariantDecls(), "enableB")
      check enableB.pinnedValue.len == 0
      check "{ variant_assigned(\"enableB\", X)" in encodeCardinality(enableB)

  test "the pin survives the rendering the digest is taken over":
    # `inputsDigest` is taken over `renderSolverInputsFixture`'s output, so a
    # solver input the rendering cannot express is one the digest cannot see.
    # A pinned assignment and a contribution naming the same value are
    # different inputs and must not render alike.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {"enableA": "true"})
      governWith(lockPath)
      declareGraph()
      let pinned = currentSolverInputsFixture()
      check "pinned: true" in pinned

      resetVariantState()
      ungovern()
      putEnv("REPRO_VARIANTS", "enableA=true")
      declareGraph()
      let contributed = currentSolverInputsFixture()
      check "pinned: true" notin contributed
      check pinned != contributed

suite "an explicit override still outranks the lock":
  ## `Named-Lock-Files.md` §2.5 — the lock is mode-agnostic and the CLI's own
  ## overrides layer above it. Asserted rather than left implicit, because the
  ## fix removed the CLI's lock->`REPRO_VARIANTS` injection and this is the
  ## property that removal has to preserve.

  test "--variant beats a lock pinning the other value":
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {"enableA": "true"})
      governWith(lockPath)
      putEnv("REPRO_VARIANTS", "enableA=false")
      declareGraph()
      let enableA = declOf(currentSolverVariantDecls(), "enableA")
      check enableA.pinnedValue.len == 0
      finalizeVariants()
      check lastSolverSolution().variants["enableA"] == "false"
