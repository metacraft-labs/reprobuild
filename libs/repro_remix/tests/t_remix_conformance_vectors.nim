## Remix v1 conformance vectors (Protocol And Registry M8: "conformance
## suites used by ReproOS, Agent Harbor, web clients, private registries,
## and optional third parties").
##
## `libs/repro_remix/conformance/remix-v1.vectors` is a plain-text corpus
## any implementation can run: each vector names an operation, its input
## bytes in hex, and the exact expected output (an identity, a digest, a
## proof result, or a refusal code). This test checks that this
## implementation reproduces every committed vector byte for byte.
##
## Regenerate (only when the protocol deliberately changes) with
##   nim c -r -d:writeRemixVectors libs/repro_remix/tests/t_remix_conformance_vectors.nim
## and review the diff: a changed vector is a wire-format change.

import std/[os, strutils, unittest]

from blake3 as b3 import nil
import repro_remix
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

const VectorFile = currentSourcePath().parentDir.parentDir / "conformance" / "remix-v1.vectors"

proc hexOf(b: openArray[byte]): string =
  const h = "0123456789abcdef"
  for x in b:
    result.add h[int(x shr 4)]
    result.add h[int(x and 0x0f)]

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(ord(c))

proc unhex(s: string): seq[byte] =
  for i in countup(0, s.len - 2, 2):
    result.add byte(parseHexInt(s[i .. i + 1]))

proc seededKey(name: string): PeerKeypair =
  let d = b3.digest("reproos.remix.conformance-key.v1:" & name)
  for i in 0 ..< 32: result.privateKey[i] = d[i]
  result.privateKey[0] = 0x01
  result.publicKey = derivePublicKey(result.privateKey)

proc d32(seed: byte): Digest32 =
  for i in 0 ..< 32: result[i] = seed xor byte(i)

proc refusalOf(f: proc ()): string =
  try:
    f()
    "accepted"
  except RemixError as e:
    $e.reason

type Vector = object
  name, op, input, expect: string

proc compute(op, input: string): string =
  ## The implementation's answer for one vector.
  # Merkle vectors take text ("<n>", "<i>/<n>"); every other op takes hex.
  let bytes =
    if op in ["merkle-root", "inclusion", "consistency"]: newSeq[byte]()
    else: unhex(input)
  case op
  of "manifest-envelope":
    # Expect: the release identity, or the refusal code.
    var id = ""
    let r = refusalOf(proc () = id = toHex(Digest32(decodeAndVerify(bytes).id)))
    if r == "accepted": id else: "refuse:" & r
  of "key-id":
    toHex(Digest32(keyId(saEcdsaP256, bytes)))
  of "blob-id":
    toHex(blobId(bytes))
  of "merkle-root":
    # Input: n leaves, each "leaf-<i>".
    let n = parseInt(input)
    var log: MerkleLog
    for i in 0 ..< n: discard log.append(bytesOf("leaf-" & $i))
    toHex(log.root())
  of "inclusion":
    # Input: "<index>/<size>"; expect: proof hashes joined by ','.
    let parts = input.split('/')
    var log: MerkleLog
    for i in 0 ..< parseInt(parts[1]): discard log.append(bytesOf("leaf-" & $i))
    var outp: seq[string]
    for p in log.inclusionProof(parseInt(parts[0]), parseInt(parts[1])): outp.add toHex(p)
    outp.join(",")
  of "consistency":
    let parts = input.split('/')
    var log: MerkleLog
    for i in 0 ..< parseInt(parts[1]): discard log.append(bytesOf("leaf-" & $i))
    var outp: seq[string]
    for p in log.consistencyProof(parseInt(parts[0]), parseInt(parts[1])): outp.add toHex(p)
    outp.join(",")
  of "nullifier":
    # Input: secret hex; release d32(1), kind interest, epoch 20000.
    toHex(eventNullifier(bytes, d32(1), ekInterest, 20000))
  of "policy-commitment":
    # Input: concatenated 32-byte statement ids.
    var ids: seq[Digest32]
    for i in countup(0, bytes.len - 32, 32):
      var d: Digest32
      for j in 0 ..< 32: d[j] = bytes[i + j]
      ids.add d
    toHex(policyCommitment(ids))
  of "bundle":
    var n = ""
    let r = refusalOf(proc () = n = $readBundle(bytes).manifests.len)
    if r == "accepted": "manifests:" & n else: "refuse:" & r
  else:
    raise newException(ValueError, "unknown op " & op)

