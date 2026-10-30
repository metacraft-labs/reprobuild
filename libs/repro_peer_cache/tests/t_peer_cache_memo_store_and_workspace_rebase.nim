## Distributed-Execution M0 unit coverage for the two-phase building blocks:
##
## * `$WORKSPACE` normalization / rebasing (`workspace_paths.nim`), including
##   the macOS `/tmp` -> `/private/tmp` style symlinked spelling and the
##   refusal of an escaping relative part;
## * the canonical PathSet blob and the two-phase strong fingerprint;
## * the on-disk memo store: selectors under one weak fingerprint coexist,
##   a second write for an existing selector never clobbers it, a file whose
##   content disagrees with its name is not served, and the advertisement
##   set carries the memo key plus every content blob;
## * the memoization plane over loopback TCP: an anonymous (CIDR-only)
##   caller is refused it per message (Distributed-Execution M7), and a
##   server wired to a memo store answers an authenticated peer's selector
##   and entry requests over TLS, while a content-plane request for a memo
##   key is an honest miss, never a suspect mark. The entry it serves
##   carries a record the cross-host publication rule accepts (campaign
##   M17): a node serves only what it would publish, so an entry whose
##   record bytes decode to nothing, or to a timestamp-policy record, is
##   declined by its reader and never reaches the wire.
##
## No mocks: real files in a temp dir, real loopback sockets, real TLS with
## host-CA leaves.

import std/[asyncdispatch, options, os, strutils, tables, tempfiles, unittest]

import repro_hash
import repro_local_store
import repro_peer_cache
import repro_cli_support/peer_cache_wiring

import ./m7_test_pki

proc digestN(seed: byte): BlobDigest =
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = byte((int(seed) * 13 + i) and 0xff)
  blobDigestFromBytes(raw)

proc contentDigestN(seed: byte; domain: HashDomain): ContentDigest =
  result = ContentDigest(algorithm: haBlake3_256, domain: domain)
  for i in 0 ..< 32:
    result.bytes[i] = byte((int(seed) * 13 + i) and 0xff)

