## Peer-Cache-BearSSL M1 verification: trust-anchor file format.
##
## The M3 stand-in carried `<pubkey_hex>:<privkey_hex>` per line; M1
## switches to one hex-encoded ECDSA-P256 public key per line (130 hex
## chars = 65-byte uncompressed pubkey). No compat shim — the legacy
## format is rejected with a clear error.
##
## Coverage:
##   1. A pubkey-only file (one or more lines) parses cleanly.
##   2. The legacy `<pub>:<priv>` shape raises `AuthError` with a
##      clear migration message.
##   3. Malformed lines raise `AuthError` carrying the line number.
##   4. Round-trip: write → load produces the same anchor set.

import std/[os, sets, strutils, unittest]

import repro_peer_cache

{.used.}

const HexChars = "0123456789abcdef"

proc toHexN(buf: openArray[byte]): string =
  result = newString(buf.len * 2)
  for i, b in buf:
    result[2 * i] = HexChars[(int(b) shr 4) and 0xf]
    result[2 * i + 1] = HexChars[int(b) and 0xf]

proc setupTempDir(name: string): string =
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "peer-cache ECDSA-P256 trust-anchor file format":

  test "hex-pubkey-per-line parses cleanly":
    let tmpDir = setupTempDir("t_peer_cache_ecdsa_anchor_ok")
    defer:
      try: removeDir(tmpDir) except CatchableError: discard

    let kpA = generateKeypair()
    let kpB = generateKeypair()
    let path = tmpDir / "anchors.txt"
    writeTrustAnchors(path, [kpA, kpB])

    let anchors = loadTrustAnchors(path)
    check kpA.publicKey in anchors.publicKeys
    check kpB.publicKey in anchors.publicKeys
    check anchors.publicKeys.len == 2

  test "legacy `<pub>:<priv>` format rejected with clear error":
    let tmpDir = setupTempDir("t_peer_cache_ecdsa_anchor_legacy")
    defer:
      try: removeDir(tmpDir) except CatchableError: discard

    let kp = generateKeypair()
    let path = tmpDir / "legacy.anchor"
    # Synthesise a "legacy" line by appending a hex private-key half
    # separated by a colon. We pick 32 zero-bytes for the priv half —
    # the parser must reject on the colon before doing anything else.
    let legacyLine = toHexN(kp.publicKey) & ":" & repeat('0', 64)
    writeFile(path, legacyLine & "\n")

    try:
      discard loadTrustAnchors(path)
      check false  # should have raised
    except AuthError as err:
      check "legacy" in err.msg
      check "pubkey-only" in err.msg

  test "malformed hex raises AuthError with line number":
    let tmpDir = setupTempDir("t_peer_cache_ecdsa_anchor_malformed")
    defer:
      try: removeDir(tmpDir) except CatchableError: discard

    let kpGood = generateKeypair()
    let path = tmpDir / "malformed.anchor"
    # Line 1: a comment (ignored).
    # Line 2: a good pubkey.
    # Line 3: blank (ignored).
    # Line 4: not enough hex chars.
    let content =
      "# malformed-anchor fixture\n" &
      toHexN(kpGood.publicKey) & "\n" &
      "\n" &
      "deadbeef\n"
    writeFile(path, content)

    try:
      discard loadTrustAnchors(path)
      check false  # should have raised
    except AuthError as err:
      # The bad line is line 4; the error must point at it.
      check "line 4" in err.msg

  test "round-trip: write -> load -> write -> load is idempotent":
    let tmpDir = setupTempDir("t_peer_cache_ecdsa_anchor_round_trip")
    defer:
      try: removeDir(tmpDir) except CatchableError: discard

    let kps = @[generateKeypair(), generateKeypair(), generateKeypair()]
    let pathA = tmpDir / "first.anchor"
    let pathB = tmpDir / "second.anchor"
    writeTrustAnchors(pathA, kps)
    let loadedA = loadTrustAnchors(pathA)
    writeTrustAnchors(pathB, loadedA)
    let loadedB = loadTrustAnchors(pathB)

    check loadedA.publicKeys == loadedB.publicKeys
    for kp in kps:
      check kp.publicKey in loadedB.publicKeys
