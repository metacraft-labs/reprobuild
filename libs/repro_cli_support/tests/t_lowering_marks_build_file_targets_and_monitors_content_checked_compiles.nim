## Two decisions the lowering of a provider graph makes about an action,
## pinned on the production `lowerProviderSnapshot` (Caching-Architecture.md,
## "Design for XPC-AREQ1", D7 and D8).
##
## * D7: a build file's `target "name", handle` row names its action a result
##   of the build, so the lowered action carries that name as a target name
##   (a portable hit then puts its outputs in place). An `aggregate` row is a
##   grouping, not a result, and marks nothing.
## * D8: an action whose input-check policy is content checked and whose only
##   evidence is a make depfile is lowered with the automatic monitor as its
##   evidence and no depfile; with the `timestamp` policy it keeps its
##   depfile.
##
## Nothing is mocked: plain values of the production payload types, lowered
## by the production lowering. No action is executed; both properties are
## facts about the lowered action.

import std/[strutils, tempfiles, os, unittest]

import repro_build_engine
import repro_cli_support
import repro_core
import repro_core/input_check_policy
import repro_project_dsl
import repro_provider_runtime
import repro_tool_profiles

proc actionNode(declared: BuildActionDef): GraphNode =
  GraphNode(id: "fixture:action:" & declared.id, kind: gnkAction,
    stableName: declared.id, payload: actionPayload(declared))

proc targetNode(name: string; kind: BuildTargetKind;
                actions: seq[string]): GraphNode =
  GraphNode(id: "fixture:target:" & name, kind: gnkMetadata,
    stableName: "reprobuild.build-target.v1",
    payload: targetPayload(BuildTargetDef(name: name, kind: kind,
      actions: actions)))

proc lowered(nodes: seq[GraphNode]; root: string): seq[BuildAction] =
  lowerProviderSnapshot(ProviderGraphSnapshot(fragments: @[
    StoredGraphFragment(namespace: "fixture", nodes: nodes)]),
    PathOnlyBuildIdentity(), root, [""]).actions

proc find(actions: seq[BuildAction]; id: string): BuildAction =
  for action in actions:
    if action.id == id:
      return action
  raise newException(KeyError, "no lowered action " & id)

proc compileDef(id, root: string; policy: ActionCacheFingerprintPolicy):
    BuildActionDef =
  let dep = root / (id & ".o.d")
  result = buildAction(id, inlineExecCall(@["/bin/true", "-MD", "-MF", dep,
    "-o", root / (id & ".o")], root), outputs = @[root / (id & ".o")],
    depfile = dep, dependencyPolicy = makeDepfilePolicy(dep),
    cacheable = true, actionCachePolicy = policy)

suite "the lowering marks build-file targets and monitors content-checked compiles":

  test "a target row names its action; an aggregate row does not":
    let root = createTempDir("repro-lower-targets-", "")
    defer: removeDir(root)
    resetBuildActionRegistry()
    let lib = buildAction("lib-archive", inlineExecCall(@["/bin/true"], root),
      outputs = @[root / "lib.a"], cacheable = true)
    let tool = buildAction("tool-link", inlineExecCall(@["/bin/true"], root),
      outputs = @[root / "tool"], cacheable = true)
    let other = buildAction("other-link", inlineExecCall(@["/bin/true"], root),
      outputs = @[root / "other"], cacheable = true)
    # A two-member aggregate: a one-member one would rename its member
    # (`considerDirectAlias`'s fallback rank) without marking it.
    let actions = lowered(@[actionNode(lib), actionNode(tool),
      actionNode(other),
      targetNode("mathlib", btkTarget, @["lib-archive"]),
      targetNode("everything", btkAggregate, @["tool-link", "other-link"])],
      root)
    # A target renames its action, so it is found under the target's name.
    check "mathlib" in actions.find("mathlib").targetNames
    check actions.find("tool-link").targetNames.len == 0
    check actions.find("other-link").targetNames.len == 0

  test "a content-checked depfile compile is monitored, a timestamp one is not":
    let root = createTempDir("repro-lower-d8-", "")
    defer: removeDir(root)
    resetBuildActionRegistry()
    let hybrid = compileDef("cc-hybrid", root, acfpHybrid)
    let checksum = compileDef("cc-checksum", root, acfpChecksum)
    let stamped = compileDef("cc-timestamp", root, acfpTimestamp)
    let actions = lowered(@[actionNode(hybrid), actionNode(checksum),
      actionNode(stamped)], root)
    for id in ["cc-hybrid", "cc-checksum"]:
      let action = actions.find(id)
      check action.dependencyPolicy.kind == dgAutomaticMonitor
      check action.dependencyPolicy.recognizedReports.len == 0
      check action.depfile == ""
    let kept = actions.find("cc-timestamp")
    check kept.dependencyPolicy.kind == dgRecognizedFormat
    check kept.depfile.len > 0
    # Applying the switch to its own result changes nothing: an edge
    # already gathered by the monitor is left as it is.
    var again = actions.find("cc-hybrid")
    check not monitorEvidenceForContentCheckedDepfileEdge(again, ffpHybrid)
