import std/unittest

import repro_project_dsl

suite "tool identity reference kinds":
  setup:
    resetBuildActionRegistry()

  test "registered dependency roles stay parallel to tool refs":
    discard buildAction(
      id = "compile",
      call = inlineExecCall(@["meson", "compile"]),
      toolIdentityRefs = @["meson"])
    appendRegisteredActionToolIdentityRefs("compile",
      @["gcc", "pkg-config", "libdrm", "wayland"])
    classifyRegisteredActionToolIdentityRefs("compile",
      @["libdrm", "wayland"])

    let action = registeredBuildActions()[0]
    check action.toolIdentityRefs ==
      @["meson", "gcc", "pkg-config", "libdrm", "wayland"]
    check action.toolIdentityRefKinds ==
      @[tirkNative, tirkNative, tirkNative, tirkBuild, tirkBuild]

  test "v23 payload round-trips dependency roles":
    let action = BuildActionDef(
      id: "compile",
      call: inlineExecCall(@["ninja"]),
      toolIdentityRefs: @["ninja", "libdrm"],
      toolIdentityRefKinds: @[tirkNative, tirkBuild])

    let decoded = decodeBuildActionPayload(encodeBuildActionPayload(action))
    check decoded.toolIdentityRefs == action.toolIdentityRefs
    check decoded.toolIdentityRefKinds == action.toolIdentityRefKinds
