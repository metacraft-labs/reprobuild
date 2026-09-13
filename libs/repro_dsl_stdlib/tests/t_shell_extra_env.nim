import std/unittest

import repro_project_dsl
import repro_dsl_stdlib/packages/sh as sh_module

suite "shell per-action environment":
  setup:
    resetBuildActionRegistry()

  test "declared values reach the registered action and provider payload":
    let declared = @[("GATE_LAYERS", "first,second"),
      ("EMPTY", ""), ("LITERAL", "space ' quote = $value")]
    let edge = sh_module.shell(command = "exit 93", actionId = "gate",
      extraEnv = declared, cacheable = false)
    check edge.env == declared
    let registered = registeredBuildActions()
    require registered.len == 1
    check registered[0].env == declared
    check not registered[0].cacheable
    let decoded = decodeBuildActionPayload(encodeBuildActionPayload(edge))
    check decoded.env == declared
    check decoded.call == edge.call
    check decoded.nonDeterminism == ndpUnblessed

  test "omitted and explicitly empty environment preserve the same payload":
    let omitted = sh_module.shell(command = "exit 93", actionId = "gate")
    resetBuildActionRegistry()
    let explicit = sh_module.shell(command = "exit 93", actionId = "gate",
      extraEnv = [])
    check omitted.env.len == 0
    check encodeBuildActionPayload(omitted) == encodeBuildActionPayload(explicit)

  test "changing only an environment value changes the provider payload":
    let off = sh_module.shell(command = "exit 93", actionId = "gate",
      extraEnv = [("GATE", "0")])
    resetBuildActionRegistry()
    let on = sh_module.shell(command = "exit 93", actionId = "gate",
      extraEnv = [("GATE", "1")])
    check off.call == on.call
    check off.id == on.id
    check encodeBuildActionPayload(off) != encodeBuildActionPayload(on)
