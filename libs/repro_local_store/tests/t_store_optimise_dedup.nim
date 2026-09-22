## Store-optimise dedup — planning core and a real filesystem roundtrip.
##
## Covers the M8 dedup mechanism `optimise.nim` adds: identical files anywhere
## under a store collapse onto one inode, distinct files are never touched, and
## re-running the pass is a no-op.

import std/[os, strutils, unittest, tempfiles]

import repro_local_store/optimise

suite "store optimise — hardlink dedup":

  test "planDedup links only byte-identical files, keeping a stable canonical":
    let dir = createTempDir("repro-optimise-plan-", "")
    defer: removeDir(dir)
    # Three identical, one distinct-but-same-size, one unique-size.
    writeFile(dir / "b_copy.bin", "AAAABBBBCCCC")
    writeFile(dir / "a_copy.bin", "AAAABBBBCCCC")
    writeFile(dir / "c_copy.bin", "AAAABBBBCCCC")
    writeFile(dir / "same_size.bin", "ZZZZYYYYXXXX")  # 12 bytes, different content
    writeFile(dir / "unique.bin", "short")

    let plan = planDedup(collectCandidates(dir))
    # Exactly two links for the three identical files; the same-size-but-
    # different file and the unique file produce none.
    check plan.len == 2
    for link in plan:
      # Canonical is the lexicographically-first of the identical group.
      check link.canonical == dir / "a_copy.bin"
      check link.duplicate != link.canonical
    var dups: seq[string]
    for link in plan: dups.add(link.duplicate)
    check (dir / "b_copy.bin") in dups
    check (dir / "c_copy.bin") in dups

  test "optimiseStore collapses inodes, preserves content, and is idempotent":
    when not defined(windows) or true:
      let root = createTempDir("repro-optimise-apply-", "")
      defer: removeDir(root)
      # Two prefixes each holding an identical 256 KiB blob — the shape the
      # parallel rust-tool realize race produces.
      let payload = repeat('R', 256 * 1024)
      createDir(root / "prefix-a" / "bin")
      createDir(root / "prefix-b" / "bin")
      writeFile(root / "prefix-a" / "bin" / "rustc", payload)
      writeFile(root / "prefix-b" / "bin" / "rustc", payload)

      let res = optimiseStore(root)
      check res.linked == 1
      check res.reclaimed == payload.len

      # Content is intact through both names.
      check readFile(root / "prefix-a" / "bin" / "rustc") == payload
      check readFile(root / "prefix-b" / "bin" / "rustc") == payload

      # And they now share an inode (POSIX; on NTFS getFileInfo.id is a
      # file-index that also matches for hardlinks).
      let ia = getFileInfo(root / "prefix-a" / "bin" / "rustc", followSymlink = false)
      let ib = getFileInfo(root / "prefix-b" / "bin" / "rustc", followSymlink = false)
      check ia.id == ib.id

      # Re-running finds nothing left to do.
      let again = optimiseStore(root)
      check again.linked == 0
      check again.reclaimed == 0
