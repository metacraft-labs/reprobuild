## Slim, dependency-free CAS reader used by the Windows launcher binary.
##
## The full M56 store API depends on SQLite (`repro_local_store/sqlite3_binding.nim`).
## The launcher MUST NOT pull SQLite in — its job is to be a tiny PE that
## depends only on Win32. So we implement just enough of the CAS read
## protocol to fetch one launch plan by its `launchPlanIdHex`:
##
##   * Compute `<store>/cas/blake3/<aa>/<full-hash>` from a hex digest.
##   * Read the bytes from disk.
##   * Verify the BLAKE3-256 hash before returning them (hash-on-read,
##     mandatory per spec).
##
## All of these are pure functions plus a `readFile` — the binary
## footprint stays at "kernel32 + CRT" exactly because of this.

import std/[os, strutils]

import blake3

import ./codec
import ./types

type
  SlimCasError* = object of CatchableError

proc decodeHex32(hex: string): array[32, byte] =
  if hex.len != 64:
    raise newException(SlimCasError,
      "expected 64-char hex digest, got " & $hex.len & " chars")
  for i in 0 ..< 32:
    let hi = parseHexInt($hex[i * 2])
    let lo = parseHexInt($hex[i * 2 + 1])
    result[i] = byte((hi shl 4) or lo)

proc casBlobPath*(storeRoot, idHex: string): string =
  ## Compose the on-disk path of a CAS blob keyed by `idHex`. Matches
  ## `repro_local_store.store.casBlobRelative` byte-for-byte so the two
  ## components stay interchangeable.
  storeRoot / "cas" / "blake3" / idHex[0 ..< 2] / idHex

proc readLaunchPlanByHex*(storeRoot, idHex: string): LaunchPlan =
  ## End-to-end: locate the blob on disk, verify its BLAKE3-256 digest
  ## against the supplied hex key, and decode the RBLP envelope.
  let expected = decodeHex32(idHex.toLowerAscii)
  let path = casBlobPath(storeRoot, idHex.toLowerAscii)
  if not fileExists(path):
    raise newException(SlimCasError,
      "launch plan CAS blob not found at " & path)
  let raw = readFile(path)
  var buf = newSeq[byte](raw.len)
  for i, ch in raw:
    buf[i] = byte(ord(ch))
  let actual = blake3.digest(buf)
  for i in 0 ..< 32:
    if actual[i] != expected[i]:
      raise newException(SlimCasError,
        "CAS digest mismatch for " & idHex)
  decodeLaunchPlan(buf)
