import std/[unittest]

import repro_project_dsl

proc patchU16Le(bytes: var seq[byte]; offset: int; value: uint16) =
  bytes[offset] = byte(value and 0xff'u16)
  bytes[offset + 1] = byte((value shr 8) and 0xff'u16)

proc readU32Le(bytes: openArray[byte]; offset: int): uint32 =
  for i in 0 ..< 4:
    result = result or (uint32(bytes[offset + i]) shl (8 * i))

proc patchU32Le(bytes: var seq[byte]; offset: int; value: uint32) =
  for i in 0 ..< 4:
    bytes[offset + i] = byte((value shr (8 * i)) and 0xff'u32)

proc sampleAction(policy = defaultDependencyPolicy(); depfile = ""):
    BuildActionDef =
  buildAction(
    "compile",
    publicCliCall("pkg", "cc", "build", "pkg.cc.build", [
      cliArg("input", "src/main.c"),
      cliArg("debug", true)
    ]),
    deps = ["generate"],
    inputs = ["src/main.c"],
    outputs = ["build/main.o"],
    depfile = depfile,
    cacheable = false,
    commandStatsId = "compile-stats",
    dependencyPolicy = policy)

suite "project DSL build action payload":
  setup:
    resetBuildActionRegistry()

  test "version 3 round-trips explicit dependency policies":
    let automatic = decodeBuildActionPayload(encodeBuildActionPayload(
      sampleAction(automaticMonitorPolicy())))
    check automatic.id == "compile"
    check automatic.call.arguments.len == 2
    check automatic.dependencyPolicy.kind == bdpAutomaticMonitor
    check automatic.dependencyPolicy.depfile == ""

    let makeDepfile = decodeBuildActionPayload(encodeBuildActionPayload(
      sampleAction(makeDepfilePolicy("deps/generated.d"))))
    check makeDepfile.dependencyPolicy.kind == bdpMakeDepfile
    check makeDepfile.dependencyPolicy.depfile == "deps/generated.d"
    check makeDepfile.cacheable == false
    check makeDepfile.commandStatsId == "compile-stats"

  test "version 2 payloads decode with default dependency policy":
    var encoded = encodeBuildActionPayload(sampleAction(
      automaticMonitorPolicy()))
    encoded.patchU16Le(4, 2'u16)
    let policyBytes = 5'u32
    let payloadLength = encoded.readU32Le(6)
    encoded.patchU32Le(6, payloadLength - policyBytes)
    encoded.setLen(encoded.len - int(policyBytes))

    let decoded = decodeBuildActionPayload(encoded)
    check decoded.id == "compile"
    check decoded.depfile == ""
    check decoded.dependencyPolicy.kind == bdpDefault
    check decoded.dependencyPolicy.depfile == ""

  test "invalid dependency policy kind fails closed":
    var encoded = encodeBuildActionPayload(sampleAction(
      automaticMonitorPolicy()))
    encoded[encoded.len - 5] = 255'u8

    expect BuildActionPayloadError:
      discard decodeBuildActionPayload(encoded)
