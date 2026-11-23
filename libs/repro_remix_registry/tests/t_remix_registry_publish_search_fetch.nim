## ReproOS-Remix-Protocol-And-Registry M4 verifications
## ``e2e_remix_registry_publish_search_fetch`` and
## ``e2e_remix_registry_concurrent_publication``, against the local
## development double.
##
## "A release is validated, stored, indexed, searched, fetched by identity,
## and reconstructed byte-for-byte with lineage and evidence." and
## "Retries and concurrent uploads cannot fork immutable identities, lose
## evidence, or expose partially validated releases."
##
## Everything crosses real loopback HTTP into the real intake, through the
## real Boundary spool, into the registrar, out through the published
## generation and the real read front. The only stand-in is the
## deployment shape itself (all zones on one host), which is the double's
## recorded deviation D1 — not a mock of any behaviour under test.

import std/[asyncdispatch, httpclient, os, sequtils, strutils, tempfiles, times, unittest]

import repro_remix
import repro_remix_registry
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

proc bytesOf(s: string): seq[byte] = s.mapIt(byte(ord(it)))

proc d32(seed: byte): Digest32 =
  for i in 0 ..< 32: result[i] = seed xor byte(i)

proc kid(k: PeerKeypair): Digest32 = Digest32(keyIdOf(k))

let logKey = generateKeypair()
let trust = TrustConfig(logKeys: @[kid(logKey)])

proc genesis(k: PeerKeypair): seq[byte] =
  encodeEnvelope(entrySigned(KeyLogEntry(operation: klGenesis,
    algorithm: saEcdsaP256, publicKey: @(k.publicKey), roles: {roleAuthor}), @[k]))

proc patchBlob(name: string): seq[byte] =
  bytesOf("--- a/" & name & ".css\n+++ b/" & name & ".css\n@@ -1,1 +1,1 @@\n-a\n+b\n")

proc manifest(name: string; k: PeerKeypair; parents: seq[Digest32] = @[]): (seq[byte], seq[byte]) =
  ## Returns (manifest envelope bytes, its patch blob bytes).
  let blob = patchBlob(name)
  let m = Manifest(remixName: name, version: "1.0.0",
    intent: "Fixture " & name & " for the registry double.", license: "MIT",
    targets: @[Target(original: OriginalRef(package: "firefox",
      interfaceFingerprint: d32(1), catalogWorkspace: "reprobuild-packages",
      catalogRemote: "https://github.com/metacraft-labs/reprobuild-packages",
      catalogRevision: "0123456789abcdef0123456789abcdef01234567",
      catalogInterfaceArtifact: d32(2)), constraintKind: ckExactFingerprint)],
    platforms: @["x86_64-linux"], parents: parents,
    patches: @[Patch(appliesToKind: ptTarget, appliesToIndex: 0,
      blob: BlobRef(id: blobId(blob), mediaType: "text/x-diff", size: uint64(blob.len)),
      strip: 1, order: 0)],
    authors: @[kid(k)])
  var env = newManifestEnvelope(m)
  env.signEnvelope(k)
  (encodeEnvelope(env), blob)

proc waitFor200(fetch: Fetch; path: string; seconds = 20): bool =
  let deadline = epochTime() + float(seconds)
  while epochTime() < deadline:
    if fetch(path)[0] == 200: return true
    sleep(20)
  false

proc idOf(envBytes: seq[byte]): Digest32 = Digest32(decodeAndVerify(envBytes).id)

