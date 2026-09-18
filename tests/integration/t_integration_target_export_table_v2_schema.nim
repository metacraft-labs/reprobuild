## Spec-Implementation M5 — target-export-table v2 schema verification.
##
## Build-Graph-Collections.md §"Persistence and the Target-Export
## Table" specifies the v1 → v2 bump:
##   - v2 expands the ``kind`` enumeration from ``{implicit, explicit}``
##     to ``{implicit, explicit, aggregate, collection}``.
##   - v1 payloads still decode under the v2 decoder, with the
##     original two-value ``kind`` enumeration only.
##   - v2 payloads round-trip every kind including the M5 additions.
##
## This test asserts the codec's wire-format contract by emitting and
## decoding both versions directly through the public payload procs.

import std/[strutils, unittest]

import repro_project_dsl

suite "Spec-Implementation M5: target-export-table v2 schema":

  test "v2 payload round-trips every row kind":
    let table = TargetExportTable(
      entries: @[
        TargetExportEntry(
          name: "out",
          kind: tekImplicit,
          owningPackage: "pkgA",
          actionId: "act-1",
          sourceFile: "fileA.nim",
          sourceLine: 10),
        TargetExportEntry(
          name: "release",
          kind: tekExplicit,
          owningPackage: "pkgB",
          actionId: "act-2",
          sourceFile: "fileB.nim",
          sourceLine: 20),
        TargetExportEntry(
          name: "docs",
          kind: tekAggregate,
          owningPackage: "pkgC",
          actionId: "act-3",
          sourceFile: "fileC.nim",
          sourceLine: 30),
        TargetExportEntry(
          name: "test",
          kind: tekCollection,
          owningPackage: "pkgD",
          actionId: "act-4",
          sourceFile: "fileD.nim",
          sourceLine: 40),
      ])

    let bytes = encodeTargetExportTablePayload(table)
    let decoded = decodeTargetExportTablePayload(bytes)

    check decoded.entries.len == 4
    check decoded.entries[0].kind == tekImplicit
    check decoded.entries[1].kind == tekExplicit
    check decoded.entries[2].kind == tekAggregate
    check decoded.entries[3].kind == tekCollection

    # Round-trip every field on the collection row so the codec's
    # field order is verified end-to-end.
    let collectionRow = decoded.entries[3]
    check collectionRow.name == "test"
    check collectionRow.owningPackage == "pkgD"
    check collectionRow.actionId == "act-4"
    check collectionRow.sourceFile == "fileD.nim"
    check collectionRow.sourceLine == 40

  test "v1 payload decodes under v2 decoder with original two-value kind":
    # Build a v1-shaped payload by hand. v1 only knew ``tekImplicit``
    # / ``tekExplicit`` kinds; the envelope version is ``1``.
    var payload: seq[byte] = @[]

    proc writeU32(buf: var seq[byte]; value: uint32) =
      for shift in [0, 8, 16, 24]:
        buf.add(byte((value shr shift) and 0xff'u32))

    proc writeStr(buf: var seq[byte]; s: string) =
      writeU32(buf, uint32(s.len))
      for ch in s:
        buf.add(byte(ord(ch)))

    # entries count = 2
    writeU32(payload, 2'u32)
    # entry 0: implicit
    writeStr(payload, "outA")
    payload.add(byte(0))  # tekImplicit
    writeStr(payload, "pkgA")
    writeStr(payload, "act-1")
    writeStr(payload, "f.nim")
    writeU32(payload, 11'u32)
    # entry 1: explicit
    writeStr(payload, "release")
    payload.add(byte(1))  # tekExplicit
    writeStr(payload, "pkgB")
    writeStr(payload, "act-2")
    writeStr(payload, "g.nim")
    writeU32(payload, 22'u32)
    # ambiguities count = 0
    writeU32(payload, 0'u32)

    # Envelope: magic ("RTET") + version (v1 = 1) + payload length.
    var bytes: seq[byte] = @[
      byte(ord('R')), byte(ord('T')), byte(ord('E')), byte(ord('T'))
    ]
    var versionBytes: seq[byte] = @[]
    versionBytes.add(byte(1'u16 and 0xff'u16))
    versionBytes.add(byte((1'u16 shr 8) and 0xff'u16))
    bytes.add(versionBytes)
    var lenBytes: seq[byte] = @[]
    writeU32(lenBytes, uint32(payload.len))
    bytes.add(lenBytes)
    bytes.add(payload)

    let decoded = decodeTargetExportTablePayload(bytes)
    check decoded.entries.len == 2
    check decoded.entries[0].kind == tekImplicit
    check decoded.entries[0].name == "outA"
    check decoded.entries[1].kind == tekExplicit
    check decoded.entries[1].name == "release"

  test "v2 decoder rejects out-of-range kind bytes":
    # Build a v2-version payload whose kind byte names a value beyond
    # the current ``tekCollection`` (3) ceiling. The decoder must
    # reject it — this guards against on-disk corruption sneaking
    # an unknown kind through.
    var payload: seq[byte] = @[]

    proc writeU32(buf: var seq[byte]; value: uint32) =
      for shift in [0, 8, 16, 24]:
        buf.add(byte((value shr shift) and 0xff'u32))

    proc writeStr(buf: var seq[byte]; s: string) =
      writeU32(buf, uint32(s.len))
      for ch in s:
        buf.add(byte(ord(ch)))

    writeU32(payload, 1'u32)        # entries count = 1
    writeStr(payload, "x")
    payload.add(byte(4))            # kind = 4, beyond tekCollection (3)
    writeStr(payload, "pkg")
    writeStr(payload, "id")
    writeStr(payload, "f.nim")
    writeU32(payload, 0'u32)
    writeU32(payload, 0'u32)        # ambiguities count = 0

    var bytes: seq[byte] = @[
      byte(ord('R')), byte(ord('T')), byte(ord('E')), byte(ord('T'))
    ]
    var versionBytes: seq[byte] = @[]
    versionBytes.add(byte(2'u16 and 0xff'u16))
    versionBytes.add(byte((2'u16 shr 8) and 0xff'u16))
    bytes.add(versionBytes)
    var lenBytes: seq[byte] = @[]
    writeU32(lenBytes, uint32(payload.len))
    bytes.add(lenBytes)
    bytes.add(payload)

    var raised = false
    try:
      discard decodeTargetExportTablePayload(bytes)
    except BuildActionPayloadError:
      raised = true
    check raised

  test "build-target payload v3 round-trips kind discriminator":
    # The ``BuildTargetDef`` payload codec gained a v3 ``kind`` byte
    # in M5. Verify both halves of the discriminator round-trip and
    # that v2 payloads (no ``kind`` byte) decode with the default
    # ``btkAggregate`` value per the backward-compat rule.
    let collectionTarget = BuildTargetDef(
      name: "test",
      actions: @["act-1"],
      targets: @[],
      sourceFile: "x.nim",
      sourceLine: 7,
      kind: btkCollection)
    let aggregateTarget = BuildTargetDef(
      name: "docs",
      actions: @["act-2"],
      targets: @[],
      sourceFile: "y.nim",
      sourceLine: 8,
      kind: btkAggregate)

    let collBytes = encodeBuildTargetPayload(collectionTarget)
    let aggBytes = encodeBuildTargetPayload(aggregateTarget)

    let collDecoded = decodeBuildTargetPayload(collBytes)
    let aggDecoded = decodeBuildTargetPayload(aggBytes)

    check collDecoded.kind == btkCollection
    check collDecoded.name == "test"
    check collDecoded.sourceLine == 7

    check aggDecoded.kind == btkAggregate
    check aggDecoded.name == "docs"
    check aggDecoded.sourceLine == 8

  test "historical build-target payloads decode under the v5 decoder":
    ## THE COMPATIBILITY CLAIM, EXERCISED RATHER THAN ASSERTED.
    ##
    ## ``btkTarget`` was APPENDED to ``BuildTargetKind`` rather than
    ## inserted, because the payload's ``kind`` byte is positional: a
    ## payload written before that value existed carries 0 for
    ## ``btkAggregate`` and 1 for ``btkCollection``, and an inserted value
    ## would have silently re-read every stored 1 as something else.
    ##
    ## The case above round-trips through the CURRENT encoder, so it
    ## cannot see a regression of that kind — both sides would move
    ## together. Its own comment promises that "v2 payloads (no ``kind``
    ## byte) decode with the default ``btkAggregate`` value", and its body
    ## never builds a v2 payload. These bytes are laid out by hand at each
    ## historical version instead, so the decoder is asked the question a
    ## stored snapshot would ask it.
    proc u32le(value: int): seq[byte] =
      for shift in [0, 8, 16, 24]:
        result.add(byte((uint32(value) shr shift) and 0xff'u32))

    proc str(value: string): seq[byte] =
      result = u32le(value.len)
      for ch in value:
        result.add(byte(ord(ch)))

    proc strSeq(values: openArray[string]): seq[byte] =
      result = u32le(values.len)
      for value in values:
        result.add(str(value))

    proc payload(version: int; kindByte: int; withExtensions: bool):
        seq[byte] =
      var body: seq[byte] = @[]
      body.add(str("docs"))
      body.add(strSeq(["act-1"]))
      body.add(strSeq([]))
      if version >= 2:
        body.add(str("recipe.nim"))
        body.add(u32le(11))
      if version >= 3:
        body.add(byte(kindByte))
      if withExtensions:
        body.add(u32le(0))
      result = @[byte(ord('R')), byte(ord('B')), byte(ord('T')),
                 byte(ord('P'))]
      result.add(byte(version and 0xff))
      result.add(byte((version shr 8) and 0xff))
      result.add(u32le(body.len))
      result.add(body)

    # v1: no source location, no kind byte at all.
    let v1 = decodeBuildTargetPayload(payload(1, 0, false))
    check v1.name == "docs"
    check v1.actions == @["act-1"]
    check v1.kind == btkAggregate
    check v1.sourceFile == ""
    check v1.sourceLine == 0

    # v2: source location, still no kind byte.
    let v2 = decodeBuildTargetPayload(payload(2, 0, false))
    check v2.kind == btkAggregate
    check v2.sourceFile == "recipe.nim"
    check v2.sourceLine == 11

    # v3/v4: the stored byte still means what it meant when it was
    # written. The ``1`` cases are the ones an inserted enum value would
    # have broken.
    check decodeBuildTargetPayload(payload(3, 0, false)).kind == btkAggregate
    check decodeBuildTargetPayload(payload(3, 1, false)).kind == btkCollection
    check decodeBuildTargetPayload(payload(4, 0, true)).kind == btkAggregate
    check decodeBuildTargetPayload(payload(4, 1, true)).kind == btkCollection

    # v5 is the version this tree writes, and 2 is the value it adds.
    check decodeBuildTargetPayload(payload(5, 2, true)).kind == btkTarget
    let encodedVersion = block:
      let bytes = encodeBuildTargetPayload(BuildTargetDef(
        name: "docs", actions: @["act-1"], kind: btkTarget))
      int(bytes[4]) or (int(bytes[5]) shl 8)
    check encodedVersion == 5

    # A byte past the enum is refused rather than cast.
    var badKindRaised = false
    try:
      discard decodeBuildTargetPayload(payload(5, 3, true))
    except BuildActionPayloadError:
      badKindRaised = true
    check badKindRaised

    # An engine built before this change takes THIS path on a payload a
    # newer provider wrote — the version is rejected by name instead of
    # the kind byte being reported as corrupt. Exercised here from the
    # other side: a version this decoder does not know yet.
    var futureVersionMessage = ""
    try:
      discard decodeBuildTargetPayload(payload(6, 2, true))
    except BuildActionPayloadError:
      futureVersionMessage = getCurrentExceptionMsg()
    check futureVersionMessage.contains(
      "unsupported build target payload version")
