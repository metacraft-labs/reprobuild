## Cross-Repo-Source-Consumption §4.2a.2a: ``InterfaceLibrary.sourceGitlinks``
## on the canonical interface envelope (v38).
##
## The requirement is MANDATORY source semantics, so the properties are:
##
## * it round-trips through the current envelope, on disk too, and is part
##   of the interface fingerprint (a consumer must not reuse a lift that
##   did not carry it);
## * a v37 payload (written before the field existed) decodes it EMPTY --
##   the empty default is for a new reader decoding an old payload;
## * a nonempty requirement is NEVER encoded at v<38, where an old reader
##   would decode the row without it: the writer raises instead;
## * an envelope newer than the reader is refused by its version, which is
##   how a v37 engine meets a v38 payload carrying the requirement;
## * a library declaring none keeps the fingerprint it had at v37 (the
##   block is omitted from the fingerprint projection when empty).
##
## Test-double policy: NO mocks. Every payload comes from the real
## ``encodeInterfacePayload`` / ``encodeProjectInterfaceArtifact`` and goes
## back through the real decoders.

import std/[os, strutils, unittest]

import repro_hash
import repro_interface_artifacts
import repro_project_dsl

proc addU16Le(outp: var seq[byte]; value: uint16) =
  outp.add(byte(value and 0xff'u16))
  outp.add(byte((value shr 8) and 0xff'u16))

proc addU32Le(outp: var seq[byte]; value: uint32) =
  outp.add(byte(value and 0xff'u32))
  outp.add(byte((value shr 8) and 0xff'u32))
  outp.add(byte((value shr 16) and 0xff'u32))
  outp.add(byte((value shr 24) and 0xff'u32))

proc envelopeAt(pi: ProjectInterface; version: uint16): seq[byte] =
  ## A complete artifact envelope at ``version``, framed as
  ## ``encodeProjectInterfaceArtifact`` frames the current one.
  var payload = encodeInterfacePayload(pi, version)
  let fingerprint = blake3DomainDigest(
    encodeInterfacePayload(pi, version, forFingerprint = true),
    hdMetadataEnvelope)
  payload.add(byte(ord(fingerprint.algorithm)))
  payload.add(byte(ord(fingerprint.domain)))
  payload.add(fingerprint.bytes)
  payload.add(if pi.standardBuildEligible: 1'u8 else: 0'u8)
  result.add([byte(ord('R')), byte(ord('B')), byte(ord('S')), byte(ord('Z'))])
  result.addU16Le(version)
  result.addU16Le(101'u16)
  result.addU32Le(uint32(payload.len))
  result.add(payload)

proc yogaLibrary(): InterfaceLibrary =
  InterfaceLibrary(name: "isonim", kind: lkStatic, exportedPath: "src",
    location: SourceLocation(file: "repro.nim", line: 832),
    sourceGitlinks: @[
      GitlinkSourceRequirement(relativePath: "src/isonim/layout/yoga"),
      GitlinkSourceRequirement(relativePath: "src/vendor/other")])

proc interfaceWith(lib: InterfaceLibrary): ProjectInterface =
  result.projectName = "isonim"
  result.packageName = "isonim"
  result.publicLibraries.add(lib)

suite "InterfaceLibrary.sourceGitlinks on the interface envelope":
  test "the current envelope carries sourceGitlinks (v38 or later)":
    # version-literal-ok: v38 is the frozen first envelope version that carries sourceGitlinks
    check interfaceEnvelopeVersion() >= 38'u16

  test "sourceGitlinks round-trip in order, on disk too":
    let artifact = artifactFor(interfaceWith(yogaLibrary()))
    let decoded = decodeProjectInterfaceArtifact(
      encodeProjectInterfaceArtifact(artifact))
    check decoded.projectInterface.publicLibraries.len == 1
    let lib = decoded.projectInterface.publicLibraries[0]
    check lib.exportedPath == "src"
    check lib.location.line == 832
    check lib.sourceGitlinks == yogaLibrary().sourceGitlinks
    check decoded.interfaceFingerprint == artifact.interfaceFingerprint
    let scratch = getTempDir() / ("t_library_source_gitlinks_codec-" &
      $getCurrentProcessId() & ".rbsz")
    defer:
      if fileExists(scratch): removeFile(scratch)
    writeInterfaceArtifact(scratch, artifact)
    check readInterfaceArtifact(scratch).projectInterface.publicLibraries[0]
      .sourceGitlinks == yogaLibrary().sourceGitlinks

  test "the requirement is part of the interface fingerprint":
    var plain = yogaLibrary()
    plain.sourceGitlinks = @[]
    check artifactFor(interfaceWith(plain)).interfaceFingerprint !=
      artifactFor(interfaceWith(yogaLibrary())).interfaceFingerprint
    var other = yogaLibrary()
    other.sourceGitlinks[1].relativePath = "src/vendor/changed"
    check artifactFor(interfaceWith(other)).interfaceFingerprint !=
      artifactFor(interfaceWith(yogaLibrary())).interfaceFingerprint

  test "a v37 payload decodes the requirement empty":
    var plain = yogaLibrary()
    plain.sourceGitlinks = @[]
    let decoded = decodeProjectInterfaceArtifact(
      envelopeAt(interfaceWith(plain), 37'u16))
    check decoded.projectInterface.publicLibraries.len == 1
    check decoded.projectInterface.publicLibraries[0].exportedPath == "src"
    check decoded.projectInterface.publicLibraries[0].sourceGitlinks.len == 0

  test "a nonempty requirement is never encoded at a version without it":
    # The negative control: the same interface WITHOUT the requirement
    # encodes at v37, so the raise below is about the requirement alone.
    var plain = yogaLibrary()
    plain.sourceGitlinks = @[]
    check encodeInterfacePayload(interfaceWith(plain), 37'u16).len > 0
    var refusal = ""
    try:
      discard encodeInterfacePayload(interfaceWith(yogaLibrary()), 37'u16)
    except CatchableError as err:
      refusal = err.msg
    check refusal.contains("declares sourceGitlinks")
    check refusal.contains("version 37")
    refusal = ""
    try:
      discard encodeInterfacePayload(interfaceWith(yogaLibrary()), 37'u16,
        forFingerprint = true)
    except CatchableError as err:
      refusal = err.msg
    check refusal.contains("declares sourceGitlinks")

  test "the requirement-bearing envelope is refused by a reader too old for it":
    # The encoder stamps the version the requirement needs ...
    let encoded = encodeProjectInterfaceArtifact(
      artifactFor(interfaceWith(yogaLibrary())))
    check (uint16(encoded[4]) or (uint16(encoded[5]) shl 8)) >= 38'u16
    # ... and a reader meets a version it does not know with a refusal, not
    # a decode that drops the field. (This reader stands in for the old one
    # by being offered one version past its own; the same bytes at its own
    # version decode, which is the control.)
    var restamped = encoded
    let newer = firstUnknownInterfaceEnvelopeVersion()
    restamped[4] = byte(newer and 0xff'u16)
    restamped[5] = byte(newer shr 8)
    var refusal = ""
    try:
      discard decodeProjectInterfaceArtifact(restamped)
    except CatchableError as err:
      refusal = err.msg
    check refusal.contains(UnsupportedInterfaceEnvelopePhrase)
    check refusal.contains($newer)
    check decodeProjectInterfaceArtifact(encoded).projectInterface
      .publicLibraries[0].sourceGitlinks.len == 2

  test "a library declaring none keeps its v37 fingerprint":
    var plain = yogaLibrary()
    plain.sourceGitlinks = @[]
    let pi = interfaceWith(plain)
    check encodeInterfacePayload(pi, 38'u16, forFingerprint = true) ==
      encodeInterfacePayload(pi, 37'u16, forFingerprint = true)
    # ...while the wire payload does carry the (empty) block at v38.
    check encodeInterfacePayload(pi, 38'u16).len ==
      encodeInterfacePayload(pi, 37'u16).len + 4
