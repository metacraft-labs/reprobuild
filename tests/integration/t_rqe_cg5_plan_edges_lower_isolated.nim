## The isolated graph-production edges of a workspace built from cargo's
## plan keep their isolation through the CLI's lowering and the lowered-graph
## cache, and their keys do not depend on the recipe.
##
## THE CONTRACT. The Rust convention declares the plan edge and the units
## edge as actions launched from their declared environment alone
## (`isolateHostEnvironment`). `repro build` lowers the emitted fragment
## (`lowerProviderSnapshot`) and caches the lowered actions
## (`encodeLoweredAction`, the lowered-graph cache's codec). Both must carry
## the flag, or a warm or cold build hands the edge the engine's own
## environment, and the host's cargo steering reaches the plan. An isolated
## edge's key covers its argv, working directory and complete declared
## environment; the recipe's revision is not part of what it computes, so
## editing or removing the project file leaves every such edge's weak
## fingerprint unchanged. (The unit edges are not lowered: the units edge's
## fragment creates them, with `planUnitEdges`' keys,
## `test_rqe_cg5_plan_unit_key_equals_created_key`.)
##
## THE CASE. The crates.io workspace of `writeRegistryWorkspace`, emitted with
## the registry lift on, wrapped in a provider snapshot and lowered by the
## real `lowerProviderSnapshot`, each isolated edge selected by its id:
##
## - each lowered edge is isolated, the plan edge has the toolchain's `PATH`
##   as its only `PATH`, neither has `OUT_MIRROR`, and each decodes from the
##   lowered-graph cache's codec with the flag intact;
## - with each payload's recipe revision replaced (another project file's
##   digest, and none at all, as without a project file), every lowered
##   edge's weak fingerprint is the same; the positive control: the same
##   edges not isolated (and the plan edge not relocatable) are keyed on the
##   revision.
##
## Falsifying mutations (applied, observed to fail, reverted; see the
## change's report): not stamping the flag in `lowerGraphAction` fails the
## isolation check; dropping the flag's byte from the lowered-graph cache's
## codec fails the round trip; keying an isolated edge on its payload with
## the recipe revision in it fails the fingerprint comparison.
##
## MOCKS: none. The production emitter, lowering and cache codec.

import std/[os, sequtils, strutils, tables, tempfiles, unittest]

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

proc isIsolatedEdge(id: string): bool =
  id.startsWith("cargo.plan/") or id.startsWith("cargo.plan-units/")

proc lowerDefault(fragment: GraphFragment; ws: string): seq[BuildAction] =
  ## The lowered isolated edges, each selected by its id. (Loops, not
  ## `filterIt`: `BuildAction` has no default value.)
  var selectors: seq[string]
  for def in actionDefs(fragment):
    if def.id.isIsolatedEdge: selectors.add def.id
  for a in lowerProviderSnapshot(snapshotOf(fragment), PathOnlyBuildIdentity(),
      ws, selectors).actions:
    if a.id.isIsolatedEdge: result.add a

proc ids(actions: seq[BuildAction]): string =
  var names: seq[string]
  for a in actions: names.add a.id
  names.join(" ")

proc fingerprints(actions: seq[BuildAction]): Table[string, string] =
  for a in actions: result[a.id] = $a.weakFingerprint

proc withRevision(fragment: GraphFragment; revision: string;
                  isolated: bool): GraphFragment =
  ## `fragment` with every isolated edge's recipe revision replaced and its
  ## isolation (and the plan edge's relocation) set as given.
  result = fragment
  for node in result.nodes.mitems:
    if node.kind != gnkAction: continue
    var bytes = newSeq[byte](node.payload.len)
    for i, c in node.payload: bytes[i] = byte(c)
    var def = decodeBuildActionPayload(bytes)
    if not def.id.isIsolatedEdge: continue
    def.recipeRevisionFingerprint = revision
    def.isolateHostEnvironment = isolated
    # Only the plan edge is declared relocatable (the units edge's argv
    # names the checkout); the control takes that away with the isolation.
    if def.id.startsWith("cargo.plan/"): def.relocatable = isolated
    node.payload = actionPayload(def)

proc recipeRevisions(fragment: GraphFragment): seq[string] =
  for def in actionDefs(fragment):
    if def.id.isIsolatedEdge: result.add def.recipeRevisionFingerprint

suite "the plan's edges through the lowering":

  test "lowered isolated edges stay isolated, survive the lowered-graph " &
      "cache and are keyed without the recipe":
    let work = createTempDir("cg5-lower-", "")
    defer: removeTestTree(work)
    let ws = work / "ws"
    writeRegistryWorkspace(ws)
    let reg = setupRegistry(work, smReal, withRegmid = true)
    lockWorkspace(ws, work, reg)
    discard prepareModeAEnv(work, "cg5-lower")
    putEnv("REPRO_STORE_ROOT", reg.store)
    putEnv(ModeARegistrySwitch, "on")
    defer: delEnv(ModeARegistrySwitch)

    let fragment = emitWorkspace(ws)
    let lowered = lowerDefault(fragment, ws)
    checkpoint "lowered: " & ids(lowered)
    check lowered.len == 2
    for a in lowered:
      checkpoint a.id
      check a.isolateHostEnvironment
      if a.id.startsWith("cargo.plan/"):
        check a.env.filterIt(it.startsWith("PATH=")).len == 1
      check not a.env.anyIt(it.startsWith("OUT_MIRROR="))
      let cached = decodeLoweredAction(encodeLoweredAction(a))
      check cached.isolateHostEnvironment
      check cached.env == a.env
      check $cached.weakFingerprint == $a.weakFingerprint

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