proc generate(): seq[Vector] =
  let alice = seededKey("alice")
  let patch = bytesOf("--- a/tabs.css\n+++ b/tabs.css\n@@ -1,1 +1,1 @@\n-h: 40px\n+h: 28px\n")
  let m = Manifest(remixName: "alice/compact-tabs", version: "1.0.0",
    intent: "Shorter tabs.", license: "MIT",
    targets: @[Target(original: OriginalRef(package: "firefox",
      interfaceFingerprint: d32(1), catalogWorkspace: "reprobuild-packages",
      catalogRemote: "https://github.com/metacraft-labs/reprobuild-packages",
      catalogRevision: "0123456789abcdef0123456789abcdef01234567",
      catalogInterfaceArtifact: d32(2)), constraintKind: ckExactFingerprint)],
    platforms: @["x86_64-linux"],
    patches: @[Patch(appliesToKind: ptTarget, appliesToIndex: 0,
      blob: BlobRef(id: blobId(patch), mediaType: "text/x-diff", size: uint64(patch.len)),
      strip: 1, order: 0)],
    authors: @[Digest32(keyIdOf(alice))])
  var env = newManifestEnvelope(m)
  env.signEnvelope(alice)
  let good = encodeEnvelope(env)
  var vs: seq[Vector]
  proc v(name, op: string; input: string) =
    vs.add Vector(name: name, op: op, input: input, expect: compute(op, input))
  v("canonical signed manifest", "manifest-envelope", hexOf(good))
  # Hostile variants of the same bytes.
  var bad = good; bad[0] = byte('X')
  v("bad magic", "manifest-envelope", hexOf(bad))
  v("truncated frame", "manifest-envelope", hexOf(good[0 ..< 8]))
  v("trailing byte", "manifest-envelope", hexOf(good & @[0'u8]))
  bad = good; bad[^1] = bad[^1] xor 1
  v("signature bit flipped", "manifest-envelope", hexOf(bad))
  var unsigned = newManifestEnvelope(m)
  v("missing author signature", "manifest-envelope", hexOf(encodeEnvelope(unsigned)))
  var feature = newManifestEnvelope(m); feature.requiredFeatures = 1
  feature.signEnvelope(alice)
  v("unknown required feature", "manifest-envelope", hexOf(encodeEnvelope(feature)))
  v("key id", "key-id", hexOf(alice.publicKey))
  v("blob id", "blob-id", hexOf(patch))
  for n in [1, 2, 3, 4, 5, 7, 8, 16]:
    v("merkle root of " & $n & " leaves", "merkle-root", $n)
  for (i, n) in [(0, 1), (0, 7), (3, 7), (6, 7), (5, 16)]:
    v("inclusion " & $i & " of " & $n, "inclusion", $i & "/" & $n)
  for (a, b) in [(1, 2), (3, 7), (4, 7), (6, 8), (8, 16)]:
    v("consistency " & $a & " to " & $b, "consistency", $a & "/" & $b)
  v("event nullifier", "nullifier", hexOf(bytesOf("installation-secret")))
  v("empty policy commitment", "policy-commitment", "")
  v("policy commitment of two ids", "policy-commitment", hexOf(@(d32(9)) & @(d32(3))))
  let bundle = writeBundle([(bekManifestEnvelope, good), (bekBlob, patch)])
  v("export bundle", "bundle", hexOf(bundle))
  v("export bundle missing its blob", "bundle", hexOf(writeBundle([(bekManifestEnvelope, good)])))
  vs

proc render(vs: seq[Vector]): string =
  result = "# Remix v1 conformance vectors. Generated by\n" &
           "# libs/repro_remix/tests/t_remix_conformance_vectors.nim; see its header.\n" &
           "# Each vector: name, op, input (hex or text), expect.\n"
  for x in vs:
    result.add "\nname: " & x.name & "\nop: " & x.op & "\ninput: " & x.input &
               "\nexpect: " & x.expect & "\n"

proc parse(text: string): seq[Vector] =
  var cur: Vector
  for line in text.splitLines:
    if line.startsWith("name: "): cur = Vector(name: line[6 .. ^1])
    elif line.startsWith("op: "): cur.op = line[4 .. ^1]
    elif line.startsWith("input: "): cur.input = line[7 .. ^1]
    elif line.startsWith("expect: "):
      cur.expect = line[8 .. ^1]
      result.add cur

when defined(writeRemixVectors):
  createDir(VectorFile.parentDir)
  writeFile(VectorFile, render(generate()))
  echo "wrote ", VectorFile

suite "Remix v1 conformance vectors":

  test "every committed vector reproduces exactly":
    let vectors = parse(readFile(VectorFile))
    check vectors.len >= 30
    for x in vectors:
      checkpoint x.name
      check compute(x.op, x.input) == x.expect

  test "the corpus covers acceptance and refusal":
    let vectors = parse(readFile(VectorFile))
    var refusals = 0
    for x in vectors:
      if x.expect.startsWith("refuse:"): inc refusals
    check refusals >= 6
