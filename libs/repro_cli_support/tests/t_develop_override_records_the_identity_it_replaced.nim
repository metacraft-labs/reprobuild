## The engine RECORDS on a develop override what it already knows: the solved
## identity the override replaced, and the sibling's variant declarations.
##
## Named-Lock-Files, closing the last gap of NLF-M2. The override document had
## two consumers and no producer. `develop_sources.nim` reads three things off
## each override entry — `path`, `version`, `variants` — and
## `writeDevelopOverrides` emitted only the first. Both of that module's
## "KNOWN GAP" notes name the same durable fix and point at the same writer:
##
##   > The durable fix is for the engine to record `version` on the override
##   > entry when it writes it (source 1), since it already knows the identity
##   > the override replaced.
##
##   > the engine does not write `variants` yet either
##   > (`writeDevelopOverrides` in `repro_cli_support.nim` emits `node` and
##   > `path`) … The durable fix is for the engine to record the sibling's
##   > declarations when it registers the override, since introspecting the
##   > sibling's recipe is work it is already positioned to do.
##
## ## What "it already knows" means, precisely, for each field
##
## `version` — the CONSUMER's committed `repro.lock`. A develop override
## replaces a solved node; the lock is the document that says which version
## that node was. Nothing else in `repro develop <dep> --into=PATH`'s reach
## answers the question, and the checkout itself is deliberately not consulted
## (that is the consumer's second source, and consulting it here would collapse
## the two into one).
##
## `variants` — the SIBLING's recipe, through the same compiled-provider probe
## `repro lock refresh` and `repro lock list` already use. The sibling's
## declarations exist in the sibling's process; the CLI runs in another one.
##
## ## What is NOT recorded, and why that is the point
##
## A version the engine cannot read is OMITTED. It is not `"0.0.0"`, not a
## timestamp, not the declared range's lower bound — the whole of NLF-M2 was
## removing a synthesized version from the solve, and re-introducing one in the
## writer would put it back one layer up with a more authoritative-looking
## provenance. `a version the engine does not know is not invented` is the case
## that holds that line, and the fallback chain the consumer already documents
## (`VERSION` file, then a loud refusal) is what runs instead.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## Every boundary here is the real one:
##
##   * the WRITER is the real `repro develop <dependency> --into=PATH` verb
##     (`runDevelopCommand`), one frame below the `repro` binary's `main()`;
##   * the FILE is the real document at the path the verb reports, in the real
##     `reprobuild.develop-overrides.v1` shape;
##   * the consumer's committed lock is written by the real
##     `serializeLockedDependencies`, not by hand-assembled TOML;
##   * the sibling is a real recipe on disk whose real provider is compiled and
##     run to obtain its real declarations;
##   * the PARSER is the real `develop_sources` reader, reached the only way
##     production reaches it — `REPRO_DEVELOP_OVERRIDES_FILE` pointing at the
##     document the verb just wrote;
##   * the SOLVE is the real `finalizeVariants()` over real clingo.
##
## The round-trip cases therefore prove one claim end to end rather than two
## halves that happen to agree: no fixture stands between the writer and the
## parser, so a writer that emitted a different spelling than the parser reads
## would fail here even though both sides were internally consistent.
##
## **What is NOT covered, stated rather than implied:** the `repro` binary
## itself is not built or executed (`scripts/build_apps.sh` does not link in
## this environment), so "end to end" here means "through the verb dispatcher".

import std/[exitprocs, json, os, posix, strutils, tables, unittest]

import repro_cli_support
import repro_dsl_stdlib/configurables/variants
import repro_lock

