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
##
## The ledger-index cases set the `actions/` directory's mtime with
## `setLastModificationTime` to model a coarse filesystem clock. That is not a
## mock: the stamp is the real directory's real mtime, read back by the
## production code through the same `stat` it always uses; only the moment the
## filesystem assigned it is chosen by the test instead of by the scheduler.

import std/[algorithm, os, strutils, tempfiles, times, unittest]

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

  test "the index is never stamped with a tick the clock has not passed":
    # reprobuild-pm issue 2026-10-16 ("the Nix ledger index trusts a stale
    # `actions/` stamp when two manifests land in one clock tick"). On Linux a
    # directory's mtime comes from the kernel's COARSE clock, so a manifest
    # written in the same tick as the stamp the index was built against
    # leaves that stamp byte-identical, and the index — still "valid" — says
    # the new manifest does not exist.
    #
    # The tick is modelled deterministically by giving `actions/` a stamp in
    # the FUTURE and restoring it after the second write. What makes a stamp
    # ambiguous is not its exact value but that the filesystem's clock has
    # not moved past it yet: until it does, a further write can be stamped
    # with the same value. Within a real tick that window is one jiffy; with
    # a stamp an hour ahead it is an hour, so the outcome no longer depends
    # on how the scheduler happens to interleave this process with the
    # clock. Restoring the stamp then produces exactly the state a coarse
    # clock produces: two different manifest sets, one byte-identical stamp.
    # Whole seconds are used because `utimes` (POSIX, microseconds) and
    # `SetFileTime` (Windows, 100 ns) both store them exactly; the first
    # `check` below confirms the round trip on this host.
    let dir = createTempDir("repro-ledger-tick-", "")
    defer: removeDir(dir)
    let store = dir / "store"
    let ledger = dir / "ledger"
    let actions = ledger / LedgerActionsDirName
    createDir(store)
    let refA = store / (H1 & "-a")
    writeFile(refA, "")
    let output = dir / "out"
    writeFile(output, "")
    writeNixRootsManifest(ledgerManifestPath(ledger, "k1"),
      NixRootsManifest(label: "one", outputs: @[output], refs: @[refA]))

    let unpassed = fromUnix(getTime().toUnix + 3600)
    setLastModificationTime(actions, unpassed)
    check getLastModificationTime(actions) == unpassed
    discard pruneStaleRoots(ledger, store)
    # The prune itself still happened (nothing to remove here), but the stamp
    # it would have recorded is one a later write can repeat, so no index.
    check not loadNixLedgerIndex(ledger).valid
    writeNixRootsManifest(ledgerManifestPath(ledger, "k2"),
      NixRootsManifest(label: "two", outputs: @[output], refs: @[refA]))
    setLastModificationTime(actions, unpassed)
    var stale = loadNixLedgerIndex(ledger)
    # The defect: a valid index that reports the new manifest as absent.
    check not stale.valid
    check not stale.valid or stale.missingStorePaths("k2").found
    check ledgerMissingStorePaths(ledger, "k2").found
    check nixLedgerNeedsMaintenance(ledger, stale)

    # The other side: a stamp the clock HAS passed is recorded, and then any
    # later write — necessarily stamped at or after "now" — moves it.
    let passed = fromUnix(getTime().toUnix - 3600)
    setLastModificationTime(actions, passed)
    check getLastModificationTime(actions) == passed
    discard pruneStaleRoots(ledger, store)
    var settled = loadNixLedgerIndex(ledger)
    check settled.valid
    check settled.valid and settled.missingStorePaths("k1").found
    check settled.valid and settled.missingStorePaths("k2").found
    check not nixLedgerNeedsMaintenance(ledger, settled)
    writeNixRootsManifest(ledgerManifestPath(ledger, "k3"),
      NixRootsManifest(label: "three", outputs: @[output], refs: @[refA]))
    check not loadNixLedgerIndex(ledger).valid
    check nixLedgerNeedsMaintenance(ledger, settled)

  test "a manifest written right after a prune always invalidates the index":
    # The same defect on the real clock: prune, then write a manifest at once,
    # with nothing in between. On Linux the old index was stamped within the
    # tick the next write landed in about half the time (5 of 10 isolated
    # runs of the test above it, issue 2026-10-16), so 32 rounds miss the
    # race with probability ~2^-32. On a fine-grained clock (APFS on macOS)
    # this passes either way; the deterministic case above is what pins the
    # fix there.
    let dir = createTempDir("repro-ledger-race-", "")
    defer: removeDir(dir)
    let store = dir / "store"
    let ledger = dir / "ledger"
    createDir(store)
    let refA = store / (H1 & "-a")
    writeFile(refA, "")
    let output = dir / "out"
    writeFile(output, "")
    var validAfterPrune = 0
    for round in 0 ..< 32:
      checkpoint("round " & $round)
      writeNixRootsManifest(ledgerManifestPath(ledger, "before-" & $round),
        NixRootsManifest(label: "before", outputs: @[output], refs: @[refA]))
      discard pruneStaleRoots(ledger, store)
      if loadNixLedgerIndex(ledger).valid:
        inc validAfterPrune
      let key = "after-" & $round
      writeNixRootsManifest(ledgerManifestPath(ledger, key),
        NixRootsManifest(label: "after", outputs: @[output], refs: @[refA]))
      var index = loadNixLedgerIndex(ledger)
      check not index.valid
      check not index.valid or index.missingStorePaths(key).found
    # Soundness alone is satisfied by never writing an index; the rounds only
    # test something if the prune does write one. It waits for the clock to
    # pass the stamp, so on any host with sub-second directory timestamps it
    # should have done so in every round.
    check validAfterPrune > 0

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

  test "a name overrun by an adjacent name character resolves to the existing entry":
    ## A store path serialized without a terminator is followed by whatever
    ## byte comes next. In a provider's `provider-compile.rbsz` the bytes
    ## after `…-source` were `9` and `=`, so the maximal name run named
    ## `…-source9` and `…-source=`, paths that exist nowhere. The ledger then
    ## recorded them as absent and judged a shared recipe-compile output to
    ## have LOST them. The reference is identified by its hash, so the
    ## longest existing prefix under that hash is the reference.
    let dir = createTempDir("repro-store-scan-", "")
    defer: removeDir(dir)
    let store = dir / "store"
    createDir(store / (H1 & "-source"))
    let real = store & "/" & H1 & "-source"
    writeFile(dir / "artifact.bin", "\x01" & real & "9\x00" & real & "=\x02")
    check scanStoreReferences([dir / "artifact.bin"], store) == @[real]
    # An existing maximal spelling wins over a shorter existing one.
    createDir(store / (H2 & "-lib"))
    createDir(store / (H2 & "-lib2"))
    let longer = store & "/" & H2 & "-lib2"
    writeFile(dir / "both.bin", "\x00" & longer & "\x00")
    check scanStoreReferences([dir / "both.bin"], store) == @[longer]
    # When no prefix exists the scanned spelling is kept: an output may name
    # a path that never existed here, and that is the caller's question.
    let absent = store & "/" & H3 & "-gone"
    writeFile(dir / "absent.bin", "\x00" & absent & "\x00")
    check scanStoreReferences([dir / "absent.bin"], store) == @[absent]
