## The plan's rustc edges keep their isolation through the CLI's lowering
## and the lowered-graph cache, and their keys do not depend on the recipe.
##
## THE CONTRACT. The Rust convention emits each edge of cargo's plan as an
## action launched from its declared environment alone
## (`isolateHostEnvironment`). `repro build` lowers the emitted fragment
## (`lowerProviderSnapshot`) and caches the lowered actions
## (`encodeLoweredAction`, the lowered-graph cache's codec). Both must carry
## the flag, or a warm or cold build hands the edge the engine's own
## environment. An isolated edge's key covers its argv, working directory
## and complete declared environment; the recipe's revision is not part of
## what it computes, so editing or removing the project file leaves every
## edge's weak fingerprint unchanged (as for a relocatable edge).
##
## THE CASE. The crates.io workspace of `writeRegistryWorkspace`, emitted with
## the registry lift on, wrapped in a provider snapshot and lowered by the
## real `lowerProviderSnapshot`, each plan edge selected by its id:
##
## - every lowered plan edge is isolated, has the toolchain's `PATH` as its
##   only `PATH` and no `OUT_MIRROR`, and decodes from the lowered-graph
##   cache's codec with the flag intact;
## - the lowered actions build through the real engine and monitor and the
##   binary prints `util:5 51`;
## - with each payload's recipe revision replaced (another project file's
##   digest, and none at all, as without a project file), every lowered
##   edge's weak fingerprint is the same; the positive control: the same
##   edges not isolated are keyed on the revision.
##
## What this does not establish: that a lowered edge's weak fingerprint
## equals the one `planUnitEdges` gives its own engine action. They differ
## by construction: the lowering keys an inline edge on its whole payload and
## governs it by the workspace lock, the emitter's action on its id and
## outside any solved graph.
##
## Falsifying mutations (applied, observed to fail, reverted; see the
## change's report): not stamping the flag in `lowerGraphAction` fails the
## isolation check; dropping the flag's byte from the lowered-graph cache's
## codec fails the round trip; keying an isolated edge on its payload with
## the recipe revision in it fails the fingerprint comparison.
##
## MOCKS: none. The production emitter, lowering, cache codec, engine and
## monitor.

import std/[os, osproc, sequtils, strutils, tables, tempfiles, unittest]

import repro_build_engine
import repro_cli_support
import repro_tool_profiles
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/conventions/rust as rust_convention

import ./rqe_cg5_plan_fixture
import ./rqe_cg5_mode_a_support

proc snapshotOf(fragment: GraphFragment): ProviderGraphSnapshot =
  ProviderGraphSnapshot(providerArtifactId: "test-provider",
    fragments: @[StoredGraphFragment(
      providerArtifactId: "test-provider",
      entryPointId: fragment.entryPointId,
      entryPointBodyHash: fragment.entryPointBodyHash,
      arguments: fragment.arguments,
      namespace: fragment.namespace,
      fragmentDigest: fragment.fragmentDigest,
      nodes: fragment.nodes,
      edges: fragment.edges,
      evaluationInputs: fragment.evaluationInputs)])

proc lowerDefault(fragment: GraphFragment; ws: string): seq[BuildAction] =
  ## The lowered plan edges, each selected by its id. (Loops, not `filterIt`:
  ## `BuildAction` has no default value.)
  var selectors: seq[string]
  for def in actionDefs(fragment):
    if def.isPlanEdge: selectors.add def.id
  for a in lowerProviderSnapshot(snapshotOf(fragment), PathOnlyBuildIdentity(),
      ws, selectors).actions:
    if a.id.startsWith("cargo.rustc/"): result.add a

proc ids(actions: seq[BuildAction]): string =
  var names: seq[string]
  for a in actions: names.add a.id
  names.join(" ")

proc fingerprints(actions: seq[BuildAction]): Table[string, string] =
  for a in actions: result[a.id] = $a.weakFingerprint

proc withRevision(fragment: GraphFragment; revision: string;
                  isolated: bool): GraphFragment =
  ## `fragment` with every plan edge's recipe revision replaced and its
  ## isolation set as given.
  result = fragment
  for node in result.nodes.mitems:
    if node.kind != gnkAction: continue
    var bytes = newSeq[byte](node.payload.len)
    for i, c in node.payload: bytes[i] = byte(c)
    var def = decodeBuildActionPayload(bytes)
    if not def.isPlanEdge: continue
    def.recipeRevisionFingerprint = revision
    def.isolateHostEnvironment = isolated
    node.payload = actionPayload(def)

proc recipeRevisions(fragment: GraphFragment): seq[string] =
  for def in actionDefs(fragment):
    if def.isPlanEdge: result.add def.recipeRevisionFingerprint

suite "the plan's edges through the lowering":

  test "lowered plan edges stay isolated, survive the lowered-graph " &
      "cache and are keyed without the recipe":
    let work = createTempDir("cg5-lower-", "")
    defer: removeTestTree(work)
    let ws = work / "ws"
    writeRegistryWorkspace(ws)
    let reg = setupRegistry(work, smReal, withRegmid = true)
    lockWorkspace(ws, work, reg)
    let env = prepareModeAEnv(work, "cg5-lower")
    putEnv("REPRO_STORE_ROOT", reg.store)
    putEnv(ModeARegistrySwitch, "on")
    defer: delEnv(ModeARegistrySwitch)

    let fragment = emitWorkspace(ws)
    let lowered = lowerDefault(fragment, ws)
    checkpoint "lowered: " & ids(lowered)
    check lowered.len == 5
    for a in lowered:
      checkpoint a.id
      check a.isolateHostEnvironment
      check a.env.filterIt(it.startsWith("PATH=")).len == 1
      check not a.env.anyIt(it.startsWith("OUT_MIRROR="))
      let cached = decodeLoweredAction(encodeLoweredAction(a))
      check cached.isolateHostEnvironment
      check cached.env == a.env
      check $cached.weakFingerprint == $a.weakFingerprint

    let run = runBuild(graph(lowered), engineConfig(env, work / "cache"))
    for r in run.results:
      checkpoint r.id & ": " & $r.status & " " & r.reason &
        (if r.stderr.len > 0: "\nstderr: " & r.stderr else: "")
      check r.status == asSucceeded
    var app = ""
    for a in lowered:
      if "bin" in a.argv and a.id.startsWith("cargo.rustc/app@"):
        for o in a.outputs:
          if extractFilename(o).startsWith("app-"): app = o
    require app.len > 0
    check execProcess(app, options = {}).strip() == "util:5 51"

    # The recipe's revision, as an edited project file (another digest) and
    # as no project file at all (none), in otherwise identical payloads. (A
    # payload is rewritten here rather than the file edited: the DSL caches
    # a project's revision for the life of the process.)
    let before = fingerprints(lowered)
    check recipeRevisions(fragment).allIt(it.len > 0)
    for revision in ["0".repeat(64), ""]:
      checkpoint "revision " & revision.escape()
      check fingerprints(lowerDefault(
        withRevision(fragment, revision, isolated = true), ws)) == before
      # The positive control: the same edges, not isolated, are keyed on the
      # revision.
      check fingerprints(lowerDefault(
          withRevision(fragment, revision, isolated = false), ws)) !=
        fingerprints(lowerDefault(withRevision(fragment,
          recipeRevisions(fragment)[0], isolated = false), ws))
