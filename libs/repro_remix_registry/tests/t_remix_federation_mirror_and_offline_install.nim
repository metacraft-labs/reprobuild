## ReproOS-Remix-Protocol-And-Registry M7 verification
## ``e2e_remix_federation_mirror_and_offline_install``.
##
## "A second registry mirrors and installs an allowed release offline while
## detecting stale checkpoints and missing revocations."
##
## Two real registry doubles (upstream and mirror) and a third, lying
## mirror, all over loopback HTTP. The lying mirror is not a mock: it is a
## real double whose sync was configured to drop policy statements — the
## attack under test. The forged upstream checkpoint in the split-view case
## is signed with the real upstream log key, as a compromised or coerced
## upstream would.

import std/[os, sequtils, tempfiles, times, unittest]

import repro_remix
import repro_remix_registry
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

proc bytesOf(s: string): seq[byte] = s.mapIt(byte(ord(it)))

proc d32(seed: byte): Digest32 =
  for i in 0 ..< 32: result[i] = seed xor byte(i)

proc kid(k: PeerKeypair): Digest32 = Digest32(keyIdOf(k))

let upstreamKey = generateKeypair()
let mirrorKey = generateKeypair()
let liarKey = generateKeypair()
let policyA = generateKeypair()
let policyB = generateKeypair()
let policyKeys = @[kid(policyA), kid(policyB)]
let upstreamTrust = TrustConfig(logKeys: @[kid(upstreamKey)], policyKeys: policyKeys,
                                policyThreshold: 2)
let mirrorTrust = TrustConfig(logKeys: @[kid(mirrorKey)], policyKeys: policyKeys,
                              policyThreshold: 2)
let liarTrust = TrustConfig(logKeys: @[kid(liarKey)], policyKeys: policyKeys,
                            policyThreshold: 2)

proc genesis(k: PeerKeypair): seq[byte] =
  encodeEnvelope(entrySigned(KeyLogEntry(operation: klGenesis,
    algorithm: saEcdsaP256, publicKey: @(k.publicKey), roles: {roleAuthor}), @[k]))

proc manifest(name: string; k: PeerKeypair; parents: seq[Digest32] = @[]): (seq[byte], seq[byte]) =
  let blob = bytesOf("--- a/" & name & ".css\n+++ b/" & name & ".css\n@@ -1,1 +1,1 @@\n-a\n+b\n")
  var env = newManifestEnvelope(Manifest(remixName: name, version: "1.0.0",
    intent: "Fixture " & name & ".", license: "MIT",
    targets: @[Target(original: OriginalRef(package: "firefox",
      interfaceFingerprint: d32(1), catalogWorkspace: "reprobuild-packages",
      catalogRemote: "https://github.com/metacraft-labs/reprobuild-packages",
      catalogRevision: "0123456789abcdef0123456789abcdef01234567",
      catalogInterfaceArtifact: d32(2)), constraintKind: ckExactFingerprint)],
    parents: parents,
    patches: @[Patch(appliesToKind: ptTarget, appliesToIndex: 0,
      blob: BlobRef(id: blobId(blob), mediaType: "text/x-diff", size: uint64(blob.len)),
      strip: 1, order: 0)],
    authors: @[kid(k)]))
  env.signEnvelope(k)
  (encodeEnvelope(env), blob)

proc idOf(b: seq[byte]): Digest32 = Digest32(decodeAndVerify(b).id)

proc waitFor200(f: Fetch; path: string; seconds = 20): bool =
  let deadline = epochTime() + float(seconds)
  while epochTime() < deadline:
    if f(path)[0] == 200: return true
    sleep(20)
  false

proc blockVerdict(id: Digest32): Envelope =
  result = newStatementEnvelope(Statement(kind: skVerdict, subjectKind: sbRelease,
    subject: id, scope: @["block"]))
  result.signEnvelope(policyA)
  result.signEnvelope(policyB)

proc policyCount(f: Fetch): int =
  decodeEnvelopeList(f("/v1/policy/latest")[1]).len

