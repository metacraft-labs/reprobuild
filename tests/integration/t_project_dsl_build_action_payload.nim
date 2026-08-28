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
  if version >= 4'u16:
    outp.writeByte(byte(ord(arg.role)))
  if version >= 5'u16:
    outp.writeByte(byte(ord(arg.format)))
    outp.writeByte(if arg.repeated: 1'u8 else: 0'u8)
  if version >= 6'u16:
    outp.writeByte(byte(ord(arg.placement)))
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
  # MR16: legacy v3..v14 payloads carried a single ``depfile: string``
  # in the dependency-policy section. We synthesise the legacy wire
  # by writing the first ``depfiles`` entry (or the empty string when
  # the policy has no depfile), letting these legacy-encoder tests
  # continue to verify the read-side migration in
  # ``readDependencyPolicy`` (v14 -> v15 lift to one-element seq).
  let legacy =
    if policy.depfiles.len > 0: policy.depfiles[0] else: ""
  outp.writeString(legacy)

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

proc sampleAction(policy = defaultDependencyPolicy(); depfile = "";
                  actionCachePolicy = defaultActionCachePolicy()):
    BuildActionDef =
  buildAction(
    "compile",
    publicCliCall("pkg", "cc", "build", "pkg.cc.build", [
      inputArg("input", "src/main.c"),
      cliArg("config", "release", alias = "-C",
        placement = capBeforeSubcommand),
      cliArg("debug", true, alias = "-g"),
      inputArgSeq("include", @["include/a.h", "include/b.h"],
        alias = "-include", repeated = true)
    ]),
    deps = ["generate"],
    inputs = ["src/main.c"],
    outputs = ["build/main.o"],
    depfile = depfile,
    cacheable = false,
    commandStatsId = "compile-stats",
    dependencyPolicy = policy,
    actionCachePolicy = actionCachePolicy)

