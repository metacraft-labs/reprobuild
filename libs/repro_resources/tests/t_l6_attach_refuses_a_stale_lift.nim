## Shared-Development-Services §4.3's SAME-GENERATION PRECONDITION —
## "THE DECISION'S INPUTS MUST BE SAME-GENERATION, AND A STALE LIFT IS A
## REFUSAL RATHER THAN A SILENT ATTACH."
##
## The clause this file is the gate for, verbatim (spec `8429bcf`):
##
##   Before comparing, establish that the owner's artifact corresponds to
##   the owner's current definition. If it cannot be established -- the
##   artifact is older than the definition, or its provenance is unknown
##   -- the decision **refuses and says the lift is stale**, naming what
##   to re-run. It does not fall through to "fingerprint equal".
##
##   A refusal here is cheap and self-correcting: the remedy is
##   re-lifting, which the owner can always do. A silent attach is
##   neither -- it hands the consumer a handle built against a definition
##   nobody is running.
##
## § MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED
##
## Every value that decides anything here is produced by the production
## code path that produces it in a real run:
##
##   * the service snapshots come from real `package` blocks in
##     `l6_attach_fixtures.nim`, expanded by the real DSL macro and
##     lifted by the real `toProjectInterface` -- the same projection
##     `t_l6_attach_decision_has_three_outcomes.nim` uses;
##   * the PROVENANCE STAMPS are written by the real
##     `writeInterfaceArtifactProvenance` and read back by the real
##     `readInterfaceArtifactProvenance`, to and from real files on a
##     real filesystem under a throwaway root;
##   * the OWNER'S DEFINITION is a real `.nim` recipe written to disk,
##     importing a real sibling module, and the closure is walked by the
##     real `discoverNimSources` and digested by the real
##     `projectSourceSemanticIdentity`;
##   * the three-state answer is established by the real
##     `ownerArtifactGeneration` -- the exact proc `repro up`'s resolver
##     calls -- and the decision is the real `attachDecision`.
##
## Nothing is stubbed, no filesystem probe is replaced, and the recipes
## are never a live `.repro/` tree.
##
## § WHAT IS NOT MEASURED HERE, SAID RATHER THAN IMPLIED
##
## `ownerArtifactGeneration` takes the provenance stamp and reads the
## owner's recipe; it does NOT read the artifact's bytes. So this file does not
## need a compiled lift to measure the decision, and it does not pretend
## to: whether the LIFT writes the stamp in the first place is a
## different claim, measured in
## `t_interface_artifact_provenance_is_recorded_by_the_lift.nim` by
## driving the real `liftInterfaceArtifact` over a real recipe.
##
## § THE ONE CASE THAT IS THE WHOLE POINT
##
## "the motivating case" below reproduces the defect the clause was
## written from (measured at reprobuild `db5745947`): the owner's
## definition has changed, its artifact has NOT been re-lifted, and the
## fingerprint the decision would compare has therefore not moved. It
## asserts BOTH answers against the SAME two snapshots:
##
##   * with the generation CLAIMED fresh -> `saoAttachSilently`, the row
##     that says nothing. That is the old behaviour, reproduced, and it
##     is this file's positive control: it proves the fingerprint
##     comparison really does agree, so the refusal below cannot be
##     coming from some incidental difference.
##   * with the generation ESTABLISHED from disk -> `saoRefuseStaleLift`.
##
## One pair of snapshots, two generations, two answers. The precondition
## is the only variable.

import std/[os, strutils, unittest]

import repro_cli_support
import repro_interface_artifacts
import repro_project_dsl
import repro_resources/service_attach
import repro_resources/service_identity
import repro_resources/service_registry

import ./l6_attach_fixtures

# ---------------------------------------------------------------------------
# Snapshots, from the real lift. Same four projections
# `t_l6_attach_decision_has_three_outcomes.nim` uses, and duplicated for
# the reason that file's sibling gives: they are private there.
# ---------------------------------------------------------------------------

