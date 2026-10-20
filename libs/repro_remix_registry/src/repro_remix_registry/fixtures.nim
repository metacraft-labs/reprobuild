## A deterministic fixture ecosystem for the registry double
## (Protocol And Registry M4 "deterministic fixture datasets" and M8
## "a fixture ecosystem containing originals, forks, compositions,
## incompatible releases, yanks, revocations, reviews, claims, and blocked
## Remixes"; Product Experience M1 "fixtures render every state from
## shared API data").
##
## Every key is derived from its name, and ECDSA-P256 signing is RFC 6979
## deterministic, so every release identity is the same on every run.
## Everything is published through the double's real intake and policy
## inbox — nothing is written into its stores directly.

import std/[algorithm, os, strutils, tables, times]

from blake3 import nil
import repro_remix
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

import ./boundary
import ./client
import ./double
import ./registrar

const FixtureKeyContext = "reproos.remix.fixture-key.v1"

type
  FixtureEcosystem* = object
    releases*: OrderedTable[string, Digest32]
      ## Fixture name -> release identity.
    expected*: Table[string, seq[VisibleState]]
      ## What `deriveStates(viewFor(...))` must show on an x86_64-linux
      ## client trusting the double's log and the fixture policy keys.
    trust*: TrustConfig
    localPlatform*: string

proc fixtureKey*(name: string): PeerKeypair =
  ## A valid P-256 scalar derived from `name`: BLAKE3, with the top byte
  ## forced to 0x01 so the scalar is non-zero and below the group order.
  let d = blake3.digest(FixtureKeyContext & ":" & name)
  for i in 0 ..< 32: result.privateKey[i] = d[i]
  result.privateKey[0] = 0x01
  result.publicKey = derivePublicKey(result.privateKey)

proc kid(k: PeerKeypair): Digest32 = Digest32(keyIdOf(k))

proc d32Fixture(seed: byte): Digest32 =
  for i in 0 ..< 32: result[i] = seed xor byte(i)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(ord(c))

proc fixturePolicyKeys*(): seq[PeerKeypair] =
  @[fixtureKey("policy-1"), fixtureKey("policy-2")]

proc waitFor200(f: Fetch; path: string; seconds = 30) =
  let deadline = epochTime() + float(seconds)
  while epochTime() < deadline:
    if f(path)[0] == 200: return
    sleep(20)
  refuse(rrNotLogged, "fixture did not appear: " & path)

