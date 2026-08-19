## A develop-mode dependency's SOURCE is read from its checkout; its VARIANTS
## are solved. The implementation has the two halves inverted, and this file is
## the regression that says so.
##
## Corpus cases `NLF-DEV-2` and `NLF-DEV-3`, from
## `reprobuild-specs/Named-Lock-Files-Test-Corpus.md`. Design reference:
## `Named-Lock-Files.md` §10.1 (source identity is recorded, not solved), §10.3
## (the implementation does the opposite), §10.4 / owner decision Q-4
## (2026-08-18: a develop package's variant values are SOLVED, not recorded).
##
## The framing matters, because an earlier draft had it backwards. A develop
## dependency BELONGS in the solve — Q-4 settles that its configuration is the
## solver's output, because a consumer linking a develop-mode `libfoo` has to
## know whether TLS was enabled in it, and only the solve knows that. So the
## defect is not "develop dependencies reach clingo". It is that the wrong half
## reaches it:
##
##   * its VERSION is fabricated by `smallestSatisfyingVersion` from the
##     declared range text — `">=0"` yields `"0.0.0"` — and then handed to
##     clingo as a candidate to search, when it is sitting on disk and should
##     be read;
##   * its VARIANTS reach nothing at all, because `buildVariantDecls` walks
##     only the current process's ambient context and a sibling named in
##     `uses:` is built with `newPackage(depName, versions)` — empty variants.
##
## Test-double policy: NO mocks, doubles, or fakes. The checkout is a real git
## repository created on the real filesystem and tagged; the override metadata
## is a real file in the real format the engine writes and
## `REPRO_DEVELOP_OVERRIDES_FILE` names; registration goes through the real
## public `registerSolverDependency` surface; and the ASP assertions run the
## real `repro_solver` encoder over the real declarations. The only thing not
## exercised is clingo itself, deliberately — the properties here are
## properties of what is HANDED to the solver, so making them depend on the
## solver being installed and the instance satisfiable would weaken them.
##
## Why the ASP surface and not just the rendered fixture: a pinned package and
## a package with exactly one candidate render identically — one `versions:`
## line either way. The corpus calls that substitution out by name, because
## "an implementation could read the right version from the checkout and still
## hand it to the solver as a one-element choice". Only the encoder
## distinguishes them, so `NLF-DEV-3` asserts there.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_dsl_stdlib/configurables/variants
import repro_dsl_stdlib/configurables/api
import repro_dsl_stdlib/configurables/types
import repro_solver

const DevelopedPackage = "libfoo"
const CheckoutVersion = "2.3.1"

proc run(cmd: string; args: openArray[string]; workDir: string): string =
  ## Run a real command, failing the test loudly rather than degrading. A
  ## silent failure here would produce a checkout with no version, and the
  ## test would then "pass" against a fallback it is supposed to forbid.
  let (output, code) = execCmdEx(
    cmd & " " & args.join(" "), workingDir = workDir)
  if code != 0:
    raise newException(OSError,
      cmd & " " & args.join(" ") & " failed in " & workDir &
      " (exit " & $code & "): " & output)
  output.strip()

proc makeDevelopCheckout(root: string; version = CheckoutVersion): string =
  ## A real git checkout — created, not described — carrying a real `VERSION`
  ## file. The git repository is here because a develop override points at a
  ## working copy and the test should look like one; the VERSION file is what
  ## is actually READ.
  ##
  ## The tag is deliberately NOT the source of the answer. Reading it would
  ## mean running ambient `git` from the solve path, which
  ## `Package-Model.md` forbids — see the note in `develop_sources.nim`. The
  ## tag is written anyway, and set to a DIFFERENT version than the file, so
  ## that an implementation which quietly starts shelling out to git fails
  ## this test instead of passing it by coincidence.
  let path = root / DevelopedPackage
  createDir(path)
  writeFile(path / "repro.nim", "## develop-mode sibling under test\n")
  if version.len > 0:
    writeFile(path / "VERSION", version & "\n")
  discard run("git", ["-c", "init.defaultBranch=main", "init", "-q"], path)
  discard run("git", ["-c", "user.email=t@example.invalid",
                      "-c", "user.name=Test",
                      "add", "."], path)
  discard run("git", ["-c", "user.email=t@example.invalid",
                      "-c", "user.name=Test",
                      "commit", "-q", "-m", "initial"], path)
  discard run("git", ["tag", "v9.9.9"], path)
  path

proc declareDevelopOverride(root, checkout: string) =
  ## Write the override metadata in the shape the engine publishes and point
  ## `REPRO_DEVELOP_OVERRIDES_FILE` at it — the same contract
  ## `repro_project_dsl.developOverridePath` reads.
  let metadata = %*{
    "overrides": [
      {"node": DevelopedPackage, "path": checkout, "state": "editable"}
    ]
  }
  let metadataPath = root / "develop-overrides.json"
  writeFile(metadataPath, $metadata)
  putEnv("REPRO_DEVELOP_OVERRIDES_FILE", metadataPath)

