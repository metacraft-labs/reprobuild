## The three voice-model packages, and why model weights are packages at all.
##
## A desktop build that ships offline speech has to put the weights in the
## installer, and the usual way that happens is a provisioning script run as
## a build step. That is a network fetch inside a build: it succeeds on any
## machine with a network, so it stays invisible until the build runs on one
## without — and then it fails at PACKAGING time rather than at
## dependency-resolution time, which is the wrong end of the build to learn
## that an input is missing.
##
## Declaring them moves the fetch to resolution, makes it substitutable from
## the shared binary cache, and makes "which weights does this installer
## contain" a question the graph answers.
##
## What these cases pin is the three decisions that are easy to get wrong:
## the payload is raw rather than an archive, the pair of files that make one
## Piper voice agree on their revision, and none of the three carry a
## platform — because the bytes do not vary by host, and a stray ``os =``
## would make the weights unresolvable everywhere else.

import std/[sequtils, strutils, unittest]

import repro_project_dsl

import repro_dsl_stdlib/packages/whisper_ggml_base
import repro_dsl_stdlib/packages/piper_voice_lessac_medium
import repro_dsl_stdlib/packages/piper_voice_lessac_medium_config

proc slices(name: string): seq[TarballProvisioningDef] =
  let hits = registeredPackages().filterIt(it.packageName == name)
  doAssert hits.len == 1, "expected one package named " & name
  hits[0].tarballProvisioning

const VoicePackages = [
  "whisper-ggml-base",
  "piper-voice-lessac-medium",
  "piper-voice-lessac-medium-config",
]

suite "the bundled voice models":

  test "the payload is the file, so the archive type is raw":
    # None of the three is an archive. ``raw`` copies the downloaded file
    # into the prefix under the declared name; any other type would send it
    # to an extractor that cannot read it.
    for name in VoicePackages:
      let entries = slices(name)
      check entries.len == 1
      checkpoint(name & " -> " & entries[0].archiveType)
      check entries[0].archiveType == "raw"
      # ``raw`` uses executablePath as the DESTINATION FILENAME, so an empty
      # one is a resolution error rather than a defaulted path.
      check entries[0].executablePath.len > 0
      # A strip is meaningless for a single file and would be a sign the
      # entry was copied from an archive package without being re-read.
      check entries[0].stripComponents == 0

  test "weights carry no platform, deliberately":
    # ``cpu = ""`` / ``os = ""`` is the selector's documented catch-all. The
    # same bytes are correct on every host; the RUNTIME that reads them is
    # per-platform and is a different package (``piper``).
    for name in VoicePackages:
      let entry = slices(name)[0]
      checkpoint(name & " cpu=" & entry.cpu & " os=" & entry.os)
      check entry.cpu.len == 0
      check entry.os.len == 0

  test "each names its upstream and pins a digest":
    for name in VoicePackages:
      let entry = slices(name)[0]
      checkpoint(name & " -> " & entry.url)
      check entry.url.startsWith("https://huggingface.co/")
      # The URL revision is a moving ref; the digest is what pins the bytes,
      # so it must be present and must be the sha256 the lock identity
      # repeats. A mismatch between the two is the failure this catches:
      # the lock would pin one thing and the fetch verify another.
      check entry.sha256.len == 64
      check entry.lockIdentity.endsWith(entry.sha256)

  test "the two halves of one Piper voice agree on their revision":
    # A Piper voice is an ONNX graph plus the JSON config that describes it.
    # A mismatched pair is not a degraded voice, it is a crash or noise — so
    # they are pinned together and share a base URL.
    let onnx = slices("piper-voice-lessac-medium")[0]
    let config = slices("piper-voice-lessac-medium-config")[0]
    check config.url == onnx.url & ".json"
    check onnx.sha256 != config.sha256

  test "the digests are the ones Agent Harbor harvested":
    # These three were pinned in `scripts/provision-voice-local-models.py`
    # before they were packaged. Packaging must not silently adopt different
    # bytes than the installer already shipped.
    check slices("whisper-ggml-base")[0].sha256 ==
      "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
    check slices("piper-voice-lessac-medium")[0].sha256 ==
      "5efe09e69902187827af646e1a6e9d269dee769f9877d17b16b1b46eeaaf019f"
    check slices("piper-voice-lessac-medium-config")[0].sha256 ==
      "efe19c417bed055f2d69908248c6ba650fa135bc868b0e6abb3da181dab690a0"
