## ReproOS-Remix-Protocol-And-Registry M1 verification
## ``test_remix_manifest_canonical_roundtrip_and_identity``.
##
## "Equivalent manifests serialize identically, preserve lineage, and change
## identity for every semantically material field or blob."
##
## Nothing is mocked: real BearSSL ECDSA-P256 keys sign real envelopes, and
## every assertion runs the same decode/verify path a client would. The
## lineage resolver is an in-memory table of real decoded envelopes, which is
## what an offline export bundle gives a client.

import std/[algorithm, sequtils, tables, unittest]

import repro_remix
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

proc d32(seed: byte): Digest32 =
  for i in 0 ..< 32:
    result[i] = seed xor byte(i)

proc cmpD(a, b: Digest32): int =
  for i in 0 ..< 32:
    if a[i] != b[i]:
      return cmp(a[i], b[i])
  0

proc bytesOf(s: string): seq[byte] = s.mapIt(byte(ord(it)))

proc blob(text, mediaType: string): BlobRef =
  BlobRef(id: blobId(bytesOf(text)), mediaType: mediaType,
          size: uint64(text.len))

proc original(pkg: string; seed: byte): OriginalRef =
  OriginalRef(package: pkg, interfaceFingerprint: d32(seed),
    catalogWorkspace: "reprobuild-packages",
    catalogRemote: "https://github.com/metacraft-labs/reprobuild-packages",
    catalogRevision: "0123456789abcdef0123456789abcdef01234567",
    catalogInterfaceArtifact: d32(seed + 1))

proc sortedIds(ids: varargs[Digest32]): seq[Digest32] =
  result = @ids
  result.sort(proc (a, b: Digest32): int = cmpD(a, b))

proc fixture(authors: seq[Digest32]; parents: seq[Digest32] = @[]): Manifest =
  ## A manifest exercising every field, already in canonical order.
  let fragA = blob("package tabs: discard", "text/x-nim")
  let fragB = blob("package tabs_test: discard", "text/x-nim")
  var frags = @[fragA, fragB]
  frags.sort(proc (a, b: BlobRef): int = cmpD(a.id, b.id))
  var assets = @[blob("PNG1", "image/png"), blob("PNG2", "image/png")]
  assets.sort(proc (a, b: BlobRef): int = cmpD(a.id, b.id))
  Manifest(
    remixName: "alice/compact-tabs",
    version: "1.2.0",
    intent: "Make the tab strip 30% shorter.\nKeeps title text legible.",
    license: "MIT OR Apache-2.0",
    targets: @[Target(original: original("firefox", 7),
                      constraintKind: ckVersionRange, constraint: ">=128 <130")],
    platforms: @["aarch64-linux", "x86_64-linux"],
    parents: parents,
    sources: @[SourceTree(repo: "compact-tabs",
      remote: "https://example.invalid/compact-tabs.git",
      revision: "89abcdef0123456789abcdef0123456789abcdef",
      digest: "blake3:" & toHex(d32(9)))],
    patches: @[
      Patch(appliesToKind: ptTarget, appliesToIndex: 0,
            blob: blob("--- a/x\n+++ b/x\n", "text/x-diff"), strip: 1, order: 0),
      Patch(appliesToKind: ptTarget, appliesToIndex: 0,
            blob: blob("--- a/y\n+++ b/y\n", "text/x-diff"), strip: 1, order: 1)],
    graphFragments: frags,
    configuration: @[ConfigContribution(configurable: "firefox.tabHeight",
      schemaFingerprint: d32(11), priority: cpSet, operation: coReplace,
      value: blob("24", "application/x-repro-config"))],
    exposedConfigurables: @[ExposedConfigurable(name: "firefox.tabHeight",
                                                schemaFingerprint: d32(11))],
    tests: @[TestRef(name: "tabs-render", fragment: 0)],
    healthChecks: @[HealthCheck(kind: hcCommandExitZero, target: "tabs-render",
                                timeoutSeconds: 30)],
    assets: assets,
    permissions: @[Permission(kind: pkFilesystemRead, scope: "user-config")],
    dataMigrations: @[DataMigration(store: "firefox-profile",
                                    kind: mkReversible, edge: "migrate-tabs")],
    dependenciesAdded: @[original("libtabs", 21)],
    authors: authors,
    extensions: @[Extension(id: "x-example.note", critical: false,
                            payload: bytesOf("hi"))])

proc signed(m: Manifest; keys: seq[PeerKeypair]): seq[byte] =
  var env = newManifestEnvelope(m)
  for k in keys:
    env.signEnvelope(k)
  encodeEnvelope(env)

let alice = generateKeypair()
let bob = generateKeypair()
let aliceId = Digest32(keyIdOf(alice))
let bobId = Digest32(keyIdOf(bob))
let bothAuthors = sortedIds(aliceId, bobId)