proc seedEcosystem*(h: DoubleHandle; logKey: PeerKeypair): FixtureEcosystem =
  let fetch = httpFetch(h.readBase)
  let base = h.intakeBase
  let policy = fixturePolicyKeys()
  result.trust = TrustConfig(logKeys: @[kid(logKey)],
    policyKeys: @[kid(policy[0]), kid(policy[1])], policyThreshold: 2)
  result.localPlatform = "x86_64-linux"

  proc post(kind: string; bytes: seq[byte]) =
    let (status, _) = submit(base, kind, bytes)
    if status != 202:
      refuse(rrMalformed, "fixture submission refused by the intake: " & $status)

  # Principals.
  let alice = fixtureKey("alice")
  let bob = fixtureKey("bob")
  let mallory = fixtureKey("mallory")
  let malloryBackup = fixtureKey("mallory-backup")
  let rita = fixtureKey("rita")
  let ray = fixtureKey("ray")
  let bea = fixtureKey("bea")
  let ivy = fixtureKey("ivy")
  var genesisOf = initTable[string, Envelope]()
  for (name, k, roles) in [("alice", alice, {roleAuthor}), ("bob", bob, {roleAuthor}),
                           ("mallory", mallory, {roleAuthor}),
                           ("rita", rita, {roleReviewer}), ("ray", ray, {roleReviewer}),
                           ("bea", bea, {roleBuilder}),
                           ("ivy", ivy, {roleAttestedInference})]:
    let g = entrySigned(KeyLogEntry(operation: klGenesis, algorithm: saEcdsaP256,
      publicKey: @(k.publicKey), roles: roles), @[k])
    genesisOf[name] = g
    post("release", encodeEnvelope(g))
  let addBackup = entrySigned(KeyLogEntry(principal: kid(mallory), sequence: 1,
    previous: envelopeIdentity(genesisOf["mallory"]), operation: klAddKey,
    algorithm: saEcdsaP256, publicKey: @(malloryBackup.publicKey),
    roles: {roleAuthor}), @[mallory])
  post("release", encodeEnvelope(addBackup))
  fetch.waitFor200("/v1/key-log/" & toHex(kid(mallory)))

  let r = addr result

  # Releases.
  proc publish(fixture, name, version: string; k: PeerKeypair;
               parents: seq[string] = @[]; platforms = @["x86_64-linux"];
               intent = ""): Digest32 =
    let patch = bytesOf("--- a/" & fixture & ".css\n+++ b/" & fixture &
                        ".css\n@@ -1,1 +1,1 @@\n-before\n+after\n")
    var ps: seq[Digest32]
    for p in parents: ps.add r[].releases[p]
    var sortedPs = ps
    sortedPs.sort(proc (a, b: Digest32): int =
      for i in 0 ..< 32:
        if a[i] != b[i]: return cmp(a[i], b[i])
      0)
    var env = newManifestEnvelope(Manifest(remixName: name, version: version,
      intent: (if intent.len > 0: intent else: "Fixture: " & fixture & "."),
      license: "MIT",
      targets: @[Target(original: OriginalRef(package: "firefox",
        interfaceFingerprint: d32Fixture(1), catalogWorkspace: "reprobuild-packages",
        catalogRemote: "https://github.com/metacraft-labs/reprobuild-packages",
        catalogRevision: "0123456789abcdef0123456789abcdef01234567",
        catalogInterfaceArtifact: d32Fixture(2)), constraintKind: ckExactFingerprint)],
      platforms: platforms, parents: sortedPs,
      patches: @[Patch(appliesToKind: ptTarget, appliesToIndex: 0,
        blob: BlobRef(id: blobId(patch), mediaType: "text/x-diff",
                      size: uint64(patch.len)), strip: 1, order: 0)],
      authors: @[kid(k)]))
    env.signEnvelope(k)
    let bytes = encodeEnvelope(env)
    post("blob", patch)
    post("release", bytes)
    result = Digest32(releaseId(env))
    fetch.waitFor200("/v1/release/" & toHex(result))

  proc say(kind: StatementKind; subject: Digest32; k: PeerKeypair;
           scope: seq[string] = @[]) =
    var env = newStatementEnvelope(Statement(kind: kind, subjectKind: sbRelease,
      subject: subject, issuer: kid(k), scope: scope))
    env.signEnvelope(k)
    post("release", encodeEnvelope(env))

  proc decree(subject: Digest32; scope: seq[string]) =
    var env = newStatementEnvelope(Statement(kind: skVerdict, subjectKind: sbRelease,
      subject: subject, scope: scope))
    for k in policy: env.signEnvelope(k)
    h.dropPolicy(env)

  template add(fixture: string; id: Digest32; states: seq[VisibleState]) =
    r.releases[fixture] = id
    r.expected[fixture] = states

  add("original, reviewed twice", publish("compact-tabs-1.0", "alice/compact-tabs", "1.0.0", alice), @[vsReviewed, vsSuperseded])
  add("newer release", publish("compact-tabs-1.1", "alice/compact-tabs", "1.1.0", alice), @[vsUnknown])
  add("original, one review", publish("dark-menus", "alice/dark-menus", "1.0.0", alice), @[vsEmbargoedClaim, vsLowConfidence])
  add("fork of a fork", publish("tabs-dark", "bob/compact-tabs-dark", "1.0.0", bob, @["newer release"]), @[vsCertifiedReview])
  add("composition", publish("tabs-and-menus", "bob/tabs-and-menus", "1.0.0", bob, @["newer release", "original, one review"]), @[vsUnknown])
  add("withdrawn", publish("old-toolbar", "alice/old-toolbar", "1.0.0", alice), @[vsYanked, vsUnknown])
  add("arm only", publish("arm-only", "bob/arm-only", "1.0.0", bob, platforms = @["aarch64-linux"]), @[vsIncompatible, vsUnknown])
  add("open concern", publish("beta-feature", "bob/beta-feature", "1.0.0", bob), @[vsWarning, vsUnknown])
  add("blocked", publish("miner", "bob/miner", "1.0.0", bob), @[vsBlocked, vsUnknown])
  add("stolen key", publish("helper", "mallory/helper", "1.0.0", mallory), @[vsRevoked, vsUnknown])

  # Evidence and policy.
  say(skReview, r.releases["original, reviewed twice"], rita)
  say(skReview, r.releases["original, reviewed twice"], ray)
  say(skReview, r.releases["original, one review"], rita)
  say(skVulnerabilityClaim, r.releases["original, one review"], ray, @["embargoed"])
  say(skAttestedInference, r.releases["fork of a fork"], ivy)
  say(skBuildEvidence, r.releases["fork of a fork"], bea)
  say(skYank, r.releases["withdrawn"], alice)
  decree(r.releases["open concern"], @["warn"])
  decree(r.releases["blocked"], @["block"])
  # Mallory's key was stolen before the helper was published: revoke it
  # with a window covering the whole log.
  let revoke = entrySigned(KeyLogEntry(principal: kid(mallory), sequence: 2,
    previous: envelopeIdentity(addBackup), operation: klRevokeKey,
    target: kid(mallory), compromisedFrom: 0), @[malloryBackup])
  post("release", encodeEnvelope(revoke))
  # Wait until every statement and verdict is published.
  let deadline = epochTime() + 30
  while epochTime() < deadline:
    let (status, body) = fetch("/v1/policy/latest")
    if status == 200 and decodeEnvelopeList(body).len == 2: break
    sleep(20)
  sleep(300)
