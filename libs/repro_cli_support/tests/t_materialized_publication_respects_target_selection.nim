## Materialized binary-cache publication must honor the requested build target.
## The operation may omit untagged dependencies because it never launches an
## action, but it must not publish tagged actions outside the selected closure.

import std/[options, unittest]

import repro_binary_cache_client/cache_key
import repro_binary_cache_server/types as bcsTypes
import repro_build_engine
import repro_cli_support
import repro_project_dsl
import repro_provider_runtime

proc cacheIdentity(name: string): CacheEntryIdentity =
  newCacheEntryIdentity(
    packageName = name,
    packageVersion = "1.0",
    platform = bcsTypes.PlatformTriple(
      cpu: "x86_64", os: "linux", abi: "gnu", libcVariant: "glibc"),
    toolchain = bcsTypes.ToolchainIdentity(
      name: "fixture", version: "1", hostLdSoAbi: "",
      extraFingerprint: ""),
    providerRevision = "fixture-revision")

proc actionNode(id: string; deps: seq[string]; publish: bool): GraphNode =
  let action = BuildActionDef(
    id: id,
    call: publicCliCall("reprobuild.builtin", "fs", "writeText",
      "fixture.writeText", @[]),
    deps: deps,
    outputs: @["build/" & id & ".txt"],
    declaredOutputs: @["build/" & id & ".txt"],
    cacheable: true,
    dependencyPolicy: defaultDependencyPolicy(),
    actionCachePolicy: defaultActionCachePolicy(),
    publishToBinaryCache: publish,
    cacheEntryIdentity:
      if publish: some(cacheIdentity(id))
      else: none(CacheEntryIdentity))
  GraphNode(
    id: "fixture:action:" & id,
    kind: gnkAction,
    stableName: id,
    payload: actionPayload(action))

proc targetNode(name: string; actions: seq[string]): GraphNode =
  GraphNode(
    id: "fixture:target:" & name,
    kind: gnkMetadata,
    stableName: "reprobuild.build-target.v1",
    payload: targetPayload(BuildTargetDef(
      name: name,
      kind: btkAggregate,
      actions: actions)))

proc fixtureSnapshot(): ProviderGraphSnapshot =
  ProviderGraphSnapshot(fragments: @[StoredGraphFragment(
    namespace: "fixture",
    nodes: @[
      actionNode("prepare-a", @[], false),
      actionNode("publish-a", @["prepare-a"], true),
      actionNode("prepare-b", @[], false),
      actionNode("publish-b", @["prepare-b"], true),
      actionNode("prepare-only", @[], false),
      targetNode("selected", @["prepare-a", "publish-a"]),
      targetNode("other", @["prepare-b", "publish-b"]),
      targetNode("untagged", @["prepare-only"]),
    ]
  )])

proc actionIds(actions: openArray[BuildAction]): seq[string] =
  for action in actions:
    result.add(action.id)

suite "materialized publication target selection":

  test "selected aggregate excludes unrelated tagged actions":
    let lowered = lowerMaterializedProviderSnapshot(
      fixtureSnapshot(), "/tmp/materialized-selection", ["selected"])
    check actionIds(lowered.actions) == @["publish-a"]

  test "no selector retains all tagged actions":
    let lowered = lowerMaterializedProviderSnapshot(
      fixtureSnapshot(), "/tmp/materialized-selection", newSeq[string]())
    check actionIds(lowered.actions) == @["publish-a", "publish-b"]

  test "selected closure without a tagged action lowers to no publications":
    let lowered = lowerMaterializedProviderSnapshot(
      fixtureSnapshot(), "/tmp/materialized-selection", ["untagged"])
    check lowered.actions.len == 0