proc declOf(decls: seq[PackageDecl]; name: string): PackageDecl =
  for d in decls:
    if d.name == name:
      return d
  raise newException(ValueError,
    "no PackageDecl named " & name & " in " & $decls.len & " declarations")

template withScenario(body: untyped) =
  ## One temp workspace, one develop checkout, one registered dependency.
  ## Torn down completely so no case can observe another's registry or env.
  let scratch {.inject.} = createTempDir("repro-nlf-dev-", "")
  let checkout {.inject.} = makeDevelopCheckout(scratch)
  declareDevelopOverride(scratch, checkout)
  resetVariantState()
  try:
    body
  finally:
    resetVariantState()
    delEnv("REPRO_DEVELOP_OVERRIDES_FILE")
    removeDir(scratch)

suite "t_develop_version_read_from_checkout":
  ## Corpus NLF-DEV-2. Ref: Named-Lock-Files.md §10.3.

  test "a develop sibling declared >=0 records the checkout's version":
    withScenario:
      # `">=0"` is the selector the measured fixture actually uses for its
      # develop siblings, and it is the one that makes the defect visible:
      # `smallestSatisfyingVersion` reads the lower bound verbatim and yields
      # `"0.0.0"`, a version that exists nowhere.
      registerSolverDependency("appAlpha", DevelopedPackage,
                               DevelopedPackage & " >=0")
      let libfoo = declOf(currentSolverPackageDecls(), DevelopedPackage)
      check libfoo.versions == @[CheckoutVersion]

  test "the fabricated version never appears":
    withScenario:
      registerSolverDependency("appAlpha", DevelopedPackage,
                               DevelopedPackage & " >=0")
      # Stated separately from the equality above on purpose. The equality
      # could be satisfied by an implementation that appended the real version
      # to the fabricated candidate set; this says the fabrication is GONE,
      # which is the milestone's exit criterion ("no call path from a
      # develop-mode entry to `smallestSatisfyingVersion`").
      let libfoo = declOf(currentSolverPackageDecls(), DevelopedPackage)
      check "0.0.0" notin libfoo.versions
      check "1.0.0" notin libfoo.versions

  test "a develop sibling with an unparseable selector is not defaulted":
    withScenario:
      # A bare selector with no range clause is the `"1.0.0"` fallback arm of
      # `smallestSatisfyingVersion`. A develop entry must not reach it either:
      # the version is on disk in both cases.
      registerSolverDependency("appAlpha", DevelopedPackage, DevelopedPackage)
      let libfoo = declOf(currentSolverPackageDecls(), DevelopedPackage)
      check libfoo.versions == @[CheckoutVersion]

  test "a non-develop dependency still gets the declared-range treatment":
    withScenario:
      # The negative control. Reading the version from a checkout must apply
      # to develop entries ONLY — a registry package has no checkout to read,
      # and breaking its candidate derivation would be a much worse defect
      # than the one under repair.
      registerSolverDependency("appAlpha", "zlib", "zlib >=1.2.0")
      let zlib = declOf(currentSolverPackageDecls(), "zlib")
      check zlib.versions == @["1.2.0"]

suite "t_develop_version_not_a_solver_choice":
  ## Corpus NLF-DEV-3. Ref: Named-Lock-Files.md §10.3, §10.1.
  ##
  ## NOTE ON THE CORPUS: this case is titled "a develop dependency does not
  ## enter the solve", and its rationale says the defect is "develop
  ## dependencies reaching clingo at all". Both of those predate the Q-4
  ## decision and contradict it — under Q-4 a develop dependency MUST enter
  ## the solve, for its variants. What survives, and what is asserted here, is
  ## the case's `Expect` clause, which is narrower and still correct: the
  ## develop sibling contributes no VERSION-SELECTION choice.

  test "the develop package contributes no version-selection choice":
    withScenario:
      registerSolverDependency("appAlpha", DevelopedPackage,
                               DevelopedPackage & " >=0")
      let libfoo = declOf(currentSolverPackageDecls(), DevelopedPackage)
      # The real encoder, not a re-implementation of it.
      check encodePackageCardinality(libfoo).len == 0

  test "the develop package's version is asserted as a fact instead":
    withScenario:
      registerSolverDependency("appAlpha", DevelopedPackage,
                               DevelopedPackage & " >=0")
      let libfoo = declOf(currentSolverPackageDecls(), DevelopedPackage)
      let universe = encodePackageUniverse(libfoo)
      # Removing the choice is only half of it. Something still has to tell
      # the solver which version was chosen, or every dependent constraint
      # gated on `package_chosen` silently stops applying — coverage lost
      # rather than a wrong answer, which is worse.
      check ("package_chosen(\"" & DevelopedPackage & "\", \"" &
             CheckoutVersion & "\").") in universe

  test "a non-develop package keeps its cardinality choice":
    withScenario:
      registerSolverDependency("appAlpha", "zlib", "zlib >=1.2.0")
      let zlib = declOf(currentSolverPackageDecls(), "zlib")
      # The negative control for the same reason as above: pinning must be
      # granted on evidence of a checkout, never by default. A version the
      # solver is supposed to choose must still be a choice.
      check "{ package_chosen(\"zlib\", V)" in encodePackageCardinality(zlib)

