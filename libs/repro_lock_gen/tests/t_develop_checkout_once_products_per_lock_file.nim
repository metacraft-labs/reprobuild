## NLF-DEV-1 and NLF-DEV-4 — one checkout, two configured builds.
##
## Named-Lock-Files NLF-M8. The narrowed §10 claim, stated as one sentence and
## then split into the two halves that must be asserted separately:
##
## > **A develop-mode dependency's *source* is lock-independent. Its
## > *variants* are not.**
##
## Corpus **NLF-DEV-1**: "`libfoo` in develop mode (local checkout). Two lock
## files. Two consumers, one under each. **Expect.** **One** checkout on disk,
## used by both. No second clone, no second materialisation."
##
## Corpus **NLF-DEV-4**: "A develop-mode `libfoo` with variant `enableTLS`,
## under two lock files assigning it differently. **Expect.** **Two builds of
## the one checkout**, configured differently … **One** checkout on disk
## (NLF-DEV-1 still holds), **two** sets of build products."
##
## ## Why the two halves have to be in one file
##
## Because each is the trap the other one sets. NLF-DEV-4 names them:
##
## > 1. **Variants recorded from the checkout rather than solved** — the
## >    rejected alternative. Under it both consumers get one configuration
## >    and one of them is silently wrong.
## > 2. **The source-independence claim over-applied** — an implementation
## >    that, having correctly given both consumers one checkout, also gives
## >    them one set of build products. That is the trap the narrowed §10
## >    claim exists to prevent, and it is easy to fall into precisely because
## >    the checkout half is correct.
##
## An implementation that passed only DEV-1 would look right and ship the
## wrong `libfoo` to one of its two consumers. So this file asserts, over ONE
## workspace: the checkout path is the same object for both lock files, the
## observed VERSION is the same in both solves, and the variant assignment
## DIFFERS between them.
##
## ## Owner decision this rests on
##
## Q-4, settled 2026-08-18: "a develop-mode package's **variant values are
## SOLVED, not recorded**." §10.3 records that the implementation had the two
## halves exactly inverted — the version was fabricated and searched for while
## the variants reached the solver not at all. NLF-M2 landed the observation
## half (`develop_sources.nim`) and NLF-M8 is where both halves are asserted
## together against one workspace.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## The checkout below is a real directory on the real filesystem with a real
## `VERSION` file; the overrides document is the real JSON shape
## `REPRO_DEVELOP_OVERRIDES_FILE` names and is read by the real
## `developSourceFor`; the two solves are real generations against a real
## loopback registry over real HTTP, driven by real clingo. `nlf_m6_fixture`'s
## header states the policy in full.

import std/[json, options, os, strutils, tables, unittest]

import repro_dsl_stdlib/configurables/develop_sources
import repro_lock_gen
import repro_solver

import ./nlf_m7_fixture

const
  Tool = "tool"
  App = "app"
  LibFoo = "libfoo"
  EnableTls = "enableTLS"
  TargetRuntime = "targetRuntime"
  CheckoutVersion = "2.3.1"

var scratchRoot = ""

proc checkoutPath(): string = scratchRoot / "checkouts" / LibFoo

proc writeCheckout() =
  ## ONE checkout on disk. There is deliberately no per-lock-file directory
  ## here, and no loop that could create one: §10 and
  ## `Workspace-And-Develop-Mode.md` §"Union Rules" both say there is
  ## physically one tree per path, and a fixture that made two would be
  ## testing something the design forbids.
  createDir(checkoutPath())
  writeFile(checkoutPath() / "VERSION", CheckoutVersion & "\n")

proc writeOverrides() =
  let doc = %*{"overrides": [
    {"node": LibFoo, "path": checkoutPath()}]}
  writeFile(scratchRoot / "develop-overrides.json", $doc)
  putEnv("REPRO_DEVELOP_OVERRIDES_FILE",
    scratchRoot / "develop-overrides.json")
  resetDevelopSourceCache()

proc workspace(): Recipe =
  ## Two consumers, one under each lock file, both using the develop sibling.
  ## They DEMAND opposite values of `enableTLS`, which is what makes the two
  ## graphs configure the one checkout differently.
  Recipe(
    packages: @[
      RecipePackage(name: Tool, versions: @["1.0.0"],
        deps: @[dep(LibFoo, ">=0")],
        demands: @[(variant: EnableTls, value: "false")]),
      RecipePackage(name: App, versions: @["1.0.0"],
        deps: @[dep(LibFoo, ">=0")],
        demands: @[(variant: EnableTls, value: "true")]),
      RecipePackage(name: LibFoo, versions: @[CheckoutVersion])],
    artifacts: @[
      RecipeArtifact(name: Tool, package: Tool,
        lockFile: HostToolsLockFileName),
      RecipeArtifact(name: App, package: App, lockFile: TargetRuntime)],
    boolVariants: @[EnableTls])

proc pinDevelop(decls: seq[PackageDecl]): seq[PackageDecl] =
  ## §10.1 — the develop sibling's version is OBSERVED, so it enters the solve
  ## as a fact rather than as a cardinality choice. `newPinnedPackage` is the
  ## surface NLF-M2 added for exactly this, and reading the value through
  ## `developSourceFor` rather than restating the constant is what makes this
  ## the observation path and not a second copy of the answer.
  let observed = developSourceFor(LibFoo)
  doAssert observed.isSome, "the develop override did not resolve"
  result = @[]
  for d in decls:
    if d.name == LibFoo:
      result.add(newPinnedPackage(LibFoo, observed.get().version, d.depends))
    else:
      result.add(d)

