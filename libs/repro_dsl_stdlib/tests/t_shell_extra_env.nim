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
    # On Windows `shell()` also declares `ShellHostSystemEnv` after them.
    let expected = declared & sh_module.ShellHostSystemEnv
    check edge.env == expected
    let registered = registeredBuildActions()
    require registered.len == 1
    check registered[0].env == expected
    check not registered[0].cacheable
    let decoded = decodeBuildActionPayload(encodeBuildActionPayload(edge))
    check decoded.env == expected
    check decoded.call == edge.call
    check decoded.nonDeterminism == ndpUnblessed

  test "omitted and explicitly empty environment preserve the same payload":
    let omitted = sh_module.shell(command = "exit 93", actionId = "gate")
    resetBuildActionRegistry()
    let explicit = sh_module.shell(command = "exit 93", actionId = "gate",
      extraEnv = [])
    check omitted.env == sh_module.ShellHostSystemEnv
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

  test "Windows shell edges declare a MinGW host, and a caller's value wins":
    # The Git launcher the Windows arms used to name set MSYSTEM=MINGW64;
    # `config.guess` reads the host from it. See `ShellHostSystemEnv`.
    when defined(windows):
      check sh_module.ShellHostSystemEnv == @[("MSYSTEM", "MINGW64")]
    else:
      check sh_module.ShellHostSystemEnv.len == 0
    let edge = sh_module.shell(command = "exit 93", actionId = "gate")
    check edge.env == sh_module.ShellHostSystemEnv
    resetBuildActionRegistry()
    let overridden = sh_module.shell(command = "exit 93", actionId = "gate",
      extraEnv = [("MSYSTEM", "MSYS")])
    check overridden.env == @[("MSYSTEM", "MSYS")]
