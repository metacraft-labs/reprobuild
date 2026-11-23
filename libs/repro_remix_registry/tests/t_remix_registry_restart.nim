## A restarted registrar extends the history it signed before (threat
## model gap G14, review finding 6): the same log key never signs a
## different tree, namespace claims survive, and a message claimed before a
## crash is processed after it. The registrar under test is the real one,
## restarted by constructing it again over the same directories.

import std/[os, sequtils, tempfiles, unittest]

import repro_remix
import repro_remix_registry
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

proc d32(seed: byte): Digest32 =
  for i in 0 ..< 32: result[i] = seed xor byte(i)
proc kid(k: PeerKeypair): Digest32 = Digest32(keyIdOf(k))
proc bytesOf(s: string): seq[byte] = s.mapIt(byte(ord(it)))

let logKey = generateKeypair()

proc frame(t: MessageType; payload: seq[byte]): seq[byte] =
  encodeMessage(BoundaryMessage(msgType: t, intake: "i", rateKey: "k", payload: payload))

proc genesis(k: PeerKeypair): seq[byte] =
  encodeEnvelope(entrySigned(KeyLogEntry(operation: klGenesis, algorithm: saEcdsaP256,
    publicKey: @(k.publicKey), roles: {roleAuthor}), @[k]))

proc manifest(name: string; k: PeerKeypair): (seq[byte], seq[byte]) =
  let blob = bytesOf("--- a/" & name & ".c\n+++ b/" & name & ".c\n@@ -1,1 +1,1 @@\n-a\n+b\n")
  var env = newManifestEnvelope(Manifest(remixName: name, version: "1.0.0",
    intent: "Fixture.", license: "MIT", targets: @[Target(original: OriginalRef(
      package: "firefox", interfaceFingerprint: d32(1),
      catalogWorkspace: "reprobuild-packages",
      catalogRemote: "https://github.com/metacraft-labs/reprobuild-packages",
      catalogRevision: "0123456789abcdef0123456789abcdef01234567",
      catalogInterfaceArtifact: d32(2)), constraintKind: ckExactFingerprint)],
    patches: @[Patch(appliesToKind: ptTarget, appliesToIndex: 0,
      blob: BlobRef(id: blobId(blob), mediaType: "text/x-diff", size: uint64(blob.len)),
      strip: 1, order: 0)],
    authors: @[kid(k)]))
  env.signEnvelope(k)
  (encodeEnvelope(env), blob)

proc latestCheckpoint(root: string): Statement =
  let cfg = dirs(root)
  decodeStatement(decodeEnvelope(bytesOf(readFile(
    cfg.publishDir / "current" / "v1" / "checkpoint" / "latest"))).body)

suite "Remix registry — restart and crash recovery":

  test "a restarted registrar extends its history and keeps its claims":
    let root = createTempDir("remix-restart-", "")
    defer: removeDir(root)
    let alice = generateKeypair()
    let mallory = generateKeypair()
    var reg = newRegistrar(dirs(root), logKey)
    let spool = initSpool(dirs(root).spoolDir)
    for k in [alice, mallory]:
      discard spool.deliver("i", frame(mtSubmitRelease, genesis(k)))
    let (env, blob) = manifest("alice/tool", alice)
    discard spool.deliver("i", frame(mtSubmitBlob, blob))
    discard spool.deliver("i", frame(mtSubmitRelease, env))
    discard reg.tick()
    let before = latestCheckpoint(root)
    check before.treeSize == 4               # two key logs, release, publication

    # Restart: a new registrar over the same directories.
    reg = newRegistrar(dirs(root), logKey)
    discard reg.tick()
    let again = latestCheckpoint(root)
    check again.treeSize == before.treeSize
    check again.rootHash == before.rootHash  # same key, same tree: no equivocation
    # The namespace claim survived: mallory cannot take "alice".
    let (squat, squatBlob) = manifest("alice/stolen", mallory)
    discard spool.deliver("i", frame(mtSubmitBlob, squatBlob))
    discard spool.deliver("i", frame(mtSubmitRelease, squat))
    let o = reg.tick()
    check o.filterIt(it.msgType == mtSubmitRelease)[0].refusal == rrForbiddenContent
    # Growth after the restart is consistent with the pre-restart checkpoint.
    let (more, moreBlob) = manifest("alice/second", alice)
    discard spool.deliver("i", frame(mtSubmitBlob, moreBlob))
    discard spool.deliver("i", frame(mtSubmitRelease, more))
    discard reg.tick()
    let after = latestCheckpoint(root)
    check after.treeSize > before.treeSize
    check verifyConsistency(before.treeSize, after.treeSize, before.rootHash,
      after.rootHash, reg.log.consistencyProof(int(before.treeSize), int(after.treeSize)))

  test "a message claimed before a crash is processed after the restart":
    let root = createTempDir("remix-restart-", "")
    defer: removeDir(root)
    let alice = generateKeypair()
    let spool = initSpool(dirs(root).spoolDir)
    let name = spool.deliver("i", frame(mtSubmitRelease, genesis(alice)))
    discard spool.claim(name)                # claimed, then the process died
    check spool.pending.len == 0
    let reg = newRegistrar(dirs(root), logKey) # recovery moves it back
    let o = reg.tick()
    check o.len == 1
    check o[0].admitted

suite "Remix registry — checkpoint cadence and refusal capture":

  test "an index update does not make the log key sign again; a quiet log is refreshed":
    let root = createTempDir("remix-cadence-", "")
    defer: removeDir(root)
    var cfg = dirs(root)
    cfg.checkpointRefreshSeconds = 2
    let reg = newRegistrar(cfg, logKey)
    let spool = initSpool(cfg.spoolDir)
    discard spool.deliver("i", frame(mtSubmitRelease, genesis(generateKeypair())))
    discard reg.tick()
    let first = latestCheckpoint(root)
    # Past the one-second resolution of `issuedAt`, so a re-signature would
    # be visible, but well inside the two-second refresh interval.
    sleep(1100)
    discard spool.deliver("i", frame(mtRequestIndexUpdate, @[]))
    discard reg.tick()
    check latestCheckpoint(root).issuedAt == first.issuedAt    # reused, not re-signed
    sleep(2100)
    discard reg.tick()
    check latestCheckpoint(root).issuedAt > first.issuedAt     # refreshed on the timer
    check latestCheckpoint(root).rootHash == first.rootHash

  test "a refused submission is captured with its reason":
    let root = createTempDir("remix-cadence-", "")
    defer: removeDir(root)
    let reg = newRegistrar(dirs(root), logKey)
    let spool = initSpool(dirs(root).spoolDir)
    let alice = generateKeypair()
    let mallory = generateKeypair()
    for k in [alice, mallory]:
      discard spool.deliver("i", frame(mtSubmitRelease, genesis(k)))
    let (a, ab) = manifest("alice/one", alice)
    discard spool.deliver("i", frame(mtSubmitBlob, ab))
    discard spool.deliver("i", frame(mtSubmitRelease, a))
    discard reg.tick()
    let (m, mb) = manifest("alice/two", mallory)
    discard spool.deliver("i", frame(mtSubmitBlob, mb))
    discard spool.deliver("i", frame(mtSubmitRelease, m))
    discard reg.tick()
    check capturedEvents(dirs(root).captureDir).anyIt(
      it[1] == "admission-refused" and it[2] == $rrForbiddenContent)
