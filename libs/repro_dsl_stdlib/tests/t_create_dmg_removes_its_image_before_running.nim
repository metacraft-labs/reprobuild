## `create_dmg` declares its `.dmg` as an output the engine removes before
## the edge runs.
##
## create-dmg 1.2.2 finishes with `hdiutil convert ... -o <dmg>`, which
## refuses an existing file (`hdiutil: convert failed - File exists`). Before
## this declaration the edge did not even list the image as an output, so a
## re-run after any input change failed because the previous run had
## succeeded (seen building CodeTracer's macOS dmg). The declaration has to
## survive the whole route to the engine: the typed-tool wrapper, the action
## registry and the build-action payload codec that every provider graph node
## passes through.
##
## No mocks: the real `create-dmg` typed tool, the real registry and the real
## codec. Nothing is executed; the engine half is covered by
## `libs/repro_build_engine/tests/t_remove_before_run.nim`.

import std/unittest

import repro_project_dsl
import repro_dsl_stdlib/packages/create_dmg as create_dmg_module

suite "create_dmg replaces its image on re-run":
  setup:
    resetBuildActionRegistry()
    resetTargetExportRegistry()

  test "the lowered action removes exactly its dmg before running":
    discard create_dmg(
      volname = "CodeTracer",
      sandboxSafe = true,
      dmg = "non-nix-build/CodeTracer.dmg",
      src = "non-nix-build/dmg-staging",
      actionId = "macos-dmg")
    let registered = registeredBuildActions()
    require registered.len == 1
    let action = registered[0]
    check "non-nix-build/CodeTracer.dmg" in action.outputs
    check action.removeBeforeRun == @["non-nix-build/CodeTracer.dmg"]
    # The source tree is not an output and is never removed.
    check "non-nix-build/dmg-staging" notin action.removeBeforeRun

    let decoded = decodeBuildActionPayload(encodeBuildActionPayload(action))
    check decoded.removeBeforeRun == @["non-nix-build/CodeTracer.dmg"]
    check "non-nix-build/CodeTracer.dmg" in decoded.outputs

  test "a payload from before the field carries nothing to remove":
    let action = BuildActionDef(id: "a", call: inlineExecCall(@["true"]),
      outputs: @["out/x"], removeBeforeRun: @["out/x"])
    let v30 = decodeBuildActionPayload(
      encodeBuildActionPayloadAtVersion(action, 30'u16))
    check v30.removeBeforeRun.len == 0
    check v30.outputs == @["out/x"]

  test "buildAction accepts the declaration for a hand-written action":
    discard buildAction(id = "writer",
      call = inlineExecCall(@["sh", "-c", "set -C; echo x > out/x"]),
      outputs = @["out/x"], removeBeforeRun = @["out/x"])
    check registeredBuildActions()[0].removeBeforeRun == @["out/x"]