proc packageDefNamed(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError,
    "fixture drift: no package named " & name & " is registered")

proc normalisedInterface(name: string): ProjectInterface =
  result = toProjectInterface(packageDefNamed(name))
  for act in result.publicActivities.mitems:
    act.handleType = "NormalisedHandle_" & act.name
  for svc in result.publicServices.mitems:
    if svc.handleType.len > 0:
      svc.handleType = "NormalisedHandle_" & svc.activityName

proc snapshotOf(package: string; service = "zitadel"):
    ServiceInterfaceSnapshot =
  serviceInterfaceSnapshot(normalisedInterface(package), service)

proc runningFrom(package: string; service = "zitadel"):
    RunningServiceInstance =
  ## A running instance whose definition is `package`'s. The key is
  ## constructed rather than resolved: this file measures §4.3's
  ## precondition, and L4's identity resolution is measured in its own
  ## file. The key never reaches the decision -- `attachDecision` reads
  ## only `interfaceSnapshot` -- so nothing here turns on it.
  runningServiceInstance(
    ServiceInstanceKey(identityKind: sikStable,
      identity: "com.example.l6.sso", scope: sscWorkspace,
      scopeKey: "stale-lift-suite", environment: "", degradation: ""),
    snapshotOf(package, service), [])

# ---------------------------------------------------------------------------
# A REAL owner project on disk: a recipe, a module it imports, and a
# provenance stamp recorded beside an artifact path.
#
# The scratch root is per-process and per-case, never a module-level
# constant -- the runner executes each case as its own process and runs
# cases of one binary concurrently.
# ---------------------------------------------------------------------------

const
  OwnerRecipeV1 = """
import ./shared_helper

const ownerPort* = 8080
"""
  OwnerRecipeV2 = """
import ./shared_helper

const ownerPort* = 9090
"""
  OwnerRecipeV3 = """
import ./shared_helper
import ./shared_second

const ownerPort* = 8080
"""
  HelperV1 = """
const helperName* = "one"
"""
  HelperV2 = """
const helperName* = "two"
"""
  SecondHelper = """
const secondName* = "second"
"""

type OwnerTree = object
  root: string
  recipe: string
  artifact: string

proc newOwnerTree(tag: string): OwnerTree =
  let root = getTempDir() / ("repro-sds-stale-" & $getCurrentProcessId() &
    "-" & tag)
  removeDir(root)
  createDir(root)
  result = OwnerTree(root: root, recipe: root / "repro.nim",
    artifact: root / ".repro" / "dev-env" / "default" /
      "project-interface.rbsz")
  createDir(parentDir(result.artifact))
  writeFile(result.recipe, OwnerRecipeV1)
  writeFile(root / "shared_helper.nim", HelperV1)

proc liftIt(tree: OwnerTree) =
  ## Stand in for the moment the lift PUBLISHES the artifact: write the
  ## artifact's placeholder bytes and record the provenance stamp with
  ## the real writer. `ownerArtifactGeneration` never reads the artifact
  ## bytes (only the stamp and the recipe), which is why a placeholder
  ## is honest here and not a shortcut -- see this file's header.
  writeFile(tree.artifact, "project-interface bytes for " & tree.root)
  writeInterfaceArtifactProvenance(tree.artifact, tree.recipe)

proc establish(tree: OwnerTree): ServiceArtifactGenerationCheck =
  ## The stamp is read here, as `repro up` reads it (beside the artifact,
  ## in one read with it), and handed to the check.
  ownerArtifactGeneration(tree.artifact,
    readInterfaceArtifactProvenance(tree.artifact), tree.root, "l6AttBase",
    "l6AttBase")

# ---------------------------------------------------------------------------

