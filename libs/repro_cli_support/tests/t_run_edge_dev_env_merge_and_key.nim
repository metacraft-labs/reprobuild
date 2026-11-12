## The rules by which a run-edge receives its package's dev environment
## (`repro_cli_support/dev_env_run_edges`), asserted on the functions
## themselves: which edges, how each op merges with the edge's own
## environment, and what enters the key.
##
## The end-to-end property -- `repro test` from a shell that has none of the
## environment -- is `tests/e2e/dev-env/t_e2e_repro_test_run_edges_get_the_dev_env.nim`.
## This file pins the cases that one fixture cannot reach cheaply: an edge's
## own declaration winning over a `setEnv`, a passthrough `PATH`, an unset
## that cannot be honoured, and the key's sensitivity to op order.
##
## MOCKS: one. ``inheritedValue`` is a table instead of the process
## environment, because the rule under test is what the function does with
## an inherited value, and reading the real environment would make the
## expectations depend on the shell the suite runs in.

import std/[sequtils, sets, strutils, tables, unittest]

import repro_build_engine
import repro_hash
import repro_provider_runtime
import repro_project_dsl
from repro_core/codec import toBytes
import repro_cli_support/dev_env_run_edges

proc edge(env: openArray[string] = [];
          passthrough: openArray[string] = []): BuildAction =
  action("fixture.run_edge", ["/bin/sh", "-c", "true"], env = env,
    envPassthrough = passthrough,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc op(kind: DevEnvShellOpKind; name: string; value = ""): DevEnvShellOp =
  DevEnvShellOp(kind: kind, name: name, value: value, separator: ":")

proc host(values: openArray[(string, string)]): proc (name: string): string =
  let table = values.toTable
  result = proc (name: string): string = table.getOrDefault(name)

proc envValue(action: BuildAction; name: string): string =
  for entry in action.env:
    if entry.startsWith(name & "="):
      result = entry[name.len + 1 .. ^1]

proc declaresCount(action: BuildAction; name: string): int =
  for entry in action.env:
    if entry.startsWith(name & "="):
      inc result

suite "applyDevEnvToRunEdge":
  test "an empty contribution changes neither the edge nor its key":
    var a = edge(["KEEP=1"])
    let before = a
    let unremoved = applyDevEnvToRunEdge(a, [], devEnvRunEdgeIdentity([]),
      host([]))
    check unremoved.len == 0
    check a.env == before.env
    check a.envPassthrough == before.envPassthrough
    check a.weakFingerprint == before.weakFingerprint

  test "a prepend onto an inherited PATH keeps the host part unkeyed":
    # The lowering's inherited branch: PATH named passthrough, no value.
    var a = edge(passthrough = ["PATH"])
    let ops = @[op(deskPrependPath, "PATH", "/devenv/bin")]
    discard applyDevEnvToRunEdge(a, ops, devEnvRunEdgeIdentity(ops),
      host({"PATH": "/usr/bin:/bin"}))
    check a.envValue("PATH") == "/devenv/bin:/usr/bin:/bin"
    check a.envPassthrough.count("PATH") == 1

  test "a prepend onto an inherited, undeclared name makes it passthrough":
    var a = edge()
    let ops = @[op(deskPrependPath, "LD_LIBRARY_PATH", "/devenv/lib")]
    discard applyDevEnvToRunEdge(a, ops, devEnvRunEdgeIdentity(ops),
      host({"LD_LIBRARY_PATH": "/host/lib"}))
    check a.envValue("LD_LIBRARY_PATH") == "/devenv/lib:/host/lib"
    check "LD_LIBRARY_PATH" in a.envPassthrough

  test "a value decided by the dev environment alone is declared":
    var a = edge()
    let ops = @[op(deskSetEnv, "MARK", "v1"),
      op(deskPrependPath, "EMPTY_LIST", "/devenv/x")]
    discard applyDevEnvToRunEdge(a, ops, devEnvRunEdgeIdentity(ops), host([]))
    check a.envValue("MARK") == "v1"
    check a.envValue("EMPTY_LIST") == "/devenv/x"
    check a.envPassthrough.len == 0

  test "the edge's own declaration wins over a set, and is composed onto":
    var a = edge(["PYTHONHASHSEED=0", "PATH=/tool/bin"])
    let ops = @[op(deskSetEnv, "PYTHONHASHSEED", "random"),
      op(deskUnsetEnv, "PYTHONHASHSEED"),
      op(deskPrependPath, "PATH", "/devenv/bin")]
    discard applyDevEnvToRunEdge(a, ops, devEnvRunEdgeIdentity(ops),
      host({"PATH": "/host/bin"}))
    check a.envValue("PYTHONHASHSEED") == "0"
    check a.declaresCount("PYTHONHASHSEED") == 1
    # Composed onto the DECLARED value, not the host's, and still declared.
    check a.envValue("PATH") == "/devenv/bin:/tool/bin"
    check a.declaresCount("PATH") == 1
    check "PATH" notin a.envPassthrough

  test "prepend moves an entry that is already present, as repro exec does":
    var a = edge(passthrough = ["PATH"])
    let ops = @[op(deskPrependPath, "PATH", "/devenv/bin")]
    discard applyDevEnvToRunEdge(a, ops, devEnvRunEdgeIdentity(ops),
      host({"PATH": "/usr/bin:/devenv/bin:/bin"}))
    check a.envValue("PATH") == "/devenv/bin:/usr/bin:/bin"

  test "an unset of an inherited value is reported, not silently dropped":
    var a = edge(["OWN=1"])
    let ops = @[op(deskUnsetEnv, "HOST_ONLY"), op(deskUnsetEnv, "ABSENT")]
    let unremoved = applyDevEnvToRunEdge(a, ops, devEnvRunEdgeIdentity(ops),
      host({"HOST_ONLY": "x"}))
    check unremoved == @["HOST_ONLY"]
    check a.declaresCount("HOST_ONLY") == 0
    check a.envValue("OWN") == "1"

  test "setWorkingDirectory is not applied to an edge":
    var a = edge()
    let ops = @[op(deskSetWorkingDirectory, "", "/elsewhere")]
    let cwdBefore = a.cwd
    discard applyDevEnvToRunEdge(a, ops, devEnvRunEdgeIdentity(ops), host([]))
    check a.cwd == cwdBefore
    check a.env.len == 0

suite "the dev environment's identity keys the run-edge":
  test "the identity folds into the weak fingerprint":
    var a = edge(passthrough = ["PATH"])
    let before = a.weakFingerprint
    let ops = @[op(deskPrependPath, "PATH", "/devenv/bin")]
    discard applyDevEnvToRunEdge(a, ops, devEnvRunEdgeIdentity(ops),
      host({"PATH": "/usr/bin"}))
    check a.weakFingerprint != before

  test "a different store path is a different key, the host PATH is not":
    proc keyOf(devDir, hostPath: string): ContentDigest =
      var a = edge(passthrough = ["PATH"])
      let ops = @[op(deskPrependPath, "PATH", devDir)]
      discard applyDevEnvToRunEdge(a, ops, devEnvRunEdgeIdentity(ops),
        host({"PATH": hostPath}))
      a.weakFingerprint
    check keyOf("/nix/store/aaa-webp/lib", "/usr/bin") ==
      keyOf("/nix/store/aaa-webp/lib", "/home/dev/bin:/usr/bin")
    check keyOf("/nix/store/aaa-webp/lib", "/usr/bin") !=
      keyOf("/nix/store/bbb-webp/lib", "/usr/bin")

  test "op order is part of the identity":
    let ab = @[op(deskPrependPath, "PATH", "/a"),
      op(deskPrependPath, "PATH", "/b")]
    let ba = @[op(deskPrependPath, "PATH", "/b"),
      op(deskPrependPath, "PATH", "/a")]
    check devEnvRunEdgeIdentity(ab) != devEnvRunEdgeIdentity(ba)

  test "no field can be shifted into its neighbour":
    check devEnvRunEdgeIdentity([op(deskSetEnv, "AB", "C")]) !=
      devEnvRunEdgeIdentity([op(deskSetEnv, "A", "BC")])

suite "devEnvRunEdgeActionIds":
  proc targetNode(target: BuildTargetDef): GraphNode =
    GraphNode(id: "ns:metadata:build-target:" & target.name,
      kind: gnkMetadata, stableName: "reprobuild.build-target.v1",
      payload: targetPayload(target))

  proc marker(): GraphNode =
    GraphNode(id: "ns:metadata:dev-env-declared", kind: gnkMetadata,
      stableName: DevEnvDeclaredGraphStableName, payload: "pkg")

  proc snapshotOf(nodes: seq[GraphNode]): ProviderGraphSnapshot =
    ProviderGraphSnapshot(fragments: @[StoredGraphFragment(nodes: nodes)])

  let targets = @[
    BuildTargetDef(name: "test", actions: @["t.direct"], targets: @["inner"],
      kind: btkCollection),
    BuildTargetDef(name: "inner", actions: @["t.nested"],
      kind: btkCollection),
    BuildTargetDef(name: "bench", actions: @["b.one"], kind: btkCollection),
    BuildTargetDef(name: "lint", actions: @["l.one"], kind: btkCollection),
    BuildTargetDef(name: "default", actions: @["compile"],
      kind: btkCollection)]

  test "test and bench members, nested ones included, in a marked package":
    var nodes = @[marker()]
    for t in targets:
      nodes.add(targetNode(t))
    let ids = devEnvRunEdgeActionIds(snapshotOf(nodes),
      initTable[string, string]())
    check ids == toHashSet(["t.direct", "t.nested", "b.one"])

  test "no marker, no run-edges: a recipe without devEnv is untouched":
    var nodes: seq[GraphNode]
    for t in targets:
      nodes.add(targetNode(t))
    check devEnvRunEdgeActionIds(snapshotOf(nodes),
      initTable[string, string]()).len == 0

  test "an edge a target renamed is named as the lowering names it":
    var nodes = @[marker()]
    for t in targets:
      nodes.add(targetNode(t))
    let ids = devEnvRunEdgeActionIds(snapshotOf(nodes),
      {"t.direct": "smoke"}.toTable)
    check "smoke" in ids
    check "t.direct" notin ids
