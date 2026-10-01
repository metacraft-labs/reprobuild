## A typed tool's own sub-tools (`cli: subTools`) survive registration and
## the build-action payload codec, and are not confused with the edge's
## declared `toolIdentityRefs`.
##
## `subToolRefs` widen an edge's PATH prefix without making it hermetic,
## while `toolIdentityRefs` select the hermetic shape. The two must stay
## distinct lists all the way to the lowering, or a tool's sub-tools would
## silently turn every edge of that tool hermetic.
##
## No mocks: the real registry and the real v29 codec.

import std/unittest

import repro_project_dsl

suite "typed-tool sub-tool refs":
  setup:
    resetBuildActionRegistry()

  test "registration appends in order, deduplicated, apart from tool refs":
    discard buildAction(
      id = "cargo-build",
      call = inlineExecCall(@["cargo", "build"]),
      toolIdentityRefs = @["nim"])
    appendRegisteredActionSubToolRefs("cargo-build", ["rustc", "gcc"])
    appendRegisteredActionSubToolRefs("cargo-build", ["gcc", "clang", ""])
    let action = registeredBuildActions()[0]
    check action.subToolRefs == @["rustc", "gcc", "clang"]
    check action.toolIdentityRefs == @["nim"]

  test "the payload round-trips sub-tool refs; a v28 payload carries none":
    let action = BuildActionDef(
      id: "cargo-build",
      call: inlineExecCall(@["cargo", "build"]),
      subToolRefs: @["rustc", "gcc", "clang"])
    let decoded = decodeBuildActionPayload(encodeBuildActionPayload(action))
    check decoded.subToolRefs == @["rustc", "gcc", "clang"]
    check decoded.toolIdentityRefs.len == 0
    let v28 = decodeBuildActionPayload(
      encodeBuildActionPayloadAtVersion(action, 28'u16))
    check v28.subToolRefs.len == 0