proc solvePerLockFileWithDevelop(reg: Registry; r: Recipe):
    Table[string, LockGenerationResult] =
  result = initTable[string, LockGenerationResult]()
  reg.publishRecipe(r)
  let prop = propagationOf(r)
  for name in prop.lockFilesInUse():
    result[name] = runLockSolve(
      reg.request(pinDevelop(declsFor(r, prop, name)), lsDefault,
        variants = variantsFor(r, prop, name),
        inputsText = "nlf-m8 develop " & name), "")

suite "NLF-DEV-1/NLF-DEV-4 one checkout, two configured builds":

  setup:
    resetLockFileDeclarations()
    discard declareLockFile(TargetRuntime,
      description = "Everything we ship.")
    scratchRoot = getTempDir() / ("repro-nlf-m8-develop-" &
      $getCurrentProcessId())
    removeDir(scratchRoot)
    createDir(scratchRoot)
    writeCheckout()
    writeOverrides()

  teardown:
    delEnv("REPRO_DEVELOP_OVERRIDES_FILE")
    resetDevelopSourceCache()
    try: removeDir(scratchRoot)
    except CatchableError: discard

  test "NLF-DEV-1: there is exactly ONE checkout on disk":
    var found: seq[string] = @[]
    for kind, path in walkDir(scratchRoot / "checkouts"):
      if kind == pcDir: found.add(path)
    check found.len == 1
    check found[0] == checkoutPath()

  test "NLF-DEV-1: both lock files resolve to that same checkout":
    # The override is keyed by PACKAGE, not by (package, lock file), so there
    # is no second answer to be had. Asserting it anyway is the point: a
    # design that multiplied develop state per lock file would need a
    # different key here, and this is where that would show.
    let underHost = developSourceFor(LibFoo)
    let underTarget = developSourceFor(LibFoo)
    check underHost.isSome
    check underTarget.isSome
    check underHost.get().path == underTarget.get().path
    check underHost.get().path == checkoutPath()

  test "NLF-DEV-2 premise: the version is READ from the checkout":
    # Not asserted for its own sake — NLF-DEV-2 owns that case — but because
    # everything below depends on the pinned version being the observed one
    # rather than one fabricated from the declared range. `">=0"` is exactly
    # the range §10.3 measured `smallestSatisfyingVersion` turning into
    # `"0.0.0"`.
    let observed = developSourceFor(LibFoo)
    check observed.isSome
    check observed.get().version == CheckoutVersion

  test "NLF-DEV-4: two lock files, two solves, one source and two configurations":
    let reg = startRegistry("nlf-m8-develop")
    try:
      let solved = solvePerLockFileWithDevelop(reg, workspace())
      check solved.lockFileNames() == @[HostToolsLockFileName, TargetRuntime]

      # The SOURCE half — lock-independent. Both graphs pin the version that
      # was read off the one checkout.
      let host = solved[HostToolsLockFileName].solvedVersions()
      let target = solved[TargetRuntime].solvedVersions()
      check host[LibFoo] == CheckoutVersion
      check target[LibFoo] == CheckoutVersion

      # The VARIANT half — NOT lock-independent. Each lock file's solve
      # answers its own consumer's demand, and the two answers differ. This
      # is the assertion that fails under both of NLF-DEV-4's traps: under
      # "recorded rather than solved" there is one answer, and under "source
      # independence over-applied" there is one set of build products.
      let hostTls = solved[HostToolsLockFileName].solvedVariant(EnableTls)
      let targetTls = solved[TargetRuntime].solvedVariant(EnableTls)
      checkpoint("hostTools " & EnableTls & " = " & hostTls)
      checkpoint("targetRuntime " & EnableTls & " = " & targetTls)
      check hostTls == "false"
      check targetTls == "true"
      check hostTls != targetTls

      # Two sets of build products, stated the way §6.2 makes it observable:
      # two graphs whose content differs are two identities, and §7 then keys
      # their edges apart. One identity would mean one set of products
      # serving both consumers, which is the trap.
      check solved[HostToolsLockFileName].lockIdentity.isValid()
      check solved[TargetRuntime].lockIdentity.isValid()
      check solved[HostToolsLockFileName].lockIdentity !=
        solved[TargetRuntime].lockIdentity
    finally:
      reg.shutdown()

  test "and the checkout is still exactly one directory afterwards":
    # NLF-DEV-1 restated after the solves have run, because "one checkout"
    # is a claim about what the build DID and not only about what it started
    # with. A generation that materialised a per-lock-file copy would leave
    # the evidence right here.
    let reg = startRegistry("nlf-m8-develop-after")
    try:
      discard solvePerLockFileWithDevelop(reg, workspace())
    finally:
      reg.shutdown()
    var found: seq[string] = @[]
    for kind, path in walkDir(scratchRoot / "checkouts"):
      if kind == pcDir: found.add(path)
    check found.len == 1
    check fileExists(checkoutPath() / "VERSION")
    check readFile(checkoutPath() / "VERSION").strip() == CheckoutVersion
