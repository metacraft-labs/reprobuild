## ReproOS-Remix-Protocol-And-Registry M1 deliverable 4 and the bundle half
## of ``test_malicious_remix_bundle_parser_bounds``.
##
## "Support private local manifests, detached export bundles, and registry
## submissions through the same codec." A bundle carries the same signed
## envelope bytes a private manifest is stored as, so the release identity
## read back from a bundle must equal the one computed before export.
##
## Hostile cases edit real bundle bytes the way an attacker would. No mocks:
## real keys, real codec, real digest checks.

import std/[sequtils, unittest]

import repro_remix
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

proc bytesOf(s: string): seq[byte] = s.mapIt(byte(ord(it)))

proc d32(seed: byte): Digest32 =
  for i in 0 ..< 32:
    result[i] = seed xor byte(i)

let alice = generateKeypair()
let patchBytes = bytesOf("--- a/tabs.css\n+++ b/tabs.css\n@@ -1 +1 @@\n-h: 40px\n+h: 28px\n")
let configBytes = bytesOf("28")

proc manifestBytes(): seq[byte] =
  let m = Manifest(
    remixName: "alice/compact-tabs", version: "1.0.0",
    intent: "Shorter tabs.", license: "MIT",
    targets: @[Target(original: OriginalRef(package: "firefox",
      interfaceFingerprint: d32(1), catalogWorkspace: "reprobuild-packages",
      catalogRemote: "https://github.com/metacraft-labs/reprobuild-packages",
      catalogRevision: "0123456789abcdef0123456789abcdef01234567",
      catalogInterfaceArtifact: d32(2)), constraintKind: ckExactFingerprint)],
    patches: @[Patch(appliesToKind: ptTarget, appliesToIndex: 0,
      blob: BlobRef(id: blobId(patchBytes), mediaType: "text/x-diff",
                    size: uint64(patchBytes.len)), strip: 1, order: 0)],
    configuration: @[ConfigContribution(configurable: "firefox.tabHeight",
      schemaFingerprint: d32(3), priority: cpSet, operation: coReplace,
      value: BlobRef(id: blobId(configBytes), mediaType: "text/plain",
                     size: uint64(configBytes.len)))],
    authors: @[Digest32(keyIdOf(alice))])
  var env = newManifestEnvelope(m)
  env.signEnvelope(alice)
  encodeEnvelope(env)

proc fullBundle(): seq[byte] =
  writeBundle([(bekBlob, configBytes), (bekManifestEnvelope, manifestBytes()),
               (bekBlob, patchBytes)])

proc refusal(f: proc ()): string =
  ## The stable reason code `f` refused with, or "accepted".
  try:
    f()
    "accepted"
  except RemixError as e:
    $e.reason

proc indexEnd(b: seq[byte]): int =
  var n = 0
  for i in 0 ..< 4:
    n = n or (int(b[8 + i]) shl (8 * i))
  12 + n

suite "Remix M1 — export bundles":

  test "a private manifest and its bundled copy have the same release identity":
    let local = decodeAndVerify(manifestBytes())
    let b = readBundle(fullBundle())
    check b.manifests.len == 1
    check b.manifests[0].id == local.id
    check b.manifests[0].manifest == local.manifest
    check b.entries.len == 3

  test "bundles are canonical: entry order and duplicates do not change bytes":
    let again = writeBundle([(bekBlob, patchBytes), (bekBlob, configBytes),
                             (bekManifestEnvelope, manifestBytes()),
                             (bekBlob, patchBytes)])
    check again == fullBundle()

  test "a missing or resized blob makes the bundle incomplete":
    let noPatch = writeBundle([(bekManifestEnvelope, manifestBytes()),
                               (bekBlob, configBytes)])
    check refusal(proc () = discard readBundle(noPatch)) == $rrMissingBlob

  test "a changed entry byte fails its digest":
    var b = fullBundle()
    b[^1] = b[^1] xor 0x01
    check refusal(proc () = discard readBundle(b)) == $rrDigestMismatch

  test "truncation, trailing bytes and a lying index are refused":
    let good = fullBundle()
    check refusal(proc () = discard readBundle(good[0 ..< ^1])) == $rrTruncated
    check refusal(proc () = discard readBundle(good & @[0'u8])) == $rrLengthMismatch
    check refusal(proc () = discard readBundle(good[0 ..< 6])) == $rrTruncated
    # Grow the index frame's length field past the file.
    var lying = good
    lying[11] = 0x7f
    check refusal(proc () = discard readBundle(lying)) == $rrTruncated

  test "a signed manifest entry that was tampered with is refused":
    var b = fullBundle()
    let start = indexEnd(b)
    # The manifest envelope sorts first (kind 1). Flip a byte inside it and
    # repair the digest in the index so only the signature check can catch it.
    let entries = readBundle(fullBundle()).entries
    check entries[0].kind == bekManifestEnvelope
    var tampered = entries[0].bytes
    tampered[^70] = tampered[^70] xor 0x01
    let rebuilt = writeBundle([(bekManifestEnvelope, tampered),
                               (bekBlob, patchBytes), (bekBlob, configBytes)])
    check refusal(proc () = discard readBundle(rebuilt)) != "accepted"
    check start > 12

  test "the unmodified bundle survives a mutation sweep only unchanged":
    let good = fullBundle()
    var refused = 0
    for i in 0 ..< good.len:
      var bad = good
      bad[i] = bad[i] xor 0x5a
      if refusal(proc () = discard readBundle(bad)) != "accepted":
        inc refused
    check refused == good.len
