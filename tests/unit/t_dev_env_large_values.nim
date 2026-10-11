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
    # Measured at Shared-Development-Services D-SS11. The three
    # superseded pins, kept so the history of this guard is readable
    # from the guard:
    #   pre-L8: 5260be4bfb09c2ffe0536e5057001b866a0b478e5e5251660495d7c54be5521e
    #   L8:     04d3aa770b1e294eb716ae258fdd56830d9e8c5da310a888cb927ae7e4eb7e53
    #   L9:     1cdd6d320513d693cb051af7c48e9faf9c9d7a1ac427cafab5bdf42b404c7844
    # The header says what moved it each time. D-SS11 moved it by adding
    # `DevEnvArtifact.sharedResolutions` -- a new variable-size SSZ
    # field, so the container's fixed portion grew by one 4-byte offset
    # entry and every later offset shifted -- and by moving both version
    # numbers 3 -> 4.
    #
    # THIS FIXTURE CARRIES NO RESOLUTION, which is what makes the pin
    # worth having: the digest moved for the SCHEMA, not for content, so
    # an implementation that added the field without moving the versions
    # would fail the two cases below rather than this one.
    check hex == "2758a09be9e22f307c4dd3d267947f15520e530d00e5027bf00066998421631c"

  test "the declared schema version is pinned, and every superseded envelope version is refused":
    # The assertions that keep the re-pin above from being a blessing.
    check decodeDevEnvArtifact(
      encodeDevEnvArtifact(fixture("small"))).schemaVersion == 4'u32
    # The envelope version is a little-endian u16 directly after the
    # 4-byte magic. PINNED rather than searched for: an earlier revision
    # of this case scanned for the first `02 00` pair, which does land on
    # offset 4 here, but a search makes the assertions below about
    # "whatever byte matched" instead of about the VERSION.
    const VersionOffset = 4
    var bytes = encodeDevEnvArtifact(fixture("small"))
    # THE ONE DELIBERATE PIN, and it is deliberate: this number is meant
    # to need a hand edit when the envelope moves, so that a bump is a
    # conscious act with a reviewer attached. It is the ONLY numeric
    # envelope version left in this file; every PROBE below is relative
    # to `devEnvEnvelopeVersion()` instead. That split is the fix for a
    # defect generator -- a probe pinned to a literal goes on passing
    # while measuring the wrong property, whereas this pin fails loudly
    # and names itself. The schema gate below already worked this way
    # (`DevEnvArtifactSchemaVersion - 1`); the envelope gate now does.
    check devEnvEnvelopeVersion() == 4'u16
    # The ENCODER writes the current version at that offset. Relative,
    # and it is the control for the pokes below: if the offset were
    # wrong, every refusal below would be a checksum failure that said
    # nothing about the version.
    check bytes[VersionOffset] ==
      byte(devEnvEnvelopeVersion() and 0xff'u16)
    check bytes[VersionOffset + 1] ==
      byte((devEnvEnvelopeVersion() shr 8) and 0xff'u16)
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
    #
    # DERIVED FROM THE CURRENT VERSION rather than listed. The list used
    # to be `[1, 2, 3]`, which meant "every version below 4" and had to
    # be extended by hand on each bump -- and a bump that forgot would
    # leave the newly superseded version unprobed WITHOUT failing
    # anything, which is the silent half of this file's own subject.
    # `1 ..< devEnvEnvelopeVersion()` is the same set, stated as what it
    # is. The loop also asserts it is non-empty, because an empty range
    # would make this whole block vacuous.
    var supersededProbed = 0
    for superseded in 1'u16 ..< devEnvEnvelopeVersion():
      bytes[VersionOffset] = byte(superseded and 0xff'u16)
      bytes[VersionOffset + 1] = byte((superseded shr 8) and 0xff'u16)
      var refusal = ""
      try:
        discard decodeDevEnvArtifact(bytes)
      except DevEnvArtifactCodecError as err:
        refusal = err.msg
      checkpoint("envelope version " & $superseded &
        " was not refused BY NAME; the refusal said: " & refusal)
      check ("envelope version " & $superseded) in refusal
      inc supersededProbed
    check supersededProbed == int(devEnvEnvelopeVersion()) - 1
    check supersededProbed > 0
    # ...and a version this build does not know YET is refused the same
    # way, by name, rather than read with shifted offsets. The FIRST
    # unknown one, named rather than hard-coded: pinned to a literal
    # this probe would land ON the current version after a bump and
    # would then be measuring that the current version decodes, which it
    # does and must.
    let unknown = firstUnknownDevEnvEnvelopeVersion()
    check unknown == devEnvEnvelopeVersion() + 1
    var future = encodeDevEnvArtifact(fixture("small"))
    future[VersionOffset] = byte(unknown and 0xff'u16)
    future[VersionOffset + 1] = byte((unknown shr 8) and 0xff'u16)
    var futureRefusal = ""
    try:
      discard decodeDevEnvArtifact(future)
    except DevEnvArtifactCodecError as err:
      futureRefusal = err.msg
    check ("envelope version " & $unknown) in futureRefusal

  test "the SCHEMA gate is independent of the envelope gate, and it fires":
    # WHAT THIS CASE ADDS, and it is the gain that makes the re-pin above
    # something other than a blessing.
    #
    # The codec has TWO equality gates on two different numbers:
    # `parseEnvelope` refuses an unexpected `EnvelopeVersion` (the u16
    # after the magic) and `decodeDevEnvArtifactSszPayload` refuses an
    # unexpected `DevEnvArtifactSchemaVersion` (a u32 inside the
    # payload). Every assertion in the case above flips the ENVELOPE
    # byte, so the schema gate was asserted as a VALUE and never
    # exercised as a REFUSAL -- deleting it would have left that case
    # green, which is exactly the shape of unprotected guard this file's
    # header exists to refuse.
    #
    # The payload is produced by the real encoder with the schema field
    # set to the immediately preceding version, which is the stale input
    # that actually occurs: a dev-env artifact cached by the previous
    # build. `encodeDevEnvArtifact` only fills the field when it is 0
    # and recomputes `artifactId` over the result, so the envelope is
    # well-formed, the checksum matches and the identity matches -- the
    # ONLY thing wrong with these bytes is the schema version, and the
    # refusal has to name it.
    var stale = fixture("small")
    stale.schemaVersion = DevEnvArtifactSchemaVersion - 1
    var refusal = ""
    try:
      discard decodeDevEnvArtifact(encodeDevEnvArtifact(stale))
    except DevEnvArtifactCodecError as err:
      refusal = err.msg
    checkpoint("the schema gate did not refuse by name; it said: " & refusal)
    check "schema version " & $(DevEnvArtifactSchemaVersion - 1) in refusal
    # And the envelope was NOT the thing that refused: a reader that
    # answered on the envelope here would be reporting the wrong number.
    check "envelope version" notin refusal

  test "value capacity is bounded independently of metadata":
    let largest = repeat("x", 128 * 1024)
    check decodeDevEnvArtifact(encodeDevEnvArtifact(fixture(largest))).shellOps[0].value == largest
    expect DevEnvArtifactCodecError:
      discard encodeDevEnvArtifact(fixture(largest & "x"))
    var named = fixture("small")
    named.shellOps[0].name = repeat("x", 16 * 1024 + 1)
    expect DevEnvArtifactCodecError:
      discard encodeDevEnvArtifact(named)