suite "the pin survives the rendering the digest is taken over":
  ## `inputsDigest` is taken over `renderSolverInputsFixture`'s output, so a
  ## solver input the rendering cannot express is a solver input the digest
  ## cannot see. That is the exact defect the canonical-ordering work landed
  ## to remove, and adding a field the renderer ignores would re-open it.

  test "a pinned package renders differently from an unpinned one":
    withScenario:
      registerSolverDependency("appAlpha", DevelopedPackage,
                               DevelopedPackage & " >=0")
      let developed = currentSolverInputsFixture()
      check "pinned: true" in developed
      # And the same package, same single version, WITHOUT the override: the
      # two must not render alike, or the digest cannot tell "observed 2.3.1"
      # from "chose 2.3.1 out of a one-element universe".
      resetVariantState()
      delEnv("REPRO_DEVELOP_OVERRIDES_FILE")
      registerSolverDependency("appAlpha", DevelopedPackage,
                               DevelopedPackage & " >=2.3.1")
      let ordinary = currentSolverInputsFixture()
      check "pinned: true" notin ordinary
      check developed != ordinary

suite "a version that cannot be read is refused, not invented":
  ## NLF-M2 deliverable 4. The whole point of reading the version is lost if
  ## an unreadable checkout quietly falls back to a synthesized one, so the
  ## refusal is asserted as its own property rather than assumed.

  test "an unreadable develop checkout raises instead of defaulting":
    let scratch = createTempDir("repro-nlf-dev-noversion-", "")
    let checkout = makeDevelopCheckout(scratch, version = "")
    declareDevelopOverride(scratch, checkout)
    resetVariantState()
    try:
      registerSolverDependency("appAlpha", DevelopedPackage,
                               DevelopedPackage & " >=0")
      expect EDevelopVersionUnknown:
        discard currentSolverPackageDecls()
    finally:
      resetVariantState()
      delEnv("REPRO_DEVELOP_OVERRIDES_FILE")
      removeDir(scratch)

  test "the diagnostic names the package and the checkout":
    let scratch = createTempDir("repro-nlf-dev-noversion-", "")
    let checkout = makeDevelopCheckout(scratch, version = "")
    declareDevelopOverride(scratch, checkout)
    resetVariantState()
    try:
      registerSolverDependency("appAlpha", DevelopedPackage,
                               DevelopedPackage & " >=0")
      var message = ""
      try:
        discard currentSolverPackageDecls()
      except EDevelopVersionUnknown as err:
        message = err.msg
      # A refusal that does not say WHICH sibling is unreadable, or where it
      # is, sends the reader looking through every `uses:` entry by hand.
      check DevelopedPackage in message
      check checkout in message
    finally:
      resetVariantState()
      delEnv("REPRO_DEVELOP_OVERRIDES_FILE")
      removeDir(scratch)

  test "an override carrying its own version needs nothing on disk":
    # Source 1 of two: the engine records the identity it replaced. This is
    # the path that will carry ordinary develop checkouts once the engine
    # writes it, so it is exercised now rather than left to be discovered.
    let scratch = createTempDir("repro-nlf-dev-recorded-", "")
    let checkout = makeDevelopCheckout(scratch, version = "")
    let metadata = %*{
      "overrides": [
        {"node": DevelopedPackage, "path": checkout, "version": "4.5.6"}
      ]
    }
    let metadataPath = scratch / "develop-overrides.json"
    writeFile(metadataPath, $metadata)
    putEnv("REPRO_DEVELOP_OVERRIDES_FILE", metadataPath)
    resetVariantState()
    try:
      registerSolverDependency("appAlpha", DevelopedPackage,
                               DevelopedPackage & " >=0")
      let libfoo = declOf(currentSolverPackageDecls(), DevelopedPackage)
      check libfoo.versions == @["4.5.6"]
    finally:
      resetVariantState()
      delEnv("REPRO_DEVELOP_OVERRIDES_FILE")
      removeDir(scratch)
