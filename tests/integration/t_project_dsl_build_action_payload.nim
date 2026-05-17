import std/[unittest]

import repro_project_dsl

proc writeByte(outp: var seq[byte]; value: byte) =
  outp.add(value)

proc writeU16Le(outp: var seq[byte]; value: uint16) =
  outp.add(byte(value and 0xff'u16))
  outp.add(byte((value shr 8) and 0xff'u16))

proc writeU32Le(outp: var seq[byte]; value: uint32) =
  for i in 0 ..< 4:
    outp.add(byte((value shr (8 * i)) and 0xff'u32))

proc writeString(outp: var seq[byte]; value: string) =
  outp.writeU32Le(uint32(value.len))
  for ch in value:
    outp.add(byte(ord(ch)))

proc writeStringSeq(outp: var seq[byte]; values: openArray[string]) =
  outp.writeU32Le(uint32(values.len))
  for value in values:
    outp.writeString(value)

proc writeCliArgLegacy(outp: var seq[byte]; arg: PublicCliArg;
                       version: uint16) =
  outp.writeString(arg.name)
  outp.writeString(arg.nimType)
  if version >= 2'u16:
    outp.writeByte(byte(ord(arg.kind)))
    outp.writeU32Le(uint32(arg.position))
    outp.writeString(arg.alias)
  outp.writeString(arg.encodedValue)

proc writeCliCallLegacy(outp: var seq[byte]; call: PublicCliCall;
                        version: uint16) =
  outp.writeString(call.packageName)
  outp.writeString(call.executableName)
  outp.writeString(call.subcommand)
  outp.writeString(call.providerEntrypointId)
  outp.writeU32Le(uint32(call.arguments.len))
  for arg in call.arguments:
    outp.writeCliArgLegacy(arg, version)

proc writeDependencyPolicy(outp: var seq[byte];
                           policy: BuildActionDependencyPolicy) =
  outp.writeByte(byte(ord(policy.kind)))
  outp.writeString(policy.depfile)

proc encodeLegacyBuildActionPayload(action: BuildActionDef;
                                    version: uint16): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeString(action.id)
  payload.writeCliCallLegacy(action.call, version)
  payload.writeStringSeq(action.deps)
  payload.writeStringSeq(action.inputs)
  payload.writeStringSeq(action.outputs)
  payload.writeString(action.depfile)
  payload.writeByte(if action.cacheable: 1'u8 else: 0'u8)
  payload.writeString(action.commandStatsId)
  if version >= 3'u16:
    payload.writeDependencyPolicy(action.dependencyPolicy)

  result.add([byte(ord('R')), byte(ord('B')), byte(ord('A')), byte(ord('P'))])
  result.writeU16Le(version)
  result.writeU32Le(uint32(payload.len))
  result.add(payload)

proc sampleAction(policy = defaultDependencyPolicy(); depfile = ""):
    BuildActionDef =
  buildAction(
    "compile",
    publicCliCall("pkg", "cc", "build", "pkg.cc.build", [
      inputArg("input", "src/main.c"),
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

  test "version 4 round-trips CLI argument roles and explicit dependency policies":
    let automatic = decodeBuildActionPayload(encodeBuildActionPayload(
      sampleAction(automaticMonitorPolicy())))
    check automatic.id == "compile"
    check automatic.call.arguments.len == 2
    check automatic.call.arguments[0].role == carInput
    check automatic.call.arguments[1].role == carOrdinary
    check automatic.dependencyPolicy.kind == bdpAutomaticMonitor
    check automatic.dependencyPolicy.depfile == ""

    let makeDepfile = decodeBuildActionPayload(encodeBuildActionPayload(
      sampleAction(makeDepfilePolicy("deps/generated.d"))))
    check makeDepfile.dependencyPolicy.kind == bdpMakeDepfile
    check makeDepfile.dependencyPolicy.depfile == "deps/generated.d"
    check makeDepfile.cacheable == false
    check makeDepfile.commandStatsId == "compile-stats"

  test "version 3 payloads decode with ordinary CLI argument roles":
    let decoded = decodeBuildActionPayload(encodeLegacyBuildActionPayload(
      sampleAction(makeDepfilePolicy("deps/generated.d")), 3'u16))
    check decoded.id == "compile"
    check decoded.call.arguments.len == 2
    check decoded.call.arguments[0].role == carOrdinary
    check decoded.dependencyPolicy.kind == bdpMakeDepfile
    check decoded.dependencyPolicy.depfile == "deps/generated.d"

  test "version 2 payloads decode with default dependency policy":
    let decoded = decodeBuildActionPayload(encodeLegacyBuildActionPayload(
      sampleAction(automaticMonitorPolicy()), 2'u16))
    check decoded.id == "compile"
    check decoded.depfile == ""
    check decoded.call.arguments[0].role == carOrdinary
    check decoded.dependencyPolicy.kind == bdpDefault
    check decoded.dependencyPolicy.depfile == ""

  test "invalid dependency policy kind fails closed":
    var encoded = encodeBuildActionPayload(sampleAction(
      automaticMonitorPolicy()))
    encoded[encoded.len - 5] = 255'u8

    expect BuildActionPayloadError:
      discard decodeBuildActionPayload(encoded)