suite "Remix M4 — registry double":

  test "publish, search, fetch by identity and reconstruct byte-for-byte with lineage":
    let root = createTempDir("remix-registry-", "")
    var h = startDouble(root, logKey)
    defer:
      h.stopDouble()
      removeDir(root)
    let fetch = httpFetch(h.readBase)
    let alice = generateKeypair()
    check submit(h.intakeBase, "release", genesis(alice))[0] == 202
    let (parentEnv, parentBlob) = manifest("alice/compact-tabs", alice)
    check submit(h.intakeBase, "blob", parentBlob)[0] == 202
    check fetch.waitFor200("/v1/key-log/" & toHex(kid(alice)))
    check submit(h.intakeBase, "release", parentEnv)[0] == 202
    let parentId = idOf(parentEnv)
    check fetch.waitFor200("/v1/release/" & toHex(parentId))
    let (childEnv, childBlob) = manifest("alice/compact-tabs-dark", alice, @[parentId])
    discard submit(h.intakeBase, "blob", childBlob)
    discard submit(h.intakeBase, "release", childEnv)
    let childId = idOf(childEnv)
    check fetch.waitFor200("/v1/release/" & toHex(childId))

    # Search the published index.
    let snapshot = decodeIndex(fetch("/v1/index/latest")[1])
    check snapshot.search(Query(text: "compact")).mapIt(it.release) == @[parentId, childId]
    check snapshot.search(Query(text: "DARK")).mapIt(it.release) == @[childId]
    check snapshot.search(Query(package: "firefox", platform: "x86_64-linux")).len == 2
    check snapshot.search(Query(package: "thunderbird")).len == 0

    # Name lookup, newest first.
    check decodeNameFile(fetch("/v1/name/alice/compact-tabs")[1]) == @[parentId]

    # Fetch by identity and accept offline; bytes are exactly what was sent.
    let got = fetchAndAccept(fetch, childId, trust)
    check got.decision.accepted
    check got.envelopeBytes == childEnv
    # Lineage and evidence travel in the bundle: both manifests, both
    # blobs, the author's key log and the registry's publication statements.
    let kinds = got.bundle.entries.mapIt(it.kind)
    check kinds.countIt(it == bekManifestEnvelope) == 2
    check got.bundle.entries.filterIt(it.kind == bekBlob).mapIt(it.bytes).toSeq.len == 2
    check bekKeyLogEnvelope in kinds
    check kinds.countIt(it == bekStatementEnvelope) == 2
    check got.bundle.manifests.mapIt(Digest32(it.id)).anyIt(it == parentId)
    for e in got.bundle.entries:
      if e.kind == bekBlob:
        check e.bytes == parentBlob or e.bytes == childBlob

    # Publication statements are signed by the registry's log key.
    let sts = decodeEnvelopeList(fetch("/v1/release/" & toHex(childId) & "/statements")[1])
    check sts.len == 1
    check verifiedSigners(decodeEnvelope(sts[0])) == @[kid(logKey)]

  test "admission refuses what clients would refuse, and records why":
    let root = createTempDir("remix-registry-", "")
    var h = startDouble(root, logKey)
    defer:
      h.stopDouble()
      removeDir(root)
    let fetch = httpFetch(h.readBase)
    let bob = generateKeypair()
    let (env, blob) = manifest("bob/no-key-log", bob)
    discard submit(h.intakeBase, "blob", blob)
    discard submit(h.intakeBase, "release", env)           # no key log yet
    sleep(300)
    check fetch("/v1/release/" & toHex(idOf(env)))[0] == 404
    # Reserved namespace: refused and captured as a canary touch naming it.
    discard submit(h.intakeBase, "release", genesis(bob))
    check fetch.waitFor200("/v1/key-log/" & toHex(kid(bob)))
    let (canaryEnv, canaryBlob) = manifest("reproos/core", bob)
    discard submit(h.intakeBase, "blob", canaryBlob)
    discard submit(h.intakeBase, "release", canaryEnv)
    sleep(300)
    check fetch("/v1/release/" & toHex(idOf(canaryEnv)))[0] == 404
    let events = capturedEvents(dirs(root).captureDir)
    check events.anyIt(it[1] == "canary" and it[2] == "reserved-namespace:reproos")
    # Unknown routes and methods are not served.
    check fetch("/v1/../interior/data")[0] == 404
    check fetch("/v1/release/ZZ")[0] == 404
    check submit(h.intakeBase, "statement", @[1'u8])[0] == 404

  test "concurrent and retried uploads cannot fork identities or expose partial releases":
    let root = createTempDir("remix-registry-", "")
    var h = startDouble(root, logKey)
    defer:
      h.stopDouble()
      removeDir(root)
    let fetch = httpFetch(h.readBase)
    let carol = generateKeypair()
    let mallory = generateKeypair()
    for k in [carol, mallory]:
      discard submit(h.intakeBase, "release", genesis(k))
    check fetch.waitFor200("/v1/key-log/" & toHex(kid(carol)))
    check fetch.waitFor200("/v1/key-log/" & toHex(kid(mallory)))
    # Carol claims her namespace first, so the race below is about
    # identities and visibility, not about who claims "carol".
    let claim = manifest("carol/claim", carol)
    discard submit(h.intakeBase, "blob", claim[1])
    discard submit(h.intakeBase, "release", claim[0])
    check fetch.waitFor200("/v1/release/" & toHex(idOf(claim[0])))
    var releases: seq[(seq[byte], seq[byte])]
    for i in 0 ..< 6:
      releases.add manifest("carol/r" & $i, carol)
    let squat = manifest("carol/stolen", mallory)          # same namespace, other principal
    # Fire everything concurrently, every release three times (retries).
    proc fire() {.async.} =
      var futs: seq[Future[AsyncResponse]]
      var clients: seq[AsyncHttpClient]
      proc post(kind: string; payload: seq[byte]) =
        let c = newAsyncHttpClient()
        clients.add c
        futs.add c.request(h.intakeBase & "/v1/submit/" & kind, HttpPost,
                           payload.mapIt(char(it)).join(""))
      for (env, blob) in releases & @[squat]:
        post("blob", blob)
      for round in 0 ..< 3:
        for (env, _) in releases & @[squat]:
          post("release", env)
      for f in futs:
        discard await f
      for c in clients: c.close()
    waitFor fire()
    # While admission runs, every release that is visible must already be
    # fully provable — no partially validated release is ever exposed.
    let deadline = epochTime() + 20
    var allVisible = false
    while epochTime() < deadline and not allVisible:
      allVisible = true
      for (env, _) in releases:
        let id = idOf(env)
        if fetch("/v1/release/" & toHex(id))[0] == 200:
          check fetchAndAccept(fetch, id, trust).decision.accepted
        else:
          allVisible = false
      sleep(20)
    check allVisible
    # Each identity was logged exactly once despite three submissions.
    let snapshot = decodeIndex(fetch("/v1/index/latest")[1])
    for (env, _) in releases:
      check snapshot.entries.countIt(it.release == idOf(env)) == 1
    # The namespace stayed with its first owner; the squatter got nothing.
    check fetch("/v1/release/" & toHex(idOf(squat[0])))[0] == 404
    # Evidence was not lost: every release has its publication statement.
    for (env, _) in releases:
      check decodeEnvelopeList(fetch("/v1/release/" & toHex(idOf(env)) & "/statements")[1]).len == 1
