## Real artifact serialization and decoding, with no mocks. The small-value
## digest was measured before widening the value bound at d481a2c5 plus its
## POSIX bridge, so changing both codec directions cannot bless a wire change.
##
## THE DIGEST WAS RE-PINNED AT SHARED-DEVELOPMENT-SERVICES L8, AND THAT IS
## EXACTLY WHAT THIS CASE IS FOR. L8 grew `DevEnvServiceSummary` by eight
## positional SSZ fields and moved BOTH version numbers with them --
## `EnvelopeVersion` 1 -> 2 and `DevEnvArtifactSchemaVersion` 1 -> 2 -- so the
## wire bytes of every artifact changed, including this fixture's, which
## carries no services at all and therefore changed by the two version numbers
## and nothing else. The case did its job: it caught the change, and the
## change is intended.
##
## Re-pinning a guard is weakening it UNLESS the reason is recorded and the
## guard gains something, so this one gains three assertions it did not have:
## that the decoded artifact reports schema version 2, that an envelope
## carrying the OLD version is REFUSED BY NAME rather than read with shifted
## offsets, and that a version this build does not know YET is refused the
## same way. A reader who re-pins the digest without those is blessing a
## wire change, which is what the first paragraph forbids.
##
## "BY NAME" IS LOAD-BEARING IN THAT SENTENCE, and the case asserts the
## refusal's MESSAGE for the reason recorded at the case itself: the envelope
## trailer checksums the header, so every corruption of the version bytes
## raises `DevEnvArtifactCodecError` whether or not the version is checked at
## all. An exception-type assertion here is satisfied by the checksum and
## says nothing about the guard.
import std/[strutils, unittest]
import blake3
import repro_dev_env_artifacts
import repro_provider_runtime

proc fixture(value: string): DevEnvArtifact =
  DevEnvArtifact(projectRoot: "/fixture", shellOps: @[
    DevEnvShellOp(kind: deskSetEnv, name: "FIXTURE", value: value)])

suite "dev-env large environment values":
  test "Nix-sized values round-trip through the real SSZ envelope":
    let value = repeat(" -isystem /nix/store/dependency/include", 900)
    check value.len > 16 * 1024
    let encoded = encodeDevEnvArtifact(fixture(value))
    let decoded = decodeDevEnvArtifact(encoded)
    check decoded.shellOps.len == 1
    check decoded.shellOps[0].value == value
    check encodeDevEnvArtifact(decoded) == encoded

  test "small artifacts retain the pre-change wire bytes":
    let digest = blake3.digest(encodeDevEnvArtifact(fixture("small")))
    var hex = ""
    for b in digest: hex.add(toHex(int(b), 2).toLowerAscii())
    # Measured at Shared-Development-Services L8; the pre-L8 pin was
    # 5260be4bfb09c2ffe0536e5057001b866a0b478e5e5251660495d7c54be5521e
    # and the header says what moved it.
    check hex == "04d3aa770b1e294eb716ae258fdd56830d9e8c5da310a888cb927ae7e4eb7e53"

  test "the artifact declares schema version 2, and version 1 is refused":
    # The two assertions that keep the re-pin above from being a blessing.
    check decodeDevEnvArtifact(
      encodeDevEnvArtifact(fixture("small"))).schemaVersion == 2'u32
    # The envelope version is a little-endian u16 directly after the
    # 4-byte magic. PINNED rather than searched for: an earlier revision
    # of this case scanned for the first `02 00` pair, which does land on
    # offset 4 here, but a search makes the assertions below about
    # "whatever byte matched" instead of about the VERSION.
    const VersionOffset = 4
    var bytes = encodeDevEnvArtifact(fixture("small"))
    check bytes[VersionOffset] == 2'u8
    check bytes[VersionOffset + 1] == 0'u8
    #
    # AND THE REFUSAL IS ASSERTED ON ITS MESSAGE, NOT ON THE EXCEPTION
    # TYPE. The envelope trailer checksums the header, so EVERY
    # corruption of these bytes raises `DevEnvArtifactCodecError` --
    # which means a bare `expect DevEnvArtifactCodecError` passes with
    # the version equality check DELETED, and the guard this case exists
    # to hold would be unprotected. Measured 2026-10-11 by disabling
    # `if version != EnvelopeVersion` in codec.nim: the type-only
    # assertion still reported [OK] and the refusal silently became
    # "dev-env artifact checksum mismatch".
    bytes[VersionOffset] = 1'u8
    var refusal = ""
    try:
      discard decodeDevEnvArtifact(bytes)
    except DevEnvArtifactCodecError as err:
      refusal = err.msg
    check "envelope version 1" in refusal
    # ...and a version this build does not know YET is refused the same
    # way, by name, rather than read with shifted offsets.
    var future = encodeDevEnvArtifact(fixture("small"))
    future[VersionOffset] = 3'u8
    var futureRefusal = ""
    try:
      discard decodeDevEnvArtifact(future)
    except DevEnvArtifactCodecError as err:
      futureRefusal = err.msg
    check "envelope version 3" in futureRefusal

  test "value capacity is bounded independently of metadata":
    let largest = repeat("x", 128 * 1024)
    check decodeDevEnvArtifact(encodeDevEnvArtifact(fixture(largest))).shellOps[0].value == largest
    expect DevEnvArtifactCodecError:
      discard encodeDevEnvArtifact(fixture(largest & "x"))
    var named = fixture("small")
    named.shellOps[0].name = repeat("x", 16 * 1024 + 1)
    expect DevEnvArtifactCodecError:
      discard encodeDevEnvArtifact(named)