const
  DevelopedPackage = "libfoo"
  LockedVersion = "2.3.1"
  CheckoutFileVersion = "9.8.7"
  TlsVariant = "libfoo.enableTls"
  ProfileVariant = "libfoo.profile"

  ConsumerRecipe = """
import repro_project_dsl

package appAlpha:
  discard
"""

  SiblingRecipe = """
import repro_project_dsl

package libfoo:
  config:
    ## Enable TLS support.
    enableTls: variant bool = true
    ## Which optimisation profile the library is built with.
    profile: variant string = "release"

  build:
    discard
"""
    ## A develop sibling that declares variants. The `build:` block is not
    ## decoration: `buildCode` emits the provider's `runPackageProvider` entry
    ## point only for a recipe that has one, so a recipe without it compiles to
    ## a binary that runs its module init and exits without ever answering the
    ## protocol. A develop sibling is a project you build, so this is what one
    ## looks like — and `a recipe with no build: block cannot be asked` below
    ## pins the other case as the known limitation it is.

  SiblingRecipeWithoutVariants = """
import repro_project_dsl

package libfoo:
  build:
    discard
"""
    ## The same buildable shape, declaring no variants — so a case asserting
    ## that nothing was recorded is asserting that the sibling HAS nothing,
    ## not that it could not be asked.

  SiblingRecipeVariantsButNoBuild = """
import repro_project_dsl

package libfoo:
  config:
    ## Enable TLS support.
    enableTls: variant bool = true
"""
    ## Declares a variant and cannot answer the provider protocol. The known
    ## limitation, recorded rather than papered over.

let NoPackages: seq[LockedPackage] = @[]
  ## A consumer with no committed lock at all — the case the engine must not
  ## answer by inventing something.

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir().parentDir().parentDir()

