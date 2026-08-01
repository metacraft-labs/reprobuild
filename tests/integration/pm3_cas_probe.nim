## PM3 CAS-share probe (Production-Runners-And-Shared-Store PM3).
##
## A tiny two-mode helper used ONLY by the `t_incus_shared_store` gate to
## prove the SHARED reprobuild content-addressed store is a safe WRITABLE
## build-farm store: a guest ADDS a CAS entry that PERSISTS to the shared
## store, and a SECOND guest resolves it (BLAKE3 digest-verified on read, NO
## HTTP round-trip — pure local `repro_local_store`). Because the CAS is
## content-addressed, a read-write mount is safe: writes are self-verifying and
## cannot corrupt existing entries (a tampered blob hashes to a new digest).
##
##   seed  <cas-root> <text>   — store `text` as a CAS blob under <cas-root>
##                               (BLAKE3-256, framed CAS domain) and print the
##                               blob's `digest-hex sizeBytes` to stdout. Used
##                               to WRITE into the shared store (host seed, or
##                               guest-A add on the read-write mount).
##   read  <cas-root> <hex> <size>
##                             — open <cas-root>, read the blob at <hex>/<size>,
##                               verify its BLAKE3 digest on read, and print its
##                               bytes. Exits non-zero if the blob is missing or
##                               fails verification.
##
## The gate runs `seed` INSIDE a fresh ephemeral Incus container (guest A) to
## the read-write shared-store mount, then `read` INSIDE a second fresh guest
## (guest B) — proving guest-written artifacts persist to the shared store and
## resolve locally, instantly, digest-verified, for later guests.

import std/[os, strutils]

import repro_local_store
import repro_hash

proc digestFromHex(hex: string): ContentDigest =
  ## Rebuild a CAS ContentDigest from its lower-case hex (as printed by
  ## `digestHex` = `toHex(digest.bytes)`). The CAS domain/algorithm are
  ## fixed (BLAKE3-256, hdCasContent), matching `casDigest`'s output.
  result = ContentDigest(algorithm: haBlake3_256, domain: hdCasContent)
  doAssert hex.len == result.bytes.len * 2,
    "unexpected digest hex length: " & $hex.len
  for i in 0 ..< result.bytes.len:
    result.bytes[i] = byte(parseHexInt(hex[i * 2 .. i * 2 + 1]))

proc main() =
  let args = commandLineParams()
  if args.len < 2:
    stderr.writeLine("usage: pm3_cas_probe {seed <cas-root> <text> | " &
      "read <cas-root> <hex> <size>}")
    quit(2)
  let mode = args[0]
  let root = args[1]
  case mode
  of "seed":
    if args.len != 3:
      stderr.writeLine("seed: expected <cas-root> <text>"); quit(2)
    let cas = openLocalCas(root)
    let payload = cast[seq[byte]](args[2])
    let blob = cas.storeBlob(payload)
    echo digestHex(blob.digest) & " " & $blob.sizeBytes
  of "read":
    if args.len != 4:
      stderr.writeLine("read: expected <cas-root> <hex> <size>"); quit(2)
    # Open the store by root WITHOUT opening it for writes: the read path only
    # needs the CAS layout, and readBlob verifies the BLAKE3 digest on read
    # (the store's hash-on-read integrity contract) so a corrupted or wrong
    # blob is rejected regardless of who wrote it.
    var cas: LocalCas
    cas.root = root
    let digest = digestFromHex(args[2])
    let blob = blobRef(digest, parseBiggestUInt(args[3]))
    # readBlob verifies the BLAKE3 digest on read (hash-on-read contract).
    let bytes = cas.readBlob(blob)
    stdout.write(cast[string](bytes))
  else:
    stderr.writeLine("unknown mode: " & mode); quit(2)

main()
