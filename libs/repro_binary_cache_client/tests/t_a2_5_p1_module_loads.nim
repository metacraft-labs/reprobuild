## A2.5 P1 — module-loads smoke test.
##
## Verifies the client library compiles + every public entry point
## links. Constructs a ``ClientContext`` over a temp store root,
## leases + releases a hash-scratch slot, opens + closes an empty
## client index. No network IO.

import std/[os, random, strutils, tables, unittest]

import ../src/repro_binary_cache_client

suite "A2.5 P1 — module scaffolding":

  test "ClientContext lifecycle":
    randomize()
    let root = getTempDir() / ("a2_5_p1_" & $rand(999_999))
    removeDir(root)
    createDir(root)
    defer:
      try: removeDir(root) except CatchableError: discard

    var ep: seq[SubstituteEndpoint] = @[]
    let cfg = defaultConfig(root, ep)
    let ctx = newClientContext(cfg)
    check ctx != nil
    check ctx.config.chunkBytes == 262144

    # Lease + release a scratch slot.
    let s = ctx.leaseHashScratch()
    check s != nil
    check s.buffer.len == 262144
    check s.inUse
    ctx.releaseHashScratch(s)
    check not s.inUse

    # Re-leasing returns the same slot (pool reuse).
    let s2 = ctx.leaseHashScratch()
    check s2 == s
    ctx.releaseHashScratch(s2)

    # Index round-trip on the temp store.
    let idx = openClientIndex(root)
    check idx.entries.len == 0
    var e = IndexEntry(entryKeyHex: "0123456789abcdef" & "0123456789abcdef" &
                                    "0123456789abcdef" & "0123456789abcdef",
                      realizedPrefixPath: root / "fake",
                      createdAtUnix: 12345,
                      sourceEndpoint: "http://localhost:1234")
    for i in 0 ..< 32:
      e.manifestHash[i] = byte(i)
      e.payloadHash[i] = byte(i + 1)
    idx.upsert(e)
    idx.flush()
    let idx2 = openClientIndex(root)
    check idx2.entries.len == 1
    let lookup = idx2.lookup(e.entryKeyHex)
    check lookup.found
    check lookup.entry.realizedPrefixPath == e.realizedPrefixPath
    check lookup.entry.manifestHash == e.manifestHash

    ctx.close()
    check ctx.closed

  test "HTTP pool URL parsing":
    let p1 = parseTarget("http://localhost:7878/cache-info")
    check p1.host == "localhost"
    check int(p1.port) == 7878
    check p1.path == "/cache-info"
    check not p1.secure

    let p2 = parseTarget("http://example.com/manifests/abc")
    check p2.host == "example.com"
    check int(p2.port) == 80
    check p2.path == "/manifests/abc"

    expect HttpError:
      discard parseTarget("https://example.com/")  # follow-up

  test "compat detect for local platform":
    let local = detectLocalPlatform("/tmp/store")
    check local.cpu in @["x86_64", "aarch64", "unknown"]
    check local.os in @["linux", "windows", "darwin", "unknown"]
    check local.storeDir == "/tmp/store"

  test "ckNone decompressor passthrough":
    let d = newDecompressor(ckNone)
    defer: d.close()
    var captured: seq[byte] = @[]
    proc cbSink(chunk: openArray[byte]) {.gcsafe.} =
      {.cast(gcsafe).}:
        for b in chunk:
          captured.add(b)
    d.feed([byte 1, 2, 3, 4, 5], cbSink)
    check captured == @[byte 1, 2, 3, 4, 5]
    check d.bytesIn == 5
    check d.bytesOut == 5

  test "manifest_codec.decodeAndVerify surface":
    # We can't construct a valid manifest in this smoke test without
    # the keypair / encoder bits — the proper test lives in P2. Here
    # we just assert the proc is callable and the error type wires
    # through correctly.
    expect ClientManifestError:
      discard decodeAndVerify(toOpenArray([byte 0, 0, 0, 0], 0, 3))

  test "in_process: empty endpoints reports failure cleanly":
    randomize()
    let root = getTempDir() / ("a2_5_p1_ip_" & $rand(999_999))
    removeDir(root)
    createDir(root)
    defer:
      try: removeDir(root) except CatchableError: discard
    let res = substituteInProcess("00" & "00" & "00" & "00" & "00" & "00" &
                                  "00" & "00" & "00" & "00" & "00" & "00" &
                                  "00" & "00" & "00" & "00" & "00" & "00" &
                                  "00" & "00" & "00" & "00" & "00" & "00" &
                                  "00" & "00" & "00" & "00" & "00" & "00" &
                                  "00" & "00",
                                  root, @[])
    check not res.ok
    check res.reason.contains("no substitute endpoints")