suite "project DSL build action payload":
  setup:
    resetBuildActionRegistry()

  test "current version round-trips CLI arguments, dependency policy, and cache policy":
    let automatic = decodeBuildActionPayload(encodeBuildActionPayload(
      sampleAction(automaticMonitorPolicy())))
    check automatic.id == "compile"
    check automatic.call.arguments.len == 4
    check automatic.call.arguments[0].role == carInput
    check automatic.call.arguments[1].placement == capBeforeSubcommand
    check automatic.call.arguments[2].role == carOrdinary
    check automatic.call.arguments[3].role == carInput
    check automatic.call.arguments[3].format == cafSeparate
    check automatic.call.arguments[3].repeated
    check automatic.dependencyPolicy.kind == bdpAutomaticMonitor
    check automatic.dependencyPolicy.depfiles.len == 0
    check automatic.actionCachePolicy == acfpTimestamp

    let makeDepfile = decodeBuildActionPayload(encodeBuildActionPayload(
      sampleAction(makeDepfilePolicy("deps/generated.d"),
        actionCachePolicy = acfpChecksum)))
    check makeDepfile.dependencyPolicy.kind == bdpMakeDepfile
    check makeDepfile.dependencyPolicy.depfiles == @["deps/generated.d"]
    check makeDepfile.cacheable == false
    check makeDepfile.commandStatsId == "compile-stats"
    check makeDepfile.actionCachePolicy == acfpChecksum

  test "version 24 payloads still decode after the removed trusted-inputs fields":
    # v24 appended two fields to the dependency policy (an input seq and a
    # reason string) for the removed ``bdpTrustedDeclaredInputs`` kind. v25
    # replaced them with a single ``suppressMonitorShimSeed`` byte.
    #
    # The encoding is append-only WITH per-version gates, not self-describing:
    # a reader that simply stopped consuming the v24 fields would leave the
    # cursor eight bytes short and misparse EVERY field after the policy —
    # target names, typed outputs, env, the cwd declaration — rather than fail.
    # So this pins that a v24 record on disk is still read correctly.
    let probe = "deps/v24-probe.d"
    var encoded = encodeBuildActionPayload(
      sampleAction(makeDepfilePolicy(probe)))

    # Locate the policy's ``depfiles`` entry: its 4-byte length prefix
    # followed by the path bytes. Unique in this payload — the sample action
    # carries no legacy ``depfile`` and no argument with this value.
    var probeBytes: seq[byte] = @[]
    probeBytes.writeString(probe)
    var found = -1
    for start in 0 .. encoded.len - probeBytes.len:
      var matches = true
      for i in 0 ..< probeBytes.len:
        if encoded[start + i] != probeBytes[i]:
          matches = false
          break
      if matches:
        check found == -1
        found = start
    check found >= 0

    # After the path: the 4-byte ``ignoredInputPrefixes`` count, then the
    # single v25 ``suppressMonitorShimSeed`` byte. Swap that byte for v24's
    # empty input seq + empty reason string.
    let flagAt = found + probeBytes.len + 4
    check encoded[flagAt] == 0'u8
    var legacyTail: seq[byte] = @[]
    legacyTail.writeStringSeq([])
    legacyTail.writeString("")
    var v24: seq[byte] = @[]
    for i in 0 ..< flagAt:
      v24.add(encoded[i])
    v24.add(legacyTail)
    for i in flagAt + 1 ..< encoded.len:
      v24.add(encoded[i])
    # Header: version word at offset 4, payload length at offset 6.
    v24[4] = 24'u8
    v24[5] = 0'u8
    var lengthBytes: seq[byte] = @[]
    lengthBytes.writeU32Le(uint32(v24.len - 10))
    for i in 0 ..< 4:
      v24[6 + i] = lengthBytes[i]

    let decoded = decodeBuildActionPayload(v24)
    check decoded.id == "compile"
    check decoded.dependencyPolicy.kind == bdpMakeDepfile
    check decoded.dependencyPolicy.depfiles == @[probe]
    check not decoded.dependencyPolicy.suppressMonitorShimSeed
    # The fields AFTER the policy are the ones a short read would corrupt.
    check decoded.commandStatsId == "compile-stats"
    check decoded.inputs == @["src/main.c"]
    check decoded.outputs == @["build/main.o"]
    check decoded.call.arguments.len == 4

  test "the removed trusted-declared-inputs policy kind is refused":
    # ``bdpTrustedDeclaredInputs`` used to be ordinal 4, one past
    # ``bdpIomonReport``. A stored graph that still names it must fail closed
    # rather than decode as some surviving kind.
    var encoded = encodeBuildActionPayload(
      sampleAction(makeDepfilePolicy("deps/generated.d")))
    var probeBytes: seq[byte] = @[]
    probeBytes.writeString("deps/generated.d")
    var found = -1
    for start in 0 .. encoded.len - probeBytes.len:
      var matches = true
      for i in 0 ..< probeBytes.len:
        if encoded[start + i] != probeBytes[i]:
          matches = false
          break
      if matches and found == -1:
        found = start
    check found >= 0
    # The kind byte sits immediately before the depfiles count.
    encoded[found - 5] = 4'u8
    expect BuildActionPayloadError:
      discard decodeBuildActionPayload(encoded)

  test "version 3 payloads decode with ordinary CLI argument roles":
    let decoded = decodeBuildActionPayload(encodeLegacyBuildActionPayload(
      sampleAction(makeDepfilePolicy("deps/generated.d")), 3'u16))
    check decoded.id == "compile"
    check decoded.call.arguments.len == 4
    check decoded.call.arguments[0].role == carOrdinary
    check decoded.dependencyPolicy.kind == bdpMakeDepfile
    check decoded.dependencyPolicy.depfiles == @["deps/generated.d"]
    check decoded.actionCachePolicy == acfpTimestamp

  test "version 2 payloads decode with default dependency policy":
    let decoded = decodeBuildActionPayload(encodeLegacyBuildActionPayload(
      sampleAction(automaticMonitorPolicy()), 2'u16))
    check decoded.id == "compile"
    check decoded.depfile == ""
    check decoded.call.arguments[0].role == carOrdinary
    check decoded.dependencyPolicy.kind == bdpDefault
    check decoded.dependencyPolicy.depfiles.len == 0
    check decoded.actionCachePolicy == acfpTimestamp

  test "invalid dependency policy kind fails closed":
    var encoded = encodeBuildActionPayload(sampleAction(
      automaticMonitorPolicy()))
    encoded[encoded.len - 6] = 255'u8

    expect BuildActionPayloadError:
      discard decodeBuildActionPayload(encoded)

  test "invalid action cache policy fails closed":
    var encoded = encodeBuildActionPayload(sampleAction())
    encoded[encoded.len - 1] = 255'u8

    expect BuildActionPayloadError:
      discard decodeBuildActionPayload(encoded)
  test "version 4 payloads decode with default CLI argument formatting":
    let decoded = decodeBuildActionPayload(encodeLegacyBuildActionPayload(
      sampleAction(makeDepfilePolicy("deps/generated.d")), 4'u16))
    check decoded.id == "compile"
    check decoded.call.arguments.len == 4
    check decoded.call.arguments[0].role == carInput
    check decoded.call.arguments[0].format == cafSeparate
    check not decoded.call.arguments[0].repeated
    check decoded.call.arguments[1].placement == capAfterSubcommand
    check decoded.dependencyPolicy.kind == bdpMakeDepfile
    check decoded.dependencyPolicy.depfiles == @["deps/generated.d"]

  test "version 5 payloads decode with after-subcommand CLI argument placement":
    let decoded = decodeBuildActionPayload(encodeLegacyBuildActionPayload(
      sampleAction(makeDepfilePolicy("deps/generated.d")), 5'u16))
    check decoded.id == "compile"
    check decoded.call.arguments.len == 4
    check decoded.call.arguments[1].format == cafSeparate
    check decoded.call.arguments[1].placement == capAfterSubcommand
    check decoded.dependencyPolicy.kind == bdpMakeDepfile
