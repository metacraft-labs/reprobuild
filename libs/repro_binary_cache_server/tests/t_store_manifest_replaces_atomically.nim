## A republished manifest replaces the file at its path; it is never
## written through it.
##
## Found by the review of the llm-api-proxy publish procedure (2026-11-01):
## `storeManifest` wrote the envelope with a plain `writeFile` over the
## final path. A republish (the same entry key published again, as an
## appliance pin change does) truncated the old file in place, so a
## concurrent reader could see a partial envelope, and a symlink sitting at
## the path was followed. It now writes a temporary file in the same
## directory and renames it over the path.
##
## Real files, a real server state and a real signed manifest; no mocks.

import std/[os, tempfiles, unittest]
when defined(posix):
  import std/posix

import ../src/repro_binary_cache_server/types
import ../src/repro_binary_cache_server/index
import ../src/repro_binary_cache_server/manifest_codec
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

proc sampleManifest(kp: peerAuth.PeerKeypair; version: string):
    BinaryCacheManifest =
  var digest: Blake3Hash
  for i in 0 ..< 32:
    digest[i] = byte(i)
  result = BinaryCacheManifest(
    formatVersion: BinaryCacheFormatVersion,
    entryKey: CacheEntryKey(packageName: "probe", packageVersion: version,
      platform: PlatformTriple(cpu: "armv7", os: "linux", abi: "gnu",
        libcVariant: ""),
      toolchain: ToolchainIdentity(name: "t", version: "1"),
      providerRevision: "r"),
    payloads: @[PayloadObject(kind: pkPrefixArchive, compression: ckNone,
      declaredSize: 4, uncompressedSize: 4, digest: digest, name: "p")],
    realizedPrefixDigest: digest,
    relocationPolicy: rpForbidden,
    createdAtUnix: 1_750_000_000'i64,
    producerPubKey: kp.publicKey)
  signManifest(kp, result)

suite "storeManifest":

  test "a republish leaves a whole manifest and no temporary file":
    let root = createTempDir("store-manifest-", "")
    defer: removeDir(root)
    let s = openBinaryCacheServer(root)
    let kp = peerAuth.generateKeypair()
    let path = s.storeManifest(sampleManifest(kp, "1"))
    let again = s.storeManifest(sampleManifest(kp, "1"))
    check again == path
    check decodeManifest(cast[seq[byte]](readFile(path))).entryKey.packageName ==
      "probe"
    for entry in walkDir(parentDir(path)):
      check entry.path == path

  when defined(posix):
    test "a symlink at the manifest path is replaced, not written through":
      let root = createTempDir("store-manifest-", "")
      defer: removeDir(root)
      let s = openBinaryCacheServer(root)
      let kp = peerAuth.generateKeypair()
      let m = sampleManifest(kp, "2")
      let path = s.storeManifest(m)
      removeFile(path)
      writeFile(root / "victim", "do not touch")
      createSymlink(root / "victim", path)
      discard s.storeManifest(m)
      check readFile(root / "victim") == "do not touch"
      check not symlinkExists(path)
      check fileExists(path)

  test "a temporary file left by an interrupted store is swept on open":
    let root = createTempDir("store-manifest-", "")
    defer: removeDir(root)
    let s = openBinaryCacheServer(root)
    let kp = peerAuth.generateKeypair()
    let path = s.storeManifest(sampleManifest(kp, "3"))
    let stale = parentDir(path) / ".manifest-crashed.tmp"
    writeFile(stale, "half a manifest")
    discard openBinaryCacheServer(root)
    check not fileExists(stale)
    check fileExists(path)