suite "Shared-Development-Services §4.3 — a stale lift is a refusal":

  test "the motivating case: the definition moved, the artifact did not":
    ## §4.3's measured hole, reproduced and then closed. ONE pair of
    ## snapshots; the generation is the only variable.
    let tree = newOwnerTree("motivating")
    defer: removeDir(tree.root)
    liftIt(tree)
    check establish(tree).generation == sagFresh

    # The owner edits its definition and does NOT re-lift.
    writeFile(tree.recipe, OwnerRecipeV2)
    let established = establish(tree)
    check established.generation == sagStale
    check established.recordedIdentity.len == 64
    check established.currentIdentity.len == 64
    check established.recordedIdentity != established.currentIdentity

    # Both sides of §4.3's comparison are the SAME definition, so the
    # fingerprints agree and the table alone selects row 1.
    let running = runningFrom("l6AttBase")
    let requested = snapshotOf("l6AttBase")
    check running.interfaceSnapshot.fingerprint == requested.fingerprint

    # THE POSITIVE CONTROL: claim the generation fresh and the decision
    # is the row that says nothing -- the behaviour measured at
    # reprobuild db5745947.
    let claimed = attachDecision(running, requested,
      freshLiftGeneration(tree.artifact, "l6AttBase", "l6AttBase",
        established.currentIdentity))
    check claimed.outcome == saoAttachSilently
    check claimed.diagnostic == ""

    # AND THE PRECONDITION: establish it from disk instead, and the same
    # pair refuses.
    let decision = attachDecision(running, requested, established)
    check decision.outcome == saoRefuseStaleLift
    check decision.generation == sagStale
    check decision.diagnostic.len > 0

  test "the stale refusal names WHAT TO RE-RUN, and names the artifact":
    ## §4.3 requires the refusal to name the remedy. Asserted on the
    ## MESSAGE, not only on the outcome: an outcome nobody can act on is
    ## the refusal half of this clause without its useful half.
    let tree = newOwnerTree("remedy")
    defer: removeDir(tree.root)
    liftIt(tree)
    writeFile(tree.recipe, OwnerRecipeV2)
    let decision = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttBase"), establish(tree))
    check decision.outcome == saoRefuseStaleLift
    check decision.diagnostic.contains("THE LIFT IS STALE")
    check decision.diagnostic.contains("repro dev-env")
    check decision.diagnostic.contains("l6AttBase")
    check decision.diagnostic.contains(tree.artifact)
    check decision.diagnostic.contains(
      "Shared-Development-Services.md §4.3")
    # The source that moved is NAMED, so the author is not left to guess
    # which of the closure's files is responsible.
    check decision.diagnostic.contains("repro.nim (edited)")

  test "a change to a module the recipe IMPORTS is a stale lift too":
    ## The property a recipe-FILE check could not have. The recipe's own
    ## bytes are untouched; only the module it imports moves. This is
    ## also the case `repro_dev_env_engine`'s own `devEnvCacheKey` cannot
    ## see -- its `projectFile=` part fingerprints the recipe file alone
    ## -- which is why the owner establishes its generation rather than
    ## asserting it.
    let tree = newOwnerTree("imported")
    defer: removeDir(tree.root)
    liftIt(tree)
    let before = readFile(tree.recipe)
    writeFile(tree.root / "shared_helper.nim", HelperV2)
    check readFile(tree.recipe) == before
    let established = establish(tree)
    check established.generation == sagStale
    check established.movedSources.len == 1
    check established.movedSources[0].contains("shared_helper.nim")
    check established.movedSources[0].contains("(edited)")
    check attachDecision(runningFrom("l6AttBase"), snapshotOf("l6AttBase"),
      established).outcome == saoRefuseStaleLift

  test "establishing a generation does NOT re-stamp, so staleness does not launder":
    ## THE RULE THIS KILLS, stated as a defect rather than a preference:
    ## a reader that re-stamped the artifact while establishing its
    ## generation would answer `sagStale` ONCE and `sagFresh` for ever
    ## after, because the stamp it wrote records the CURRENT closure
    ## against the OLD artifact. The staleness would be laundered on
    ## disk, and the next `repro up` would attach silently -- which is
    ## exactly the defect section 4.3's precondition exists to prevent,
    ## re-introduced by the freshness check itself.
    ##
    ## That prohibition was prose-only in three comments and nothing
    ## mechanical enforced it: a mutation adding the re-stamp survived a
    ## full run of this file. Establishing three times is the assertion
    ## that converts it into a control.
    let tree = newOwnerTree("nolaunder")
    defer: removeDir(tree.root)
    liftIt(tree)
    writeFile(tree.root / "shared_helper.nim", HelperV2)
    let first = establish(tree)
    let second = establish(tree)
    let third = establish(tree)
    check first.generation == sagStale
    check second.generation == sagStale
    check third.generation == sagStale
    ## And the artifact must still refuse, not merely report: a reader
    ## that laundered the stamp would pass this line while failing the
    ## three above, so assert the decision too.
    check attachDecision(runningFrom("l6AttBase"), snapshotOf("l6AttBase"),
      third).outcome == saoRefuseStaleLift

  test "an ADDED import grows the closure, and that is a stale lift":
    ## The membership case. A check that re-hashed only the files the
    ## record NAMES would be blind to it, which is why the closure is
    ## re-discovered.
    let tree = newOwnerTree("added")
    defer: removeDir(tree.root)
    liftIt(tree)
    writeFile(tree.root / "shared_second.nim", SecondHelper)
    writeFile(tree.recipe, OwnerRecipeV3)
    let established = establish(tree)
    check established.generation == sagStale
    var namedAdded = false
    for moved in established.movedSources:
      if moved.contains("shared_second.nim") and moved.contains("(added)"):
        namedAdded = true
    check namedAdded

  test "a REMOVED import shrinks the closure, and that is a stale lift":
    let tree = newOwnerTree("removed")
    defer: removeDir(tree.root)
    writeFile(tree.root / "shared_second.nim", SecondHelper)
    writeFile(tree.recipe, OwnerRecipeV3)
    liftIt(tree)
    check establish(tree).generation == sagFresh
    writeFile(tree.recipe, OwnerRecipeV1)
    let established = establish(tree)
    check established.generation == sagStale
    var namedRemoved = false
    for moved in established.movedSources:
      if moved.contains("shared_second.nim") and moved.contains("(removed)"):
        namedRemoved = true
    check namedRemoved

  test "UNKNOWN provenance refuses, with a DISTINGUISHABLE message":
    ## §4.3's second failure mode, and the one this campaign's dominant
    ## defect class would have folded into "fresh". A separate outcome
    ## and a separate sentence, both asserted, because "stale" and
    ## "nothing recorded" have different remedies.
    let tree = newOwnerTree("unknown")
    defer: removeDir(tree.root)
    writeFile(tree.artifact, "an artifact nobody recorded")
    let established = establish(tree)
    check established.generation == sagUnknownProvenance
    check established.recordedIdentity == ""
    check established.detail.contains("No readable provenance record")
    let decision = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttBase"), established)
    check decision.outcome == saoRefuseUnknownProvenance
    check decision.generation == sagUnknownProvenance
    check decision.diagnostic.contains("cannot be shown to correspond")
    check decision.diagnostic.contains("repro dev-env")
    check decision.diagnostic.contains("l6AttBase")
    # DISTINGUISHABLE from the stale refusal, in both directions.
    check not decision.diagnostic.contains("THE LIFT IS STALE")
    liftIt(tree)
    writeFile(tree.recipe, OwnerRecipeV2)
    let stale = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttBase"), establish(tree))
    check stale.outcome == saoRefuseStaleLift
    check not stale.diagnostic.contains("cannot be shown to correspond")

  test "a FRESH artifact compares normally, and all three rows still hold":
    ## §4.3's table, decided under a generation ESTABLISHED FROM DISK
    ## rather than asserted. `t_l6_attach_decision_has_three_outcomes.nim`
    ## ranges over the whole fixture set with a constructed `sagFresh`;
    ## this is the same three rows with the real establishment in front
    ## of them, which is what says the precondition does not swallow the
    ## comparison.
    let tree = newOwnerTree("fresh")
    defer: removeDir(tree.root)
    liftIt(tree)
    let fresh = establish(tree)
    check fresh.generation == sagFresh

    # Row 1: a different IMPLEMENTATION, same interface -> silent.
    let row1 = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttOtherImpl"), fresh)
    check row1.outcome == saoAttachSilently
    check row1.diagnostic == ""
    check row1.generation == sagFresh

    # Row 2: one added `config:` key -> attach, and warn, naming it.
    let row2 = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttAddedKey"), fresh)
    check row2.outcome == saoAttachWithWarning
    check row2.differences.len > 0
    check row2.diagnostic.contains("Differing members")

    # Row 3: a differing MAJOR -> refuse.
    let row3 = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttOtherMajor"), fresh)
    check row3.outcome == saoRefuseMajor
    check row3.diagnostic.contains("MAJOR compatibility field")

  test "the precondition is tested BEFORE the major, and before the diff":
    ## §4.3: "Before comparing". A stale artifact whose major ALSO
    ## differs refuses as STALE, not as a major mismatch -- because the
    ## major is read off the very snapshot whose freshness is in
    ## question, so deciding the hardest outcome from it would be
    ## deciding from a value two generations old.
    let tree = newOwnerTree("ordering")
    defer: removeDir(tree.root)
    liftIt(tree)
    writeFile(tree.recipe, OwnerRecipeV2)
    let established = establish(tree)
    let decision = attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttOtherMajor"), established)
    check decision.outcome == saoRefuseStaleLift
    check not decision.diagnostic.contains("MAJOR compatibility field")
    # And `differences` is EMPTY on a precondition refusal: a member
    # list diffed against an untrustworthy snapshot is a list that may
    # not exist.
    check decision.differences.len == 0
    # The same pair, decided fresh, DOES reach the major refusal -- so
    # the assertion above is about ORDER and not about the major check
    # having stopped working.
    check attachDecision(runningFrom("l6AttBase"),
      snapshotOf("l6AttOtherMajor"),
      freshLiftGeneration(tree.artifact, "l6AttBase", "l6AttBase",
        "x")).outcome == saoRefuseMajor

  test "omitting the generation is a COMPILE ERROR, not a silent fresh":
    ## A STRUCTURAL guarantee rather than an assertion: there is no
    ## two-argument `attachDecision`, so a call site that forgets §4.3's
    ## precondition does not compile. This is the near-miss probe for
    ## the surface this change adds -- the campaign's standing hunt is
    ## for constructs that look wired and are silently dropped, and a
    ## defaulted parameter is the commonest way that happens.
    let running = runningFrom("l6AttBase")
    let requested = snapshotOf("l6AttBase")
    check not compiles(attachDecision(running, requested))
    check compiles(attachDecision(running, requested,
      freshLiftGeneration("", "", "", "")))

  test "sagUnknownProvenance is the ZERO value of the generation enum":
    ## So a default-constructed check, or one decoded from a wire body
    ## that carried no answer, means REFUSE. Asserted rather than
    ## described, because the ordinal is what a zeroed record gets and a
    ## comment cannot hold it in place.
    check ord(sagUnknownProvenance) == 0
    check ServiceArtifactGenerationCheck().generation ==
      sagUnknownProvenance
    check attachDecision(runningFrom("l6AttBase"), snapshotOf("l6AttBase"),
      ServiceArtifactGenerationCheck()).outcome ==
      saoRefuseUnknownProvenance

  test "a malformed or alien provenance record is UNKNOWN, never fresh":
    ## Every way the stamp can fail to be understood, probed. Each must
    ## answer `sagUnknownProvenance`; none may answer `sagFresh`, and
    ## none may answer `sagStale` either -- a wrong schema is not
    ## evidence about the definition's age.
    let tree = newOwnerTree("malformed")
    defer: removeDir(tree.root)
    liftIt(tree)
    let stampPath = interfaceArtifactProvenancePath(tree.artifact)
    let good = readFile(stampPath)
    check establish(tree).generation == sagFresh

    var probes: seq[(string, string)] = @[]
    probes.add(("an empty file", ""))
    probes.add(("a wrong schema line",
      good.replace(InterfaceProvenanceSchemaId,
        "reprobuild.interface-provenance.v2")))
    probes.add(("an unknown key", good & "surprise yes\n"))
    probes.add(("no closure identity",
      good.replace("closure-identity", "closure-identityx")))
    probes.add(("a key with no value", good & "recipe\n"))
    probes.add(("a duplicated recipe key", good & "recipe other.nim\n"))
    probes.add(("a non-boolean sibling-sources", good.replace(
      "sibling-sources 0", "sibling-sources maybe")))
    probes.add(("a malformed source row", good & "source onlyonefield\n"))
    for probe in probes:
      writeFile(stampPath, probe[1])
      let answer = establish(tree)
      check answer.generation == sagUnknownProvenance
      if answer.generation != sagUnknownProvenance:
        echo "PROBE NOT REFUSED: ", probe[0], " -> ", answer.generation
      check attachDecision(runningFrom("l6AttBase"),
        snapshotOf("l6AttBase"), answer).outcome ==
        saoRefuseUnknownProvenance
    # The probe set is not empty, and the arithmetic is asserted rather
    # than trusted: a loop over an accidentally empty sequence passes.
    check probes.len == 8

  test "a recipe the record names but that is gone is UNKNOWN, not stale":
    ## The record is readable and the definition is not. "Older than the
    ## definition" is not the right answer when there is no definition
    ## to be older than, and the remedy differs -- so it is the unknown
    ## refusal, with its own sentence.
    let tree = newOwnerTree("gonerecipe")
    defer: removeDir(tree.root)
    liftIt(tree)
    removeFile(tree.recipe)
    let established = establish(tree)
    check established.generation == sagUnknownProvenance
    check established.detail.contains("no such file")
    check established.detail.contains("repro.nim")

  test "the generation travels the daemon wire, and an absent field refuses":
    ## The codec half. §4.3's answer is established by the CLIENT and
    ## decided by the DAEMON, so a wire default of "fresh" would delete
    ## the precondition on a client/daemon revision skew.
    let tree = newOwnerTree("wire")
    defer: removeDir(tree.root)
    liftIt(tree)
    writeFile(tree.recipe, OwnerRecipeV2)
    let established = establish(tree)
    let roundTripped = decodeServiceArtifactGenerationCheck(
      encodeServiceArtifactGenerationCheck(established))
    check roundTripped.generation == sagStale
    check roundTripped.recordedIdentity == established.recordedIdentity
    check roundTripped.currentIdentity == established.currentIdentity
    check roundTripped.movedSources == established.movedSources
    check roundTripped.artifactPath == established.artifactPath

    # A fresh answer survives too, so the refusals above are not an
    # artefact of the codec losing everything.
    let freshTrip = decodeServiceArtifactGenerationCheck(
      encodeServiceArtifactGenerationCheck(
        freshLiftGeneration("a", "b", "c", "d")))
    check freshTrip.generation == sagFresh

    # AND THE DEFAULTS. Each of these is what a daemon reads when the
    # client did not send the field, or sent one it cannot read.
    for text in ["", "not json at all", "[1,2,3]",
                 """{"generation":"sagSomethingElse"}""",
                 """{"generation":""}""", "{}"]:
      let decoded = decodeServiceArtifactGenerationCheck(text)
      check decoded.generation == sagUnknownProvenance
      check decoded.detail.len > 0