suite "Remix M1 — canonical roundtrip and identity":

  test "a signed manifest round-trips byte-for-byte and verifies offline":
    let m = fixture(bothAuthors)
    let bytes = signed(m, @[alice, bob])
    let v = decodeAndVerify(bytes)
    check v.manifest == m
    check v.authors.len == 2
    check encodeEnvelope(decodeEnvelope(bytes)) == bytes
    check encodeManifest(v.manifest) == decodeEnvelope(bytes).body

  test "equivalent manifests serialize identically":
    # Signing order and repeated encoding must not change a single byte.
    let m = fixture(bothAuthors)
    check signed(m, @[alice, bob]) == signed(m, @[bob, alice])
    check encodeManifest(m) == encodeManifest(fixture(bothAuthors))

  test "signatures are not part of the release identity":
    let m = fixture(bothAuthors)
    let a = decodeEnvelope(signed(m, @[alice, bob]))
    var unsigned = newManifestEnvelope(m)
    check releaseId(a) == releaseId(unsigned)

  test "every semantically material field and blob changes the identity":
    let base = fixture(@[aliceId])
    var variants: seq[(string, Manifest)]
    template variant(label: string; body: untyped) =
      block:
        var it {.inject.} = base
        body
        variants.add((label, it))
    variant("remixName"): it.remixName = "alice/compact-tabs2"
    variant("version"): it.version = "1.2.1"
    variant("intent"): it.intent = "Make the tab strip 31% shorter."
    variant("license"): it.license = "MIT"
    variant("target constraint"): it.targets[0].constraint = ">=128 <131"
    variant("target fingerprint"): it.targets[0].original.interfaceFingerprint = d32(99)
    variant("target catalog revision"):
      it.targets[0].original.catalogRevision = "1123456789abcdef0123456789abcdef01234567"
    variant("platforms"): it.platforms = @["x86_64-linux"]
    variant("parents"): it.parents = @[d32(42)]
    variant("source revision"):
      it.sources[0].revision = "99abcdef0123456789abcdef0123456789abcdef"
    variant("patch blob"):
      it.patches[0].blob = blob("--- a/x\n+++ b/z\n", "text/x-diff")
    variant("patch strip"): it.patches[0].strip = 0
    variant("patch order"): it.patches[1].order = 5
    variant("graph fragment blob"):
      it.graphFragments = @[blob("package other: discard", "text/x-nim")]
      it.tests[0].fragment = 0
    variant("configuration value blob"):
      it.configuration[0].value = blob("28", "application/x-repro-config")
    variant("configuration priority"): it.configuration[0].priority = cpOverride
    variant("configuration operation"): it.configuration[0].operation = coAppend
    variant("exposed configurable"): it.exposedConfigurables = @[]
    variant("test"): it.tests[0].name = "tabs-render-2"
    variant("health check timeout"): it.healthChecks[0].timeoutSeconds = 31
    variant("asset blob"): it.assets = @[blob("PNG3", "image/png")]
    variant("asset media type"): it.assets[0].mediaType = "image/webp"
    variant("permission"): it.permissions[0].scope = "user-cache"
    variant("data migration kind"): it.dataMigrations[0].kind = mkOneWay
    variant("dependency added"): it.dependenciesAdded = @[]
    variant("authors"): it.authors = @[bobId]
    variant("extension payload"): it.extensions[0].payload = bytesOf("ho")
    variant("extension removed"): it.extensions = @[]

    var seen = initTable[string, string]()
    seen[$ReleaseId(releaseId(newManifestEnvelope(base)))] = "base"
    for (label, m) in variants:
      let id = $releaseId(newManifestEnvelope(m))
      checkpoint label
      check id notin seen
      seen[id] = label
    check seen.len == variants.len + 1

  test "a required-feature bit is part of the identity":
    let m = fixture(@[aliceId])
    var env = newManifestEnvelope(m)
    let before = releaseId(env)
    env.requiredFeatures = 1
    check releaseId(env) != before

  test "lineage preserves every ancestor once, in deterministic order":
    # A diamond: d -> (b, c) -> a.
    var store = initTable[Digest32, seq[Digest32]]()
    proc publish(m: Manifest): Digest32 =
      let v = decodeAndVerify(signed(m, @[alice]))
      result = Digest32(v.id)
      store[result] = v.manifest.parents
    let a = publish(fixture(@[aliceId]))
    var mb = fixture(@[aliceId], @[a]); mb.remixName = "alice/b"
    var mc = fixture(@[aliceId], @[a]); mc.remixName = "alice/c"
    let b = publish(mb)
    let c = publish(mc)
    var md = fixture(@[aliceId], sortedIds(b, c)); md.remixName = "alice/d"
    let d = publish(md)
    let resolver: ParentResolver = proc (id: ReleaseId): (bool, seq[Digest32]) =
      let key = Digest32(id)
      if key in store: (true, store[key]) else: (false, @[])
    let l = walkLineage(ReleaseId(d), resolver)
    check l.isComplete
    check l.ancestors.len == 3
    check l.isAncestor(ReleaseId(a))
    check walkLineage(ReleaseId(d), resolver).ancestors == l.ancestors
    # Dropping an ancestor makes the lineage incomplete, not wrong.
    store.del a
    let partial = walkLineage(ReleaseId(d), resolver)
    check not partial.isComplete
    check partial.missing == @[ReleaseId(a)]
    expect RemixError:
      partial.requireComplete()
