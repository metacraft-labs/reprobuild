import std/[os, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packages/nim as nim_module

proc argByName(action: BuildActionDef; name: string): PublicCliArg =
  for arg in action.call.arguments:
    if arg.name == name:
      return arg
  raise newException(ValueError, "no argument named '" & name & "'")

suite "Nim SSL compile dependency":
  setup:
    resetBuildActionRegistry()
    resetTargetExportRegistry()

  test "ssl define records OpenSSL and portable linker names":
    let previousNixLdFlags = getEnv("NIX_LDFLAGS")
    defer:
      putEnv("NIX_LDFLAGS", previousNixLdFlags)
    putEnv("NIX_LDFLAGS", "-L/ambient/openssl/lib -lambient")

    let action = nim.c(
      source = "src/main.nim",
      binary = "build/bin/example",
      defines = @["ssl"],
      actionId = "nim.ssl.fixture")

    let passL = action.argByName("passL").encodedValue
    check "-lssl" in passL
    check "-lcrypto" in passL
    check "/ambient/openssl" notin passL

    let registered = registeredBuildActions()
    check registered.len == 1
    check "openssl" in registered[0].toolIdentityRefs

  test "compile without ssl does not depend on OpenSSL":
    discard nim.c(
      source = "src/main.nim",
      binary = "build/bin/example",
      defines = @["release"],
      actionId = "nim.no-ssl.fixture")

    let registered = registeredBuildActions()
    check registered.len == 1
    check "openssl" notin registered[0].toolIdentityRefs
