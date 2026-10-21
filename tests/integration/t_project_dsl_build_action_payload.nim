import std/[options, strutils, tables, unittest]

import repro_project_dsl

proc writeU32Le(outp: var seq[byte]; value: uint32) =
  for i in 0 ..< 4:
    outp.add(byte((value shr (8 * i)) and 0xff'u32))

proc writeString(outp: var seq[byte]; value: string) =
  outp.writeU32Le(uint32(value.len))
  for ch in value:
    outp.add(byte(ord(ch)))

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

proc singleDifferingByte(a, b: seq[byte]): int =
  ## Offset of the one byte at which ``a`` and ``b`` differ, or -1 when they
  ## differ in length or in more than one byte.
  ##
  ## Corruption cases locate the byte they corrupt this way, by encoding two
  ## actions that differ only in the field under test, rather than by its
  ## distance from the end of the payload. Version bumps append fields, so a
  ## tail offset silently moves onto a different field. The cache-policy case
  ## used ``encoded.len - 1`` long after the policy had stopped being the last
  ## byte; at v30 it was corrupting the high byte of the ``scratchDirs`` count,
  ## and the decoder tried to allocate ~68 GB.
  if a.len != b.len:
    return -1
  result = -1
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      if result != -1:
        return -1
      result = i

proc markerOffset(encoded: seq[byte]; marker: string): int =
  ## Offset of the first length-prefixed occurrence of ``marker``, or -1.
  var probe: seq[byte] = @[]
  probe.writeString(marker)
  for start in 0 .. encoded.len - probe.len:
    if encoded[start ..< start + probe.len] == probe:
      return start
  -1

proc countBefore(encoded: seq[byte]; marker: string): int =
  ## Offset of the u32 count of a list whose FIRST element begins with the
  ## length-prefixed string ``marker``.
  let found = markerOffset(encoded, marker)
  if found < 4: -1 else: found - 4

proc countAfter(encoded: seq[byte]; marker: string): int =
  ## Offset of the u32 count that immediately follows the length-prefixed
  ## string ``marker``, the last element of the list before it.
  let found = markerOffset(encoded, marker)
  if found < 0: -1 else: found + 4 + marker.len

proc decodeFailure(encoded: seq[byte]): string =
  ## The ``BuildActionPayloadError`` message ``encoded`` decodes to, or ""
  ## when it decodes.
  try:
    discard decodeBuildActionPayload(encoded)
  except BuildActionPayloadError as err:
    result = err.msg

proc decodeWithCount(encoded: seq[byte]; offset: int; count: uint32):
    tuple[message: string, peakGrowth: int] =
  ## Overwrite the u32 count at ``offset`` with ``count``, decode, and report
  ## the payload error and how far the allocator's peak footprint grew.
  ## ``getMaxMem`` is a high-water mark since process start, so growth shows
  ## only when the decode exceeds every earlier peak in this binary. The
  ## counts the caller uses would exceed it by megabytes to gigabytes if
  ## anything were sized by them.
  var corrupt = encoded
  for i in 0 ..< 4:
    corrupt[offset + i] = byte((count shr (8 * i)) and 0xff'u32)
  when declared(getMaxMem):
    let before = getMaxMem()
  result.message = decodeFailure(corrupt)
  when declared(getMaxMem):
    result.peakGrowth = getMaxMem() - before

proc markedAction(): BuildActionDef =
  ## An action whose count-prefixed lists are non-empty and start (or, for
  ## ``readOnlyRoots``, end) with a unique marker, so a test can find each
  ## count in the encoded payload without restating the field layout.
  result = buildAction(
    "marked",
    publicCliCall("pkg", "cc", "build", "pkg.cc.build", [
      cliArg("argMarker", "value")]),
    outputs = ["build/marked.o"],
    commandStatsId = "marked")
  result.typedOutputs = @[BuildActionTypedOutput(
    fieldName: "typedMarker", types: @["TestBinary"], path: "build/t")]
  result.env = @[("envMarker", "1")]
  result.cacheEntryIdentity = some(CacheEntryIdentity(
    packageName: "pkg", packageVersion: "1",
    selectedOptions: {"optionMarker": "on"}.newTable))
  result.toolIdentityRefs = @["toolRefMarker"]
  result.readOnlyRoots = @["readOnlyMarker"]
  result.toolIdentityRefKinds = @[tirkBuild]
  result.scratchDirs = @["scratchMarker"]
  result.removeBeforeRun = @["removeMarker"]

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
    #
    # The image comes from the real encoder running at v24. It used to be
    # spliced together instead: find the depfile path in a current-version
    # image, swap v25's ``suppressMonitorShimSeed`` byte for v24's two fields,
    # rewrite the header. That handled the one MID-PAYLOAD difference it knew
    # about and silently kept every LATER one — v26 appends the entropy
    # blessing after the policy — so the splice carried five bytes no v24
    # reader consumes and died on the decoder's trailing-bytes check. Asking
    # the encoder for a v24 image cannot go stale that way: its gates and the
    # decoder's are the same list, in the same file.
    let probe = "deps/v24-probe.d"
    let v24 = encodeBuildActionPayloadAtVersion(
      sampleAction(makeDepfilePolicy(probe)), 24'u16)
    check v24[4] == 24'u8
    check v24[5] == 0'u8
    # The v24 image really carries the two removed trusted-inputs fields: it
    # is longer than a v25 one, which replaced them with a single byte, by
    # exactly (u32 empty seq + u32 empty string) - 1.
    check v24.len - encodeBuildActionPayloadAtVersion(
      sampleAction(makeDepfilePolicy(probe)), 25'u16).len == 4 + 4 - 1

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
    # Like the v24 case above, the legacy image comes from the REAL encoder
    # asked for an older version. This file used to carry its own
    # ``encodeLegacyBuildActionPayload`` — a second, hand-maintained spelling
    # of the v1..v6 wire shape — which is the same hazard as the forgery the
    # v24 case documents, one step removed: a bump that changed an EARLY
    # field would have to be mirrored into it by hand, and a bump that forgot
    # would leave these cases green against a format nothing else writes.
    # The two encoders were byte-identical for v1..v6 when this was removed,
    # so nothing about what these cases assert changed.
    let decoded = decodeBuildActionPayload(encodeBuildActionPayloadAtVersion(
      sampleAction(makeDepfilePolicy("deps/generated.d")), 3'u16))
    check decoded.id == "compile"
    check decoded.call.arguments.len == 4
    check decoded.call.arguments[0].role == carOrdinary
    check decoded.dependencyPolicy.kind == bdpMakeDepfile
    check decoded.dependencyPolicy.depfiles == @["deps/generated.d"]
    check decoded.actionCachePolicy == acfpTimestamp

  test "version 2 payloads decode with default dependency policy":
    let decoded = decodeBuildActionPayload(encodeBuildActionPayloadAtVersion(
      sampleAction(automaticMonitorPolicy()), 2'u16))
    check decoded.id == "compile"
    check decoded.depfile == ""
    check decoded.call.arguments[0].role == carOrdinary
    check decoded.dependencyPolicy.kind == bdpDefault
    check decoded.dependencyPolicy.depfiles.len == 0
    check decoded.actionCachePolicy == acfpTimestamp

  test "a NEWER version is refused as too new, naming both versions":
    # A cache shared with a newer reprobuild maps exactly this refusal to a
    # miss (``providerSnapshotUsable``), so it must be told apart from
    # corruption by TYPE, and must carry the versions for the diagnostic.
    # The version word is a u16 LE directly after the 4-byte magic.
    var encoded = encodeBuildActionPayload(sampleAction())
    let newer = BuildActionPayloadVersion + 1'u16
    encoded[4] = byte(newer and 0xff'u16)
    encoded[5] = byte(newer shr 8)
    check buildActionPayloadVersion(encoded) == newer
    try:
      discard decodeBuildActionPayload(encoded)
      checkpoint("a newer payload decoded")
      fail()
    except BuildActionPayloadTooNewError as err:
      check err.foundVersion == newer
      check err.supportedVersion == BuildActionPayloadVersion
      check ("version " & $newer) in err.msg

  test "version 0 and a bad magic are corruption, not a newer version":
    # The narrow half: neither is a payload of another reprobuild, so neither
    # may be mistaken for one and silently treated as a cache miss.
    var zero = encodeBuildActionPayload(sampleAction())
    # version-literal-ok: zero is the structural floor below version 1,
    # never a real version, so it does not move with the current one.
    zero[4] = 0'u8
    # version-literal-ok: high byte of the same structural-floor zero.
    zero[5] = 0'u8
    var badMagic = encodeBuildActionPayload(sampleAction())
    badMagic[0] = byte(ord('X'))
    for corrupt in [zero, badMagic]:
      try:
        discard decodeBuildActionPayload(corrupt)
        fail()
      except BuildActionPayloadTooNewError:
        checkpoint("corruption raised the too-new subtype")
        fail()
      except BuildActionPayloadError:
        discard
    expect BuildActionPayloadError:
      discard buildActionPayloadVersion(badMagic)

  test "invalid dependency policy kind fails closed":
    # The kind byte is located by encoding two policies that differ ONLY in
    # their kind, never by a distance from the payload's tail: see the note on
    # ``singleDifferingByte``.
    var encoded = encodeBuildActionPayload(sampleAction(
      automaticMonitorPolicy()))
    let kindOffset = singleDifferingByte(encoded,
      encodeBuildActionPayload(sampleAction(defaultDependencyPolicy())))
    check kindOffset >= 0
    encoded[kindOffset] = 255'u8

    check decodeFailure(encoded) ==
      "invalid dependency policy kind in build action payload"

  test "invalid action cache policy fails closed":
    var encoded = encodeBuildActionPayload(sampleAction(
      actionCachePolicy = acfpTimestamp))
    let policyOffset = singleDifferingByte(encoded, encodeBuildActionPayload(
      sampleAction(actionCachePolicy = acfpChecksum)))
    check policyOffset >= 0
    encoded[policyOffset] = 255'u8

    # The message is part of the assertion. Without it this case only proves
    # that SOME payload error was raised, which is how it went on passing
    # long after the byte it corrupted had stopped being the cache policy.
    check decodeFailure(encoded) ==
      "invalid action cache policy in build action payload"

  test "a corrupted element count fails closed without allocating for it":
    # Every list in the payload is a u32 element count followed by the
    # elements. A count corrupted on disk must be refused because the bytes
    # left in the payload cannot hold that many elements. Sizing a seq by it
    # first asks for up to ``high(uint32)`` elements (~68 GB for a string
    # list) and the OOM killer, not a payload error, ends the run. That is
    # how the full suite used to die in this file.
    #
    # Each site is corrupted twice. The ``high(uint32)`` count is the one that
    # kills an unguarded decoder outright under a memory cap. The moderate one
    # fits in memory, so an unguarded decoder survives it, allocates tens to
    # hundreds of megabytes, and only then fails on a truncated element: the
    # message and peak-memory checks catch that without needing a cap.
    let encoded = encodeBuildActionPayload(markedAction())
    let sites = @[
      ("CLI arguments", countBefore(encoded, "argMarker")),
      ("typed outputs", countBefore(encoded, "typedMarker")),
      ("env", countBefore(encoded, "envMarker")),
      ("selected options", countBefore(encoded, "optionMarker")),
      ("tool identity refs", countBefore(encoded, "toolRefMarker")),
      ("tool identity ref kinds", countAfter(encoded, "readOnlyMarker")),
      ("scratch dirs", countBefore(encoded, "scratchMarker")),
      ("remove-before-run outputs", countBefore(encoded, "removeMarker"))]
    for (site, offset) in sites:
      checkpoint site
      check offset >= 0
    # Moderate counts at every site first, so an unguarded decoder reports
    # each unguarded site before the first ``high(uint32)`` count ends it.
    for count in [0x0080_0000'u32, high(uint32)]:
      for (site, offset) in sites:
        checkpoint site & " count " & $count
        let (message, peakGrowth) = decodeWithCount(encoded, offset, count)
        check message.endsWith("count exceeds remaining payload bytes")
        when declared(getMaxMem):
          # Nothing in this payload needs a megabyte; the moderate count alone
          # names 8 Mi elements.
          check peakGrowth < 1024 * 1024

  test "valid payloads with populated lists decode at every version":
    # The count bound refuses a count whose elements cannot fit in the bytes
    # left, assuming each element is at least its minimum size. A minimum set
    # too high would refuse a valid payload, and only a populated list can
    # show it: an empty one passes any bound. So every version is decoded
    # here with every count-prefixed list non-empty.
    #
    # The lists at the tail of the payload hold empty strings, each exactly
    # the four-byte minimum of a string, and one of them ends the payload. The
    # bound is then met with equality, so an off-by-one in the comparison
    # would refuse this payload. The last check of the test confirms that a
    # list of three empty strings really does end the current payload: a
    # version that appends a field after it fails there, rather than quietly
    # testing nothing at the boundary.
    var action = markedAction()
    action.scratchDirs = @["", "", ""]
    action.removeBeforeRun = @["", "", ""]
    for version in 1'u16 .. BuildActionPayloadVersion:
      checkpoint "version " & $version
      let decoded = decodeBuildActionPayload(
        encodeBuildActionPayloadAtVersion(action, version))
      check decoded.id == action.id
      check decoded.call.arguments.len == 1
      if version >= 12'u16:
        check decoded.typedOutputs.len == 1
      if version >= 14'u16:
        check decoded.env == action.env
      if version >= 23'u16:
        check decoded.toolIdentityRefKinds == action.toolIdentityRefKinds
    let currentImage = encodeBuildActionPayload(action)
    let current = decodeBuildActionPayload(currentImage)
    check current.scratchDirs == action.scratchDirs
    check current.removeBeforeRun == action.removeBeforeRun
    check current.toolIdentityRefs == action.toolIdentityRefs
    check current.readOnlyRoots == action.readOnlyRoots
    check current.cacheEntryIdentity.isSome
    check current.cacheEntryIdentity.get().selectedOptions["optionMarker"] ==
      "on"
    # A u32 count of 3 and three zero-length strings, as the last 16 bytes.
    check currentImage[^16 .. ^1] == @[3'u8, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0]

  test "version 4 payloads decode with default CLI argument formatting":
    let decoded = decodeBuildActionPayload(encodeBuildActionPayloadAtVersion(
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
    let decoded = decodeBuildActionPayload(encodeBuildActionPayloadAtVersion(
      sampleAction(makeDepfilePolicy("deps/generated.d")), 5'u16))
    check decoded.id == "compile"
    check decoded.call.arguments.len == 4
    check decoded.call.arguments[1].format == cafSeparate
    check decoded.call.arguments[1].placement == capAfterSubcommand
    check decoded.dependencyPolicy.kind == bdpMakeDepfile