proc scratchRoot(label: string): string =
  ## Under the repo's `build/` scratch, not the system temp dir: Nim finds
  ## `config.nims` by walking UP from the compiled file, and this repo's is
  ## what puts every `libs/*/src` on the module path. A recipe in /tmp compiles
  ## against a different world and would fail for reasons that have nothing to
  ## do with develop overrides — the same reason
  ## `t_lock_list_without_a_build_block` gives for the same choice.
  result = repoRoot() / "build" /
    ("nlf-devrec-" & label & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc writeConsumer(root: string; lockedPackages: openArray[LockedPackage]) =
  ## A real consumer project: a recipe so it is a project root at all, and —
  ## when the caller supplies one — a real committed lock written by the real
  ## `repro_lock` serializer. Hand-written TOML would let a lock this reader
  ## cannot actually parse pass for one it can.
  createDir(root)
  writeFile(root / "repro.nim", ConsumerRecipe)
  if lockedPackages.len > 0:
    var ld = LockedDependencies(
      schema: "reprobuild.solved-graph-lock.v2",
      platform: "amd64-linux",
      optimal: true,
      inputsDigest: "fnv1a64:0000000000000000")
    for p in lockedPackages:
      ld.packages.add(p)
    writeFile(root / "repro.lock", serializeLockedDependencies(ld))

proc writeSibling(root, recipe: string; versionFile = ""): string =
  ## A real develop checkout: a recipe the provider probe can compile, and
  ## optionally the `VERSION` file that is the CONSUMER's second source. The
  ## two cases that assert on a recorded version deliberately do NOT write one,
  ## so a passing assertion cannot have come from the fallback.
  result = root / DevelopedPackage
  createDir(result)
  writeFile(result / "repro.nim", recipe)
  if versionFile.len > 0:
    writeFile(result / "VERSION", versionFile & "\n")

proc developInto(consumerRoot, checkout: string): string =
  ## Run the real `repro develop <dependency> --into=PATH` verb and return the
  ## metadata path it reports. The verb resolves its project root from the
  ## CURRENT DIRECTORY, which is how a user invokes it, so the cwd is moved
  ## rather than a root threaded in by a back door that production has no
  ## equivalent of.
  let captured = consumerRoot / "develop-stdout.txt"
  let previousDir = getCurrentDir()
  var rc = 0
  block:
    let original = dup(stdout.getFileHandle())
    defer:
      discard dup2(original, stdout.getFileHandle())
      discard close(original)
      setCurrentDir(previousDir)
    let sink = open(captured, fmWrite)
    discard dup2(sink.getFileHandle(), stdout.getFileHandle())
    setCurrentDir(consumerRoot)
    rc = runDevelopCommand([DevelopedPackage, "--into=" & checkout])
    flushFile(stdout)
    sink.close()
  doAssert rc == 0, "repro develop exited " & $rc
  for line in readFile(captured).splitLines():
    if line.startsWith("metadata\t"):
      return line["metadata\t".len .. ^1]
  raise newException(ValueError,
    "repro develop reported no metadata path; it printed: " &
      readFile(captured))

proc overrideEntry(metadataPath: string): JsonNode =
  ## The single override entry of the document the verb just wrote.
  let doc = parseJson(readFile(metadataPath))
  doAssert doc["schemaId"].getStr() == "reprobuild.develop-overrides.v1"
  doAssert doc["overrides"].len == 1,
    "expected exactly one override, got " & $doc["overrides"].len
  doc["overrides"][0]

template withConsumerReading(metadataPath: string; body: untyped) =
  ## Point the real consumer at the document the real writer produced, the one
  ## way production connects them, and tear the registry down afterwards so no
  ## case can observe another's answer.
  putEnv("REPRO_DEVELOP_OVERRIDES_FILE", metadataPath)
  resetVariantState()
  try:
    body
  finally:
    resetVariantState()
    delEnv("REPRO_DEVELOP_OVERRIDES_FILE")

proc solvedVersionOf(package: string): seq[string] =
  ## The candidate versions the develop-mode package carries into the solve,
  ## read from the real registration path.
  registerSolverDependency("appAlpha", package, package & " >=0")
  for decl in currentSolverPackageDecls():
    if decl.name == package:
      return decl.versions
  raise newException(ValueError, "no PackageDecl named " & package)


# ---------------------------------------------------------------------------
# The scenarios, built ONCE.
#
# Each `developInto` runs the real verb, and the real verb now compiles the
# sibling's provider to obtain its declarations — minutes, not milliseconds.
# `setup:` runs per test, so building these per case would pay that price four
# times over for four assertions about the same document. They are built here
# instead, at module scope, and every suite below reads the documents they
# produced. A scenario that cannot be built raises before any test runs, which
# is the loud failure it should be: none of the assertions mean anything
# against a document the verb refused to write.
# ---------------------------------------------------------------------------

type
  Scenario = object
    root: string          ## the scratch tree holding consumer and sibling
    checkout: string      ## the develop checkout the override points at
    metadataPath: string  ## the document the verb reported writing

proc scenario(label: string; lockedPackages: openArray[LockedPackage];
              recipe: string; versionFile = ""): Scenario =
  result.root = scratchRoot(label)
  writeConsumer(result.root / "app", lockedPackages)
  result.checkout = writeSibling(result.root, recipe, versionFile)
  result.metadataPath = developInto(result.root / "app", result.checkout)

let
  lockedSibling = scenario("locked", @[
      LockedPackage(name: DevelopedPackage, version: LockedVersion,
                    source: DevelopedPackage),
      LockedPackage(name: "zlib", version: "1.2.13", source: "zlib")],
    SiblingRecipeWithoutVariants)
    ## The ordinary case: the consumer's lock names the dependency, so the
    ## engine knows the identity the override replaces. NO `VERSION` file, so
    ## a version reaching the solve can only have come off the entry.

  unlockedSibling = scenario("unlocked", NoPackages,
    SiblingRecipeWithoutVariants)
    ## No committed lock and no `VERSION` file: the engine knows nothing and
    ## the consumer's chain runs to its end, which is a refusal.

  strangerLockSibling = scenario("stranger", @[
      LockedPackage(name: "zlib", version: "1.2.13", source: "zlib")],
    SiblingRecipeWithoutVariants, versionFile = CheckoutFileVersion)
    ## A lock that names somebody else. The engine still knows nothing about
    ## THIS dependency, and the checkout's `VERSION` file is what answers.

  variantSibling = scenario("variants", @[
      LockedPackage(name: DevelopedPackage, version: LockedVersion,
                    source: DevelopedPackage)],
    SiblingRecipe)
    ## A sibling whose recipe really declares variants.

  unaskableSibling = scenario("unaskable", NoPackages,
    SiblingRecipeVariantsButNoBuild)
    ## A sibling that declares a variant and cannot be asked about it.

addExitProc(proc () =
  for s in [lockedSibling, unlockedSibling, strangerLockSibling,
            variantSibling, unaskableSibling]:
    try: removeDir(s.root)
    except CatchableError: discard)

suite "the engine records the version the override replaced":
  ## `develop_sources.nim` source 1, and the first of its two KNOWN GAPs.

  test "the written document carries the version the lock solved":
    let entry = overrideEntry(lockedSibling.metadataPath)
    check entry["node"].getStr() == DevelopedPackage
    check entry["path"].getStr() == lockedSibling.checkout
    check entry.hasKey("version")
    check entry["version"].getStr() == LockedVersion

  test "the consumer reads back exactly what the engine wrote":
    # The round-trip, and the reason it is one case rather than two. The
    # checkout carries NO `VERSION` file, so the only way this version can
    # reach the solve is off the entry the writer produced — a writer and a
    # parser that each agreed with a fixture but not with each other would
    # fail here.
    check not fileExists(lockedSibling.checkout / "VERSION")
    withConsumerReading(lockedSibling.metadataPath):
      check solvedVersionOf(DevelopedPackage) == @[LockedVersion]

  test "and it is not a version the solver may choose":
    withConsumerReading(lockedSibling.metadataPath):
      discard solvedVersionOf(DevelopedPackage)
      # NLF-M2's own distinction: a recorded version is asserted, not searched.
      # Recording the right number and still handing it over as a one-element
      # universe would render identically and be a different answer.
      check "pinned: true" in currentSolverInputsFixture()

  test "only the replaced node's version is recorded":
    # The lock names two packages; the override replaces one. Recording the
    # other one's version against this entry would be a fabrication that
    # happens to be a real number, which is harder to notice than a synthetic
    # one.
    check overrideEntry(lockedSibling.metadataPath)["version"].getStr() !=
      "1.2.13"

suite "a version the engine does not know is not invented":
  ## NLF-M2 deliverable 4, one layer up. The defect the milestone removed was a
  ## synthesized version reaching the solve; a synthesized version reaching the
  ## OVERRIDE DOCUMENT is the same defect with better provenance, because the
  ## consumer trusts source 1 unconditionally.

  test "no committed lock means no recorded version":
    # Absent, not empty, not zero. `develop_sources` treats a present-but-empty
    # `version` as absent too, but writing one would say "we looked and the
    # answer is nothing", which is not what happened.
    check not overrideEntry(unlockedSibling.metadataPath).hasKey("version")

  test "a lock that does not name the dependency records nothing":
    check not overrideEntry(strangerLockSibling.metadataPath).hasKey("version")

  test "and the consumer's fallback chain still runs":
    withConsumerReading(strangerLockSibling.metadataPath):
      # Source 2 of `develop_sources`'s documented order. It can only be
      # reached because source 1 is absent, so this is also the negative
      # control for the case above.
      check solvedVersionOf(DevelopedPackage) == @[CheckoutFileVersion]

  test "and with neither source the refusal is still raised":
    withConsumerReading(unlockedSibling.metadataPath):
      expect EDevelopVersionUnknown:
        discard solvedVersionOf(DevelopedPackage)

suite "the engine records the sibling's variant declarations":
  ## `develop_sources.nim`'s second KNOWN GAP, and the premise
  ## `t_develop_sibling_variants_reach_the_solve` had to supply for itself.
  ## Here the declarations come out of a real sibling recipe.

  test "the premise: the sibling really declares two variants":
    # If the fixture stopped declaring them, every case below would be
    # asserting that a path nobody takes works.
    let recipe = readFile(variantSibling.checkout / "repro.nim")
    check "enableTls: variant bool = true" in recipe
    check "profile: variant string = \"release\"" in recipe

  test "the written document carries them, unqualified":
    let entry = overrideEntry(variantSibling.metadataPath)
    check entry.hasKey("variants")
    var byName = initTable[string, JsonNode]()
    for item in entry["variants"]:
      byName[item["name"].getStr()] = item
    # The names are the SIBLING's own. Qualification is the reader's job
    # (`qualifiedVariantName`); doing it here as well would produce
    # `libfoo.libfoo.enableTls` and reach nothing.
    check "enableTls" in byName
    check byName["enableTls"]["kind"].getStr() == "bool"
    check byName["enableTls"]["default"].getStr() == "true"
    check "profile" in byName
    check byName["profile"]["kind"].getStr() == "enum"
    check byName["profile"]["default"].getStr() == "release"
    check "release" in byName["profile"]["values"].to(seq[string])

  test "and they reach the solve through the real path":
    withConsumerReading(variantSibling.metadataPath):
      discard solvedVersionOf(DevelopedPackage)
      let fixture = currentSolverInputsFixture()
      # Writer -> file -> parser -> solver input, with nothing hand-written in
      # between. This is the premise
      # `t_develop_sibling_variants_reach_the_solve` supplies from a fixture,
      # made real.
      check ("variant " & TlsVariant) in fixture
      check ("variant " & ProfileVariant) in fixture

  test "and the solver assigns them":
    withConsumerReading(variantSibling.metadataPath):
      discard solvedVersionOf(DevelopedPackage)
      finalizeVariants()
      check hasSolverSolution()
      let solved = lastSolverSolution()
      check solved.variants[TlsVariant] == "true"
      check solved.variants[ProfileVariant] == "release"

  test "a sibling declaring none renders exactly as it always has":
    # The compatibility guard, and the reason landing this moves no
    # fingerprint: an override the engine can say nothing extra about is
    # byte-identical to what the writer produced before, which is the shape of
    # every override on disk today.
    #
    # "Declares none" and "could not be asked" are deliberately NOT
    # distinguished, and the honest reason is that the probe cannot
    # distinguish them either — a recipe with no variants emits no solver
    # inputs at all, which is the same `none` a failed provider compile
    # returns. Writing `"variants": []` for one of them would be a claim the
    # engine is not in a position to make.
    let entry = overrideEntry(unlockedSibling.metadataPath)
    check not entry.hasKey("variants")
    check not entry.hasKey("version")
    check entry.len == 2

  test "a recipe with no build: block cannot be asked, and that is recorded here":
    # The KNOWN LIMITATION, pinned as an observed fact rather than left for
    # somebody to discover. `buildCode` emits the provider's protocol entry
    # point only for a recipe with a `build:` (or `devEnv:`) body, so a recipe
    # without one compiles to a binary that runs its module init and exits
    # without answering — and the probe reports nothing, exactly as it would
    # for a provider that failed to compile.
    #
    # The premise first, so this cannot silently become a test of something
    # else: the recipe really does declare a variant.
    check "enableTls: variant bool = true" in
      readFile(unaskableSibling.checkout / "repro.nim")
    check not overrideEntry(unaskableSibling.metadataPath).hasKey("variants")

suite "an override document written before this change still loads":
  ## Every override on disk today carries `node` and `path` and nothing else.
  ## The consumer already handles that; this says the change did not quietly
  ## make the old shape unreadable, and that a re-registration does not eat
  ## what a newer document already carried.

  test "a node-and-path-only document still reaches the solve":
    let metadataPath = strangerLockSibling.root / "legacy-overrides.json"
    writeFile(metadataPath, $(%*{
      "schemaId": "reprobuild.develop-overrides.v1",
      "projectRoot": strangerLockSibling.root / "app",
      "overrides": [{"node": DevelopedPackage,
                     "path": strangerLockSibling.checkout}]}))
    withConsumerReading(metadataPath):
      check solvedVersionOf(DevelopedPackage) == @[CheckoutFileVersion]
      check "variant " notin currentSolverInputsFixture()

  test "re-registering a dependency does not drop what was recorded":
    # `upsertDevelopOverride` READS the document, edits it and writes the whole
    # thing back. A reader that forgot the two new fields would silently strip
    # them from every entry it did not touch — a regression with no diagnostic,
    # visible only as the version fallback mysteriously firing again.
    let before = overrideEntry(variantSibling.metadataPath)
    check before.hasKey("version")
    check before.hasKey("variants")
    # Second registration of the SAME dependency at the same path: the entry is
    # rewritten, so this is also the case that proves the refresh is
    # idempotent rather than merely non-destructive.
    check developInto(variantSibling.root / "app",
                      variantSibling.checkout) == variantSibling.metadataPath
    let after = overrideEntry(variantSibling.metadataPath)
    check after["version"] == before["version"]
    check after["variants"] == before["variants"]
