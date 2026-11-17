## Two distinct realization ids never share one prefix directory.
##
## Issue: reprobuild-pm
## issues/2026-11-12-the-realization-hash-envelope-omits-the-recipe-itself-runtimedeps-and-environment-values.md
## (R05-16, "the truncation length is never stated"; the proposed fix states
## it once, at 160 bits or more).
##
## The prefix id (``PrefixIdBytes``) is a full BLAKE3-256 digest, but the
## directory a prefix is published at is named from a TRUNCATION of it
## (``prefix_paths.realizationDirName``). Two ids that agree on the truncated
## bits name one directory. At a 64-bit truncation a birthday collision costs
## about 2^32 realization-hash evaluations, which is within reach of anyone
## who chooses realization inputs (a published recipe, a binary-cache or
## federation import).
##
## WHY THE COLLIDING ID IS CONSTRUCTED rather than found: finding a real
## 64-bit BLAKE3 prefix collision costs ~2^32 hashes, far too slow for a unit
## test. ``realizePrefix`` takes the id as an input and treats it as opaque,
## so supplying a second id that equals the first in its leading 8 bytes and
## differs later exercises exactly the code path a real collision reaches.
## The first case collides at the old 64-bit boundary and requires the store
## to keep both realizations apart end to end; the second pins the stated
## width (160 bits = 40 lowercase hex) by naming two ids that agree in 152.
##
## MOCK POLICY: none. A real ``Store`` on a real temporary directory,
## through ``openStore`` / ``realizePrefix`` / ``recover``.

import std/[os, tempfiles, unittest]

from repro_core/paths import extendedPath

import repro_local_store

proc hintFor(): StoreReceiptHint =
  ## One package at one version: only the id tells the two apart, as with
  ## two recipes whose inputs differ but whose ids collide when truncated.
  StoreReceiptHint(adapter: "collision-test", packageName: "pkg",
    version: "1.0", lockIdentity: "collision-test")

proc writer(content: string): proc (stagingDir: string;
                                     mechanism: var string) =
  result = proc (stagingDir: string; mechanism: var string) =
    writeFile(stagingDir / "payload", content)
    mechanism = "copy"

proc idWithSharedLeadingBytes(base: PrefixIdBytes;
                              shared: int): PrefixIdBytes =
  ## An id equal to ``base`` in its first ``shared`` bytes and different in
  ## every byte after them.
  result = base
  for i in shared ..< result.len:
    result[i] = base[i] xor 0xA5'u8

suite "distinct realization ids never share a prefix directory":

  test "ids agreeing in their first 64 bits are realized apart":
    let root = createTempDir("repro-prefix-collision-", "")
    defer:
      try: removeDir(extendedPath(root)) except OSError: discard
    var store = openStore(root / "store")
    defer: store.close()
    let x = computeRealizationHash("pkg", "1.0", "collision-test",
      "collision-test", "", extra = ["a"])
    let y = idWithSharedLeadingBytes(x, 8)
    check x != y

    let a = store.realizePrefix(x, hintFor(), writer("bytes of A"))
    let b = store.realizePrefix(y, hintFor(), writer("bytes of B"))
    checkpoint "A at " & a.absolutePath & " (" & $a.outcome & ")"
    checkpoint "B at " & b.absolutePath & " (" & $b.outcome & ")"
    check a.absolutePath != b.absolutePath
    check a.relativePath != b.relativePath
    check readFile(a.absolutePath / "payload") == "bytes of A"
    check readFile(b.absolutePath / "payload") == "bytes of B"
    check readReceiptFile(a.absolutePath / ReceiptFileName).realizationHash == x
    check readReceiptFile(b.absolutePath / ReceiptFileName).realizationHash == y

    # Each id's index row names its own directory.
    check store.lookupPrefix(x).row.realizedPath == a.relativePath
    check store.lookupPrefix(y).row.realizedPath == b.relativePath

    # A later use of A, in a fresh process, finds A where it was published,
    # untouched: B's publish did not displace it.
    forgetVerifiedPrefixes()
    let again = store.realizePrefix(x, hintFor(), writer("bytes of A"))
    checkpoint "A again at " & again.absolutePath & " (" & $again.outcome &
      ", replacedUntrusted=" & $again.replacedUntrusted & ")"
    check again.outcome == roAlreadyPresent
    check not again.replacedUntrusted
    check again.absolutePath == a.absolutePath
    check readFile(b.absolutePath / "payload") == "bytes of B"

    # Recovery keeps both: neither directory is quarantined.
    let report = store.recover()
    check report.quarantinedPrefixes.len == 0
    check readFile(a.absolutePath / "payload") == "bytes of A"
    check readFile(b.absolutePath / "payload") == "bytes of B"

  test "the directory name carries at least 160 bits of the id":
    let x = computeRealizationHash("pkg", "1.0", "collision-test",
      "collision-test", "", extra = ["width"])
    # Agreeing in the first 19 bytes (152 bits) still names apart; the
    # stated width is 20 bytes = 40 lowercase hex characters.
    let y = idWithSharedLeadingBytes(x, 19)
    check realizationDirName("1.0", x) != realizationDirName("1.0", y)
    check realizationDirName("1.0", x) == "1.0-" & prefixIdHex(x)[0 ..< 40]
