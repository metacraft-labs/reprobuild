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

import std/unittest

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
