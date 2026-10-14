## `scanStoreReferences` finds exactly the store paths an output's bytes name.
##
## MOCK POLICY — none. Every case writes real files, directories and symlinks
## into a real temporary directory and scans them with the production scanner.
## No Nix is needed: the scanner is pure byte matching, and the store paths
## below are syntactically valid names that need not exist (existence is the
## caller's question, not the scanner's — see the module doc).
##
## The chunk-boundary cases are the ones that matter most. The scanner reads
## 1 MiB at a time; a store path cut by a chunk boundary must be found whole,
## and must NOT be reported as the shorter prefix that happened to fit in the
## first chunk (`…-openssl-3` for `…-openssl-3.5.8`). Every offset around the
## boundary is tried, so a carry that is one byte short fails here.

import std/[algorithm, os, strutils, tempfiles, unittest]

import repro_core/nix_store_roots

const
  Chunk = 1 shl 20                                 ## the scanner's chunk size
  H1 = "m1kwp7bxnlri7nm9x9x8br0d4zlr95f9"          ## 32 valid base-32 chars
  H2 = "0k4r9hnfbnyngn5f3j31siddfs0iglwl"
  H3 = "ka85gyy8vxsjrjzpbldz5iz6a9zbnf7h"
  P1 = "/nix/store/" & H1 & "-openssl-3.5.8"
  P2 = "/nix/store/" & H2 & "-sqlite-3.53.3"
  P3 = "/nix/store/" & H3 & "-pcre-8.45"

proc scan(paths: varargs[string]): seq[string] =
  scanStoreReferences(paths, "/nix/store")

suite "scanStoreReferences":

  test "finds a path inside a longer path, between NULs, and dedupes":
    let dir = createTempDir("repro-store-scan-", "")
    defer: removeDir(dir)
    writeFile(dir / "a.bin", "\0\x7fELF\0" & P1 & "/lib/libssl.3.dylib\0" &
      "junk " & P1 & "/lib/libcrypto.3.dylib\0" & P2 & "\n")
    writeFile(dir / "b.txt", "rpath=" & P1 & "/lib:" & P3 & "/lib\n")
    check scan(dir / "a.bin") == @[P1, P2].sorted()
    check scan(dir / "a.bin", dir / "b.txt") == @[P1, P2, P3].sorted()
    # A directory is walked recursively.
    check scan(dir) == @[P1, P2, P3].sorted()

  test "rejects lookalikes: short hashes and letters outside base-32":
    let dir = createTempDir("repro-store-scan-", "")
    defer: removeDir(dir)
    var text = ""
    # 31 characters: one short.
    text.add("/nix/store/" & H1[0 .. 30] & "-short\n")
    # Each of e, o, t, u is outside Nix's base-32 alphabet.
    for bad in ['e', 'o', 't', 'u']:
      text.add("/nix/store/" & bad & H1[1 .. ^1] & "-bad\n")
    # Uppercase is not base-32 either.
    text.add("/nix/store/" & H1.toUpperAscii() & "-upper\n")
    # No dash after the hash, and an empty name.
    text.add("/nix/store/" & H1 & "_nodash\n")
    text.add("/nix/store/" & H1 & "-\n")
    # A different directory that merely contains the same letters.
    text.add("/nix/storex/" & H2 & "-elsewhere\n")
    # A name over Nix's 211-character limit is not a store path.
    text.add("/nix/store/" & H3 & "-" & repeat('a', 212) & "\n")
    writeFile(dir / "lookalikes.txt", text)
    check scan(dir / "lookalikes.txt").len == 0
    # ...while a name of exactly 211 characters is.
    let longest = "/nix/store/" & H3 & "-" & repeat('a', 211)
    writeFile(dir / "longest.txt", longest & "\n")
    check scan(dir / "longest.txt") == @[longest]

  test "a path cut by the chunk boundary is found whole at every offset":
    let dir = createTempDir("repro-store-scan-", "")
    defer: removeDir(dir)
    # From "the whole path fits before the boundary" through "only the first
    # byte of the prefix is before it" to "it starts just after it".
    let starts = @[Chunk - P1.len - 1, Chunk - P1.len, Chunk - P1.len + 1,
      Chunk - 20, Chunk - 12, Chunk - 11, Chunk - 10, Chunk - 2, Chunk - 1,
      Chunk, Chunk + 1]
    for start in starts:
      let path = dir / ("straddle-" & $start & ".bin")
      var bytes = newString(start)
      for i in 0 ..< bytes.len:
        bytes[i] = char(ord('A') + (i mod 7))   # no '/' so no false prefix
      bytes.add(P1 & "/lib/libssl.3.dylib\0")
      bytes.add(repeat('B', 100))
      writeFile(path, bytes)
      checkpoint("store path starts at byte " & $start)
      check scan(path) == @[P1]

  test "a long name cut by the boundary is not reported as its prefix":
    let dir = createTempDir("repro-store-scan-", "")
    defer: removeDir(dir)
    let long = "/nix/store/" & H2 & "-" & repeat("libname", 25)  # 175 chars
    for cut in [1, 10, 100, long.len - 1]:
      let start = Chunk - cut
      var bytes = repeat('A', start)
      bytes.add(long & "\0tail")
      let path = dir / ("cut-" & $cut & ".bin")
      writeFile(path, bytes)
      checkpoint("cut after " & $cut & " bytes")
      check scan(path) == @[long]

  test "a path in the final chunk with no terminator is found":
    let dir = createTempDir("repro-store-scan-", "")
    defer: removeDir(dir)
    writeFile(dir / "eof.txt", "x " & P2)
    check scan(dir / "eof.txt") == @[P2]
    var big = repeat('A', Chunk + 17)
    big.add(P3)
    writeFile(dir / "eof-big.txt", big)
    check scan(dir / "eof-big.txt") == @[P3]

  test "symlinks are not followed, but their targets are scanned":
    let dir = createTempDir("repro-store-scan-", "")
    defer: removeDir(dir)
    let outDir = dir / "out"
    let elsewhere = dir / "elsewhere"
    createDir(outDir)
    createDir(elsewhere)
    writeFile(elsewhere / "ref.txt", P3 & "\n")
    # A symlink INTO the store (dangling here: the path need not exist).
    createSymlink(P1 & "/bin/tool", outDir / "tool")
    # A symlink to a directory outside the output: its contents are not part
    # of the output and must not be scanned.
    createSymlink(elsewhere, outDir / "linked-dir")
    createSymlink(elsewhere / "ref.txt", outDir / "linked-file")
    check scan(outDir) == @[P1]
    # The output path itself may be the symlink.
    check scan(outDir / "tool") == @[P1]

  test "a missing output contributes nothing; other store dirs are honoured":
    let dir = createTempDir("repro-store-scan-", "")
    defer: removeDir(dir)
    check scan(dir / "does-not-exist").len == 0
    writeFile(dir / "custom.txt", "/opt/store/" & H1 & "-x " & P2 & "\n")
    check scanStoreReferences([dir / "custom.txt"], "/opt/store") ==
      @["/opt/store/" & H1 & "-x"]