suite "Remix M7 — federation, mirrors and offline install":

  test "a mirror carries identical releases and policy; offline installs gate on it":
    let root = createTempDir("remix-federation-", "")
    var up = startDouble(root / "upstream", upstreamKey, policyKeys = policyKeys,
                         policyThreshold = 2)
    var mi = startDouble(root / "mirror", mirrorKey, policyKeys = policyKeys,
                         policyThreshold = 2)
    var liar = startDouble(root / "liar", liarKey, policyKeys = policyKeys,
                           policyThreshold = 2)
    defer:
      up.stopDouble(); mi.stopDouble(); liar.stopDouble()
      removeDir(root)
    let upF = httpFetch(up.readBase)
    let miF = httpFetch(mi.readBase)
    let liarF = httpFetch(liar.readBase)

    # Upstream: alice publishes A and B; policy blocks B.
    let alice = generateKeypair()
    discard submit(up.intakeBase, "release", genesis(alice))
    check upF.waitFor200("/v1/key-log/" & toHex(kid(alice)))
    let (aEnv, aBlob) = manifest("alice/a", alice)
    let (bEnv, bBlob) = manifest("alice/b", alice)
    for (e, b) in [(aEnv, aBlob), (bEnv, bBlob)]:
      discard submit(up.intakeBase, "blob", b)
      discard submit(up.intakeBase, "release", e)
    check upF.waitFor200("/v1/release/" & toHex(idOf(aEnv)))
    check upF.waitFor200("/v1/release/" & toHex(idOf(bEnv)))
    up.dropPolicy(blockVerdict(idOf(bEnv)))
    let deadline = epochTime() + 20
    while epochTime() < deadline and policyCount(upF) == 0: sleep(20)
    check policyCount(upF) == 1

    # The honest mirror syncs everything; the liar drops policy on the floor.
    let honest = newMirrorSync(upF, upstreamTrust, root / "mirror")
    check honest.sync() == soSynced
    let lying = newMirrorSync(upF, upstreamTrust, root / "liar")
    lying.copyPolicy = false                 # the attack: withhold the block
    check lying.sync() == soSynced
    for (e, _) in [(aEnv, aBlob), (bEnv, bBlob)]:
      check miF.waitFor200("/v1/release/" & toHex(idOf(e)))
      check liarF.waitFor200("/v1/release/" & toHex(idOf(e)))
    let deadline2 = epochTime() + 20
    while epochTime() < deadline2 and policyCount(miF) == 0: sleep(20)
    check policyCount(miF) == 1

    # Identities and bytes are unchanged by mirroring.
    check miF("/v1/release/" & toHex(idOf(aEnv)))[1] == aEnv
    check fetchAndAccept(miF, idOf(aEnv), mirrorTrust).decision.accepted

    # Offline: export from the mirror, plan with no network.
    let now = getTime().toUnix
    let offlineA = exportOffline(miF, idOf(aEnv), mirrorTrust, now)
    let planA = planFromOffline(offlineA, idOf(aEnv), mirrorTrust, now, 3600,
                                admittedLicenses = @["MIT"])
    check planA.ok
    check lockMembers(planA.plan.lockBytes) == @[idOf(aEnv)]
    let offlineB = exportOffline(miF, idOf(bEnv), mirrorTrust, now)
    let planB = planFromOffline(offlineB, idOf(bEnv), mirrorTrust, now, 3600,
                                admittedLicenses = @["MIT"])
    check not planB.ok
    check planB.refusals.mapIt(it.reason) == @[rrBlockedByPolicy]

    # Stale: a day later the frozen snapshot is refused unless the
    # organization allows offline installs; the block still holds then.
    let later = now + 86400
    check planFromOffline(offlineA, idOf(aEnv), mirrorTrust, later, 3600).stalePolicy
    check planFromOffline(offlineA, idOf(aEnv), mirrorTrust, later, 3600,
      allowStaleOffline = true, admittedLicenses = @["MIT"]).ok
    check not planFromOffline(offlineB, idOf(bEnv), mirrorTrust, later, 3600,
      allowStaleOffline = true, admittedLicenses = @["MIT"]).ok

    # Missing revocation: the liar's own view is self-consistent, but set
    # against any upstream snapshot its missing policy is evidence.
    let (_, liarPolicy) = fetchPolicySnapshot(liarF, liarTrust, now, 0)
    let (_, upPolicy) = fetchPolicySnapshot(upF, upstreamTrust, now, 0)
    check liarPolicy.len == 0
    check missingPolicy(liarPolicy, upPolicy) == @[statementId(blockVerdict(idOf(bEnv)))]
    let (_, honestPolicy) = fetchPolicySnapshot(miF, mirrorTrust, now, 0)
    check missingPolicy(honestPolicy, upPolicy).len == 0

    # A bundle whose policy list was trimmed no longer matches its
    # checkpoint's commitment.
    let trimmed = readBundle(offlineB).entries.filterIt(not (it.kind == bekStatementEnvelope and
      decodeStatement(decodeEnvelope(it.bytes).body).kind == skVerdict))
    let trimmedBytes = writeBundle(trimmed.mapIt((it.kind, it.bytes)))
    var reason = "accepted"
    try:
      discard planFromOffline(trimmedBytes, idOf(bEnv), mirrorTrust, now, 3600,
                              admittedLicenses = @["MIT"])
    except RemixError as e:
      reason = $e.reason
    check reason == $rrDigestMismatch

  test "a mirror stops on a split view and keeps the evidence":
    let root = createTempDir("remix-federation-", "")
    var up = startDouble(root / "upstream", upstreamKey, policyKeys = policyKeys,
                         policyThreshold = 2)
    defer:
      up.stopDouble()
      removeDir(root)
    let upF = httpFetch(up.readBase)
    let alice = generateKeypair()
    discard submit(up.intakeBase, "release", genesis(alice))
    check upF.waitFor200("/v1/key-log/" & toHex(kid(alice)))
    let m = newMirrorSync(upF, upstreamTrust, root / "mirror")
    check m.sync() == soSynced
    # The upstream key signs a different tree of the same size.
    let real = decodeStatement(decodeEnvelope(upF("/v1/checkpoint/latest")[1]).body)
    var forged = newStatementEnvelope(Statement(kind: skLogCheckpoint, subjectKind: sbLog,
      subject: kid(upstreamKey), treeSize: real.treeSize, rootHash: d32(77),
      scope: real.scope, issuedAt: real.issuedAt))
    forged.signEnvelope(upstreamKey)
    let forgedBytes = encodeEnvelope(forged)
    m.upstream = proc (path: string): (int, seq[byte]) =
      if path == "/v1/checkpoint/latest": (200, forgedBytes) else: upF(path)
    check m.sync() == soSplitView
    check m.evidence.len == 1
    let (a, b) = m.evidence[0]
    check verifyEquivocationEvidence(EquivocationEvidence(
      a: verifyCheckpoint(a, upstreamTrust.logKeys),
      b: verifyCheckpoint(b, upstreamTrust.logKeys)), upstreamTrust.logKeys)
