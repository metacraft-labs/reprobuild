## Real artifact serialization and decoding, with no mocks. The small-value
## digest was measured before widening the value bound at d481a2c5 plus its
## POSIX bridge, so changing both codec directions cannot bless a wire change.
##
## THE DIGEST WAS RE-PINNED AT SHARED-DEVELOPMENT-SERVICES L8, AND AGAIN AT
## L9, AND THAT IS EXACTLY WHAT THIS CASE IS FOR. L8 grew
## `DevEnvServiceSummary` by eight positional SSZ fields and moved BOTH
## version numbers with them -- `EnvelopeVersion` 1 -> 2 and
## `DevEnvArtifactSchemaVersion` 1 -> 2. L9 grew the same record by NINE more
## (the typed `service` block's readiness probe, working directory, state
## directories and `instance` block -- the facts that until then existed only
## inside a `servicePlaceholder`'s opaque JSON) and moved both numbers again,
## 2 -> 3. Either way the wire bytes of every artifact change, including this
## fixture's, which carries no services at all and therefore changes by the
## two version numbers and nothing else. The case did its job twice: it caught
## the change, and the change is intended.
##
## Re-pinning a guard is weakening it UNLESS the reason is recorded and the
## guard gains something. L8's re-pin gained three assertions: that the decoded
## artifact reports the current schema version, that an envelope carrying an
## OLD version is REFUSED BY NAME rather than read with shifted offsets, and
## that a version this build does not know YET is refused the same way.
##
## L9's re-pin gains a fourth, and it is the one that matters most in practice:
## **the IMMEDIATELY PRECEDING version is refused by name too.** Version 1 is a
## hypothetical nobody has on disk any more; version 2 is what every dev-env
## artifact cached before this change actually carries, so it is the stale
## input a developer will really hand this decoder. A guard that refused 1 and
## 3 but read 2 with shifted offsets would be wrong in exactly the case that
## occurs.
##
## A reader who re-pins the digest without those is blessing a wire change,
## which is what the first paragraph forbids.
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
    # Measured at Shared-Development-Services L9. The two superseded pins,
    # kept so the history of this guard is readable from the guard:
    #   pre-L8: 5260be4bfb09c2ffe0536e5057001b866a0b478e5e5251660495d7c54be5521e
    #   L8:     04d3aa770b1e294eb716ae258fdd56830d9e8c5da310a888cb927ae7e4eb7e53
    # The header says what moved it each time.
    check hex == "1cdd6d320513d693cb051af7c48e9faf9c9d7a1ac427cafab5bdf42b404c7844"

  test "the artifact declares schema version 3, and 1 and 2 are refused":
    # The assertions that keep the re-pin above from being a blessing.
    check decodeDevEnvArtifact(
      encodeDevEnvArtifact(fixture("small"))).schemaVersion == 3'u32
    # The envelope version is a little-endian u16 directly after the
    # 4-byte magic. PINNED rather than searched for: an earlier revision
    # of this case scanned for the first `02 00` pair, which does land on
    # offset 4 here, but a search makes the assertions below about
    # "whatever byte matched" instead of about the VERSION.
    const VersionOffset = 4
    var bytes = encodeDevEnvArtifact(fixture("small"))
    check bytes[VersionOffset] == 3'u8
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
    #
    # EVERY SUPERSEDED VERSION IS PROBED, NOT JUST THE FIRST ONE. Version 2
    # is the one that matters: it is what a dev-env artifact cached before L9
    # carries, so it is the stale input that actually occurs. Version 1 is
    # kept because a guard that only knew about its immediate predecessor
    # would read the one before that with shifted offsets.
    for superseded in [1'u8, 2'u8]:
      bytes[VersionOffset] = superseded
      var refusal = ""
      try:
        discard decodeDevEnvArtifact(bytes)
      except DevEnvArtifactCodecError as err:
        refusal = err.msg
      checkpoint("envelope version " & $superseded &
        " was not refused BY NAME; the refusal said: " & refusal)
      check ("envelope version " & $superseded) in refusal
    # ...and a version this build does not know YET is refused the same
    # way, by name, rather than read with shifted offsets.
    var future = encodeDevEnvArtifact(fixture("small"))
    future[VersionOffset] = 4'u8
    var futureRefusal = ""
    try:
      discard decodeDevEnvArtifact(future)
    except DevEnvArtifactCodecError as err:
      futureRefusal = err.msg
    check "envelope version 4" in futureRefusal

  test "value capacity is bounded independently of metadata":
    let largest = repeat("x", 128 * 1024)
    check decodeDevEnvArtifact(encodeDevEnvArtifact(fixture(largest))).shellOps[0].value == largest
    expect DevEnvArtifactCodecError:
      discard encodeDevEnvArtifact(fixture(largest & "x"))
    var named = fixture("small")
    named.shellOps[0].name = repeat("x", 16 * 1024 + 1)
    expect DevEnvArtifactCodecError:
      discard encodeDevEnvArtifact(named)