proc recordFor(seed: byte): ActionResultRecord =
  ## A record the publication rule accepts (Edge-Derived-Identities.md
  ## §3.3a and §3.4 item 1; `publicationRefusal`): made under `ffpChecksum`,
  ## every regular-file input carrying a content hash, and one CAS output.
  ## Its inputs are the entry's path set. A node serves an entry only when
  ## the rule accepts its record (campaign M17, `entryReaderFor`), so a
  ## fixture entry carries a real record, as every published one does.
  proc input(path: string; seed: byte): FileFingerprint =
    FileFingerprint(path: path, policy: ffpChecksum,
      metadata: FileMetadata(kind: ffkRegular, sizeBytes: uint64(seed) + 10,
        mtimeNs: 1_700_000_000_000_000_000'u64),
      hasLocalHash: true,
      localHash: LocalInvalidationHash(algorithm: haXxh3_64,
        domain: hdLocalInvalidation, value: uint64(seed) * 7919))
  ActionResultRecord(
    weakFingerprint: contentDigestN(seed, hdActionFingerprint),
    policy: ffpChecksum,
    inputs: @[input("$WORKSPACE/main.c", 1),
              input("$WORKSPACE/config-" & $seed & ".h", seed)],
    strongFingerprint: contentDigestN(seed + 50, hdActionFingerprint),
    outputPayloadKind: opkCasBlobs,
    outputs: @[OutputBlob(path: "$WORKSPACE/out/hello",
      metadata: FileMetadata(kind: ffkRegular, sizeBytes: 64,
        mtimeNs: 1_700_000_000_000_000_000'u64),
      blob: CasBlobRef(digest: contentDigestN(seed + 100, hdCasContent),
        sizeBytes: 64),
      permissions: {fpUserRead, fpUserWrite, fpUserExec})])

proc entryFor(weak: BlobDigest; seed: byte): MemoEntry =
  let pathSet = encodePeerPathSet(@["$WORKSPACE/main.c",
    "$WORKSPACE/config-" & $seed & ".h"])
  let psd = digestOf(pathSet)
  MemoEntry(weakFingerprint: weak, pathSetDigest: psd,
    strongFingerprint: twoPhaseStrongFingerprint(weak, psd,
      @["id-a", "id-" & $seed]),
    recordBytes: encodeActionResultRecord(recordFor(seed)),
    outputDigests: @[digestN(seed + 100)],
    evidenceLevel: elComplete)

suite "Distributed-Execution M0: workspace rebasing":

  test "paths inside the workspace become $WORKSPACE markers and rebase":
    let root = createTempDir("m0-ws-", "")
    defer: removeDir(root)
    check normalizeWorkspacePath(root / "src" / "main.c", root) ==
      "$WORKSPACE/src/main.c"
    check normalizeWorkspacePath(root, root) == WorkspaceMarker
    check rebaseWorkspacePath("$WORKSPACE/src/main.c", "/other/ws") ==
      normalizedPath("/other/ws" / "src" / "main.c")
    check rebaseWorkspacePath(WorkspaceMarker, "/other/ws") == "/other/ws"
    check isWorkspaceMarked("$WORKSPACE/x")
    check not isWorkspaceMarked("$WORKSPACEX/x")

  test "outside paths, relative names and an empty root are left alone":
    let root = createTempDir("m0-ws-", "")
    defer: removeDir(root)
    check normalizeWorkspacePath("/usr/include/stdio.h", root) ==
      "/usr/include/stdio.h"
    check normalizeWorkspacePath("src/main.c", root) == "src/main.c"
    check normalizeWorkspacePath(root & "-sibling/x", root) ==
      root & "-sibling/x"
    check normalizeWorkspacePath(root / "x", "") == root / "x"
    check rebaseWorkspacePath("/usr/include/stdio.h", root) ==
      "/usr/include/stdio.h"

  test "a symlinked spelling of the root is recognised":
    let real = createTempDir("m0-ws-real-", "")
    let link = real & "-link"
    defer:
      removeFile(link)
      removeDir(real)
    createSymlink(real, link)
    # Configured as the link; a path recorded under the resolved target.
    check normalizeWorkspacePath(expandFilename(real) / "a.c", link) ==
      "$WORKSPACE/a.c"

  test "escaping or root-less markers are refused":
    expect WorkspacePathError:
      discard rebaseWorkspacePath("$WORKSPACE/../etc/passwd", "/ws")
    expect WorkspacePathError:
      discard rebaseWorkspacePath("$WORKSPACE/a", "")

suite "Distributed-Execution M0: ancestor probes of the workspace":

  test "isWorkspaceAncestor recognises proper ancestors only":
    let base = createTempDir("m0-anc-", "")
    defer: removeDir(base)
    let ws = base / "pa" / "x" / "ws"
    createDir(ws)
    check isWorkspaceAncestor(base / "pa" / "x", ws)
    check isWorkspaceAncestor(base, ws)
    check isWorkspaceAncestor("/", ws)
    check isWorkspaceAncestor(expandFilename(base / "pa"), ws)  # other spelling
    check not isWorkspaceAncestor(ws, ws)
    check not isWorkspaceAncestor(ws / "src", ws)
    check not isWorkspaceAncestor(base / "pa" / "sibling", ws)
    check not isWorkspaceAncestor(base / "p", ws)               # prefix, not dir

  test "only existence-only directory probes of ancestors are dropped":
    let base = createTempDir("m0-anc-", "")
    defer: removeDir(base)
    let wsA = base / "pa" / "x" / "ws-a"
    let wsB = base / "pb" / "ws-b"
    for ws in [wsA, wsB]:
      createDir(ws)
      writeFile(ws / "main.c", "int main(void){return 0;}\n")
    let outside = base / "shared-header.h"   # a REAL input outside both
    writeFile(outside, "#define X 1\n")
    proc recordFor(ws: string): ActionResultRecord =
      result.policy = ffpTimestamp
      for path in [ws / "main.c", outside]:
        result.inputs.add(observeFile(path, ffpTimestamp))
      var dir = ws.parentDir
      while dir.len > 0:
        var probe = observeFile(dir, ffpTimestamp)
        result.inputs.add(probe)
        if dir.parentDir == dir: break
        dir = dir.parentDir
      # An ENUMERATED ancestor depends on its other entries: never dropped.
      result.inputs.add(observeEnumeratedDirectory(base, ffpTimestamp))
    let weak = digestN(40)
    proc strongOf(ws: string): tuple[pathSet: PeerPathSet; strong: BlobDigest] =
      let ctx = TwoPhaseContext(peerKey: weak, cwd: ws, workspaceRoot: ws,
        portable: true)
      let normalized = normalizeRecord(recordFor(ws), ctx)
      let ps = pathSetOf(normalized, ctx)
      (ps, twoPhaseStrongFingerprint(weak, digestOf(encodePeerPathSet(ps)),
        identitiesFor(ps, ctx)))
    let a = strongOf(wsA)
    let b = strongOf(wsB)
    # Different parents at different depths: same PathSet, same strong.
    check a.pathSet == b.pathSet
    check a.strong == b.strong
    check ("r:$WORKSPACE/main.c") in a.pathSet
    check ("r:" & outside) in a.pathSet
    check ("e:" & base) in a.pathSet
    for entry in a.pathSet:
      check not entry.endsWith("/pa") and not entry.endsWith("/x")
    # Soundness: a real input outside the workspace that differs is a miss.
    writeFile(outside, "#define X 2\n")
    check strongOf(wsB).strong != a.strong
    # Without portable caching nothing is dropped.
    let plain = TwoPhaseContext(peerKey: weak, cwd: wsA, workspaceRoot: wsA,
      portable: false)
    check normalizeRecord(recordFor(wsA), plain).inputs.len ==
      recordFor(wsA).inputs.len

suite "Distributed-Execution M0: PathSet and strong fingerprint":

  test "the PathSet blob is canonical, so its digest ignores input order":
    let a = encodePeerPathSet(@["b", "a", "c", "a"])
    let b = encodePeerPathSet(@["c", "b", "a"])
    check a == b
    check decodePeerPathSet(a) == @["a", "b", "c"]
    check digestOf(a) == digestOf(b)

  test "a non-canonical PathSet encoding is rejected":
    # Hand-build "RPPS" (the current version) with entries out of order.
    var raw: seq[byte] = @[byte('R'), byte('P'), byte('P'), byte('S'),
      byte(PathSetVersion and 0xff), byte(PathSetVersion shr 8), 2, 0, 0, 0]
    for s in ["b", "a"]:
      raw.add(@[1'u8, 0, 0, 0])
      raw.add(byte(ord(s[0])))
    try:
      discard decodePeerPathSet(raw)
      check false
    except LegacyPeerFormatError:
      check false   # the current version, so not refused as a legacy one
    except PeerMemoStoreError as err:
      check "not canonical" in err.msg
    # Campaign M17 chunk 2: a version-1 PathSet (before the published-trace
    # record) is refused as a legacy format, canonical or not.
    raw[4] = 1   # version-literal-ok: the frozen pre-rbpm-v2 PathSet version, refused as legacy
    expect LegacyPeerFormatError:
      discard decodePeerPathSet(raw)

  test "the strong fingerprint moves with any identity and only then":
    let weak = digestN(1)
    let psd = digestN(2)
    let base = twoPhaseStrongFingerprint(weak, psd, @["x", "y"])
    check base == twoPhaseStrongFingerprint(weak, psd, @["x", "y"])
    check base != twoPhaseStrongFingerprint(weak, psd, @["x", "z"])
    check base != twoPhaseStrongFingerprint(digestN(3), psd, @["x", "y"])
    check base != twoPhaseStrongFingerprint(weak, digestN(4), @["x", "y"])
    # Framing: moving a boundary changes the fingerprint.
    check twoPhaseStrongFingerprint(weak, psd, @["ab", "c"]) !=
      twoPhaseStrongFingerprint(weak, psd, @["a", "bc"])

suite "Distributed-Execution M0: memo store":

  test "selectors under one weak fingerprint coexist and never clobber":
    let root = createTempDir("m0-memo-", "")
    defer: removeDir(root)
    let store = openPeerMemoStore(root)
    let weak = digestN(9)
    let first = entryFor(weak, 1)
    let second = entryFor(weak, 2)
    check store.writeMemoEntry(first)
    check store.writeMemoEntry(second)
    check store.listSelectors(weak).len == 2
    check selectorOf(first) in store.listSelectors(weak)
    check selectorOf(second) in store.listSelectors(weak)
    # A second writer for an existing selector does not replace it.
    var impostor = first
    impostor.recordBytes = @[0'u8]
    check not store.writeMemoEntry(impostor)
    check store.readMemoEntryBytes(weak, first.strongFingerprint).get() ==
      encodeMemoEntry(first)
    check store.weakFingerprints() == @[weak]
    check store.listSelectors(digestN(10)).len == 0

  test "an entry whose content disagrees with its file name is not served":
    let root = createTempDir("m0-memo-", "")
    defer: removeDir(root)
    let store = openPeerMemoStore(root)
    let weak = digestN(11)
    let good = entryFor(weak, 3)
    let other = entryFor(weak, 4)
    store.writeMemoEntry(good)
    # Overwrite good's file with other's bytes.
    let path = root / "v1" / $weak / ($good.strongFingerprint & ".rpme")
    let bytes = encodeMemoEntry(other)
    var text = newString(bytes.len)
    for i, b in bytes: text[i] = char(b)
    writeFile(path, text)
    check store.readMemoEntryBytes(weak, good.strongFingerprint).isNone
    check store.listSelectors(weak).len == 0

  test "advertised keys carry the memo key and every content blob":
    let root = createTempDir("m0-memo-", "")
    defer: removeDir(root)
    let store = openPeerMemoStore(root)
    let weak = digestN(12)
    let entry = entryFor(weak, 5)
    store.writeMemoEntry(entry)
    let keys = store.advertisedKeys()
    check memoAdvertKey(weak) in keys
    check entry.pathSetDigest in keys
    check entry.outputDigests[0] in keys
    check memoAdvertKey(weak) != weak
    check memoAdvertKey(weak) != memoAdvertKey(digestN(13))

suite "Distributed-Execution M0: memoization plane over loopback TCP":

  test "an anonymous CIDR-only caller is refused the memoization plane":
    # Distributed-Execution M7 (FLOW-4): memo queries need an authenticated
    # caller — a memo entry is only ever accepted with a verified issuer
    # attestation, and an anonymous node can verify none — so the receiver
    # refuses them per message, and serves nothing.
    let root = createTempDir("m0-memo-anon-", "")
    defer: removeDir(root)
    let store = openPeerMemoStore(root)
    let weak = digestN(31)
    store.writeMemoEntry(entryFor(weak, 7))
    var peers = spawnLoopbackPeers(2)
    defer: waitFor shutdownLoopbackPeers(peers)
    waitFor dialAllLoopbackClients(peers)
    let server = peers[1].server
    server.memoSelectorReader = proc(w: BlobDigest): seq[MemoSelector] =
      store.listSelectors(w)
    let client = peers[0].client
    client.fetchTimeoutMs = 1_000
    let sels = waitFor client.requestSelectorsFrom(peers[1].peerId, weak)
    check sels.isNone
    check client.refusalsReceived >= 1
    check client.lastRefusal.refusalClass == uint8(ord(rcUnauthenticated))
    check server.memoRequestsServed == 0
    check server.gate.refusedCount[rcUnauthenticated] >= 1
    check client.suspectMarks == 0

  test "selector and entry requests are served; memo keys are not content":
    # Over TLS between two hosts that pin each other (the shape every LAN
    # node runs since Distributed-Execution M7), in BOTH trust profiles:
    # hardened one-hour host-CA leaves, and trusted pinned long-lived host
    # keys (the product default).
    for profile in [tpHardened, tpTrusted]:
      checkpoint("trust profile: " & $profile)
      let base = createTempDir("m0-memo-tcp-", "")
      defer: removeDir(base)
      let a = newTestNode(base, "a")
      let b = newTestNode(base, "b")
      mutualTrust([a, b])
      let rootB = base / "b-cache"
      createDir(rootB)
      let store = openPeerMemoStore(rootB / PeerMemoDirName)
      let weak = digestN(21)
      var entry = entryFor(weak, 6)
      # Attested by B (its issuer): a node serves an entry only with an
      # attestation a consumer can accept (Distributed-Execution M7, G15).
      attest(entry, mintNodeCredential(b.identity, lrDaemon,
        identityPolicyOf(profile)))
      store.writeMemoEntry(entry)
      let hostB = startPeerCacheHost(tlsConfig(b, profile = profile),
        b.identity.hostId,
        cacheRoot = rootB)
      defer: hostB.stop()
      let hostA = startPeerCacheHost(tlsConfig(a, seeds = @[initEndpoint(
        "127.0.0.1", hostB.actualPort)], profile = profile), a.identity.hostId,
        cacheRoot = base / "a-cache")
      defer: hostA.stop()
      let client = hostA.client
      let target = b.identity.hostId
      check client.isConnected(target)
      let server = hostB.server
      let sels = waitFor client.requestSelectorsFrom(target, weak)
      check sels.isSome
      check sels.get() == @[selectorOf(entry)]
      let miss = waitFor client.requestSelectorsFrom(target, digestN(22))
      check miss.isSome
      check miss.get().len == 0
      let fetched = waitFor client.requestMemoEntryFrom(target, weak,
        entry.strongFingerprint)
      check fetched.isSome
      check decodeMemoEntry(fetched.get()) == entry
      let absent = waitFor client.requestMemoEntryFrom(target, weak, digestN(23))
      check absent.isNone
      # Asking the CONTENT plane for a fingerprint key is a miss — the old
      # bundle-by-weak-fingerprint shape — and must not mark the peer suspect.
      let wrongPlane = waitFor client.requestFetchFrom(target,
        memoAdvertKey(weak))
      check wrongPlane.isNone
      check client.suspectMarks == 0
      check not hostA.registry.entries[target].suspect
      check server.memoRequestsServed == 4