suite "nix-gc-roots manifests":

  test "round trip, and missingStorePaths reports only recorded refs":
    let dir = createTempDir("repro-store-manifest-", "")
    defer: removeDir(dir)
    let present = dir / "present"
    writeFile(present, "")
    let m = NixRootsManifest(label: "act\tion\nid", outputs: @[dir / "o"],
      refs: @[present, dir / "gone"], absentAtRecord: @[dir / "never"])
    let path = dir / "m.refs"
    writeNixRootsManifest(path, m)
    let read = readNixRootsManifest(path)
    check read.found
    check read.manifest.label == "act ion id"
    check read.manifest.outputs == m.outputs
    check read.manifest.refs == m.refs
    check read.manifest.absentAtRecord == m.absentAtRecord
    # `absentAtRecord` is diagnostic: a path that was already missing when
    # the output was produced is never "lost".
    check missingStorePaths(path) == @[dir / "gone"]
    check missingStorePaths(dir / "no-such-manifest").len == 0
    # An unknown header is not misread as a manifest.
    writeFile(path, "# some other format\nref\t" & dir / "gone" & "\n")
    check not readNixRootsManifest(path).found

  test "a derivation is scanned but never rooted or tracked":
    # `nix-store --realise <x>.drv` BUILDS the derivation instead of rooting
    # it, so a mentioned `.drv` must not reach registration; see
    # `isRootableStorePath` for the measured cost of letting it.
    let drv = "/nix/store/" & H1 & "-bash-5.3.drv"
    let dir = createTempDir("repro-store-drv-", "")
    defer: removeDir(dir)
    writeFile(dir / "log.txt", "building '" & drv & "'... " & P2 & "\n")
    check scan(dir / "log.txt") == @[drv, P2].sorted()
    check not isRootableStorePath(drv, "/nix/store")
    check isRootableStorePath(P2, "/nix/store")
    check not isRootableStorePath("/nix/store", "/nix/store")
    check not isRootableStorePath("/elsewhere/" & H1 & "-x", "/nix/store")

  test "the ledger index answers like the manifests, and only while exact":
    # No Nix is involved: the "store" is a temporary directory and the pool
    # is empty, so `pruneStaleRoots` removes links at most and never
    # registers one. What is under test is the index's bookkeeping.
    let dir = createTempDir("repro-ledger-index-", "")
    defer: removeDir(dir)
    let store = dir / "store"
    let ledger = dir / "ledger"
    createDir(store)
    let refA = store / (H1 & "-a")
    let refB = store / (H2 & "-b")
    writeFile(refA, "")
    writeFile(refB, "")
    let out1 = dir / "out1"
    let out2 = dir / "out2"
    writeFile(out1, "")
    writeFile(out2, "")
    writeNixRootsManifest(ledgerManifestPath(ledger, "k1"),
      NixRootsManifest(label: "one", outputs: @[out1], refs: @[refA, refB]))
    writeNixRootsManifest(ledgerManifestPath(ledger, "k2"),
      NixRootsManifest(label: "two", outputs: @[out2], refs: @[refB]))

    # No index yet: callers must read manifests.
    check not loadNixLedgerIndex(ledger).valid
    discard pruneStaleRoots(ledger, store)
    var index = loadNixLedgerIndex(ledger)
    check index.valid
    check index.missingStorePaths("k1") == (found: true, missing: newSeq[string]())
    check index.missingStorePaths("k2") == (found: true, missing: newSeq[string]())
    # With an exact index, an absent key HAS no manifest.
    check not index.missingStorePaths("k3").found
    check not ledgerMissingStorePaths(ledger, "k3").found
    check not nixLedgerNeedsMaintenance(ledger, index)
    # Re-recording an action into the SAME references rewrites nothing, so
    # the index stays exact and no prune is owed.
    writeNixRootsManifest(ledgerManifestPath(ledger, "k1"),
      NixRootsManifest(label: "one", outputs: @[out1], refs: @[refA, refB]))
    check loadNixLedgerIndex(ledger).valid
    check not nixLedgerNeedsMaintenance(ledger, index)

    # A collected store path is reported by the index exactly as by the
    # manifest it summarises.
    removeFile(refB)
    var fresh = loadNixLedgerIndex(ledger)
    check fresh.valid
    check fresh.missingStorePaths("k1").missing == @[refB]
    check fresh.missingStorePaths("k2").missing == @[refB]
    check ledgerMissingStorePaths(ledger, "k1").missing == @[refB]

    # A manifest written after the index makes it untrustworthy.
    writeNixRootsManifest(ledgerManifestPath(ledger, "k3"),
      NixRootsManifest(label: "three", outputs: @[out1], refs: @[refA]))
    check not loadNixLedgerIndex(ledger).valid
    check nixLedgerNeedsMaintenance(ledger, index)

    # A prune that removes a manifest (its output is gone) does not write an
    # index it cannot vouch for; the next prune, which removes nothing, does.
    removeFile(out2)
    let pruned = pruneStaleRoots(ledger, store)
    check pruned.manifestsRemoved == 1
    check not fileExists(ledgerManifestPath(ledger, "k2"))
    check not loadNixLedgerIndex(ledger).valid
    discard pruneStaleRoots(ledger, store)
    var rebuilt = loadNixLedgerIndex(ledger)
    check rebuilt.valid
    check rebuilt.missingStorePaths("k3").found
    check not rebuilt.missingStorePaths("k2").found

  test "ledger keys are filesystem-safe and distinguish scope":
    let a = ledgerKey("pkg/compile:a.c", "/work")
    let b = ledgerKey("pkg/compile:a.c", "/other")
    check a != b
    check a == ledgerKey("pkg/compile:a.c", "/work")
    for c in a:
      check c in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '.', '_', '-'}

  test "an absent reference is lost only when the output was already there":
    # No Nix is involved: every referenced path is absent, so nothing is
    # handed to `nix-store`. What is under test is which list the manifest
    # puts an absent path in, which decides whether detection reports it.
    let dir = createTempDir("repro-ledger-absent-", "")
    defer: removeDir(dir)
    let store = dir / "store"
    let ledger = dir / "ledger"
    createDir(store)
    let gone = store / (H3 & "-libgone")
    let output = dir / "app.bin"
    writeFile(output, "\0" & gone & "/lib/libgone.dylib\0")
    # Just produced: the producer named a path this host lacks. Re-executing
    # cannot change that, so it is not reported lost (or it would loop).
    let produced = recordOutputRoots(ledger, "fresh", "fresh", [output],
      storeDir = store)
    check produced.absent == @[gone]
    check ledgerMissingStorePaths(ledger, "fresh") ==
      (found: true, missing: newSeq[string]())
    # Already in the working tree with no manifest: produced while the path
    # existed, collected since. Reported lost until a re-execution replaces
    # the manifest.
    discard recordOutputRoots(ledger, "inherited", "inherited", [output],
      storeDir = store, absentIsLost = true)
    check ledgerMissingStorePaths(ledger, "inherited") ==
      (found: true, missing: @[gone])
    discard recordOutputRoots(ledger, "inherited", "inherited", [output],
      storeDir = store)
    check ledgerMissingStorePaths(ledger, "inherited").missing.len == 0
