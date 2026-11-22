## An interface envelope newer than the engine reading it is refused with a
## message that names BOTH versions, and that message is recognised as such.
##
## Spec: Unified-Locking-And-Hooks.md §13.5, "An engine older than the
## interface envelope" (amended 2026-11-22). Observed 2026-11-22: a gate anchored to a build that reads envelope 33 met a recipe
## compiled against a checkout writing 36, and its decode said only
## "unsupported interface envelope version", so the pre-push gate could tell
## neither the operator nor itself that the ENGINE was too old.
##
## What is asserted, against the real codec (`encodeProjectInterfaceArtifact`
## / `decodeProjectInterfaceArtifact`) with the version bytes rewritten:
##
##   1. the first unknown version is refused with a message naming it and the
##      newest version this build reads (fails before the fix: the message
##      carried no number);
##   2. `interfaceEnvelopeSkewIn` recognises that message, also when it is
##      wrapped inside a longer diagnostic, and returns both numbers;
##   3. controls: version 0 (malformed, not newer) is refused but NOT read as
##      a newer engine's; the current version decodes; text without the
##      refusal yields nothing;
##   4. `sdkWrittenInterfaceEnvelopeVersion` reads this checkout's own
##      declaration, which is the version this build writes.
##
## NO MOCKS: the real encoder and decoder, and this repository's own source
## file for (4).

import std/[os, strutils, unittest]

import repro_core
import repro_interface_artifacts
import repro_project_dsl  # ProjectInterface

proc withVersion(version: uint16): seq[byte] =
  ## A real encoded artifact whose envelope header claims ``version``. The
  ## version is the little-endian u16 after the four magic bytes.
  result = encodeProjectInterfaceArtifact(artifactFor(ProjectInterface()))
  result[4] = byte(version and 0xff'u16)
  result[5] = byte((version shr 8) and 0xff'u16)

proc decodeMessage(bytes: seq[byte]): string =
  try:
    discard decodeProjectInterfaceArtifact(bytes)
  except EnvelopeError as err:
    return err.msg
  ""

suite "an envelope newer than the engine names both versions":

  test "the refusal of a newer envelope carries both version numbers":
    let current = interfaceEnvelopeVersion()
    let newer = firstUnknownInterfaceEnvelopeVersion()
    # Control: the same bytes at the current version decode.
    check decodeMessage(withVersion(current)) == ""
    let msg = decodeMessage(withVersion(newer))
    checkpoint("decode refusal: " & msg)
    check msg.startsWith(UnsupportedInterfaceEnvelopePhrase)
    check msg.contains(" " & $newer & " ")
    check msg.contains("1 through " & $current)

  test "the refusal is recognised, also inside a wrapped diagnostic":
    let newer = firstUnknownInterfaceEnvelopeVersion()
    let msg = decodeMessage(withVersion(newer))
    let wrapped = "could not read the solve of /ws/app: repro interface " &
      "extract: error: " & msg & "\n(exit 1)"
    let skew = interfaceEnvelopeSkewIn(wrapped)
    check skew.found
    check skew.written == int(newer)
    check skew.readable == int(interfaceEnvelopeVersion())

  test "a malformed version is refused but is not a newer engine's":
    let msg = decodeMessage(withVersion(0'u16))
    checkpoint("decode refusal: " & msg)
    check msg.startsWith(UnsupportedInterfaceEnvelopePhrase)
    check not interfaceEnvelopeSkewIn(msg).found
    check not interfaceEnvelopeSkewIn("repro lock refresh: the recipe does " &
      "not compile").found
    # The bare pre-2026-11-22 wording names no version: nothing to report.
    check not interfaceEnvelopeSkewIn(UnsupportedInterfaceEnvelopePhrase).found

  test "an SDK's declared envelope version is read from its source":
    let checkout = currentSourcePath().parentDir.parentDir.parentDir.parentDir
    check sdkWrittenInterfaceEnvelopeVersion(checkout) ==
      int(interfaceEnvelopeVersion())
    check sdkWrittenInterfaceEnvelopeVersion(checkout / "no-such-sdk") == 0
