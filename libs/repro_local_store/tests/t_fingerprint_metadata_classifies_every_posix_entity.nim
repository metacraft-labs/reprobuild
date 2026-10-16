## What `fingerprintMetadata` records for every kind of thing a POSIX path
## can be -- and which of those answers CHANGED when the single-`lstat` fast
## path was widened from Linux to all of POSIX.
##
## MOCK POLICY -- NO MOCK OF THE SYSTEM UNDER TEST IS USED, AND NONE MAY BE
## ADDED. Every case is a real entity in a real temporary directory, observed
## through the real production `observeFile` / `recordActionResult` /
## `hotMetadataRecordInputsUnchanged`. The one piece of non-production code
## here is `retiredGenericBranch`, a faithful transcription of the stdlib
## `fileExists` + `dirExists` + `getFileInfo` branch that macOS used to take.
## It is NOT a stand-in for anything the test exercises -- production is
## always called directly -- it is a DIFFERENTIAL ORACLE. The change swapped
## one classifier for another, the two disagree on exactly two of the seven
## cases below, and a test that only asserted the new answers would leave the
## disagreement as prose in a commit message. Keeping the retired algorithm
## executable is what makes "these two cases changed, these five did not" a
## checked claim.
##
## WHY THE BRANCH WAS WIDENED. macOS took the generic branch, which asks the
## kernel the same question three times. On a warm no-op of the zlib CMake
## project, 4,359 calls cost 37.3 ms, of which the two existence probes were
## 36.4 ms and the `getFileInfo` that actually produces the answer was 0.67 ms.
## 3,928 of the 4,363 recorded inputs do not exist -- linker and CMake
## library-search probes -- so the common case paid two FAILED `stat`s before
## concluding nothing, and a negative path lookup costs about twice a positive
## one.
##
## THE THREE DELIBERATE DIVERGENCES, all asserted below:
##
##   dangling symlink   retired: ffkMissing(0, 0)   now: ffkUnresolvedSymlink
##                      (link's own size and mtime)
##   FIFO / socket      retired: ffkMissing(0, 0)   now: ffkOther, and
##                      therefore not a recorded input at all
##   link to directory  retired: ffkDirectory(0, 0) now: ffkDirectory with
##                      `sizeBytes` = a digest of the link's target text
##                      (`linkedDirectoryIdentity`); the retired answer was
##                      the one a real directory gives, so a directory
##                      replaced by a link, or a directory link retargeted,
##                      compared equal
##
## All three follow the branch that was kept, and are argued in the code
## comment beside it. The consequences run in the last two suites: what the
## new classification BUYS (a dangling link retargeted to another absent
## target now invalidates) and what it USED TO COST: while a dangling link was
## classified `ffkRegular`, its target appearing did not invalidate. That cost
## was pinned by a test on purpose, as a known hole with a stated way to close
## it; the dangling link now has a kind of its own (`ffkUnresolvedSymlink`),
## the hole is closed, and the same test now asserts the invalidation.

import std/[os, posix, sets, tempfiles, times, unittest]

import repro_hash
import repro_local_store
import repro_test_support/reasoned_skip

when defined(posix):
  # Not in std/posix. Restores a symlink's own timestamps without following
  # it, which is what a retarget that hides itself from `lstat` does.
  var
    AtFdcwd {.importc: "AT_FDCWD", header: "<fcntl.h>".}: cint
    AtSymlinkNofollow {.importc: "AT_SYMLINK_NOFOLLOW",
      header: "<fcntl.h>".}: cint
  proc utimensat(dirfd: cint; path: cstring; times: ptr array[2, Timespec];
                 flags: cint): cint {.importc, header: "<sys/stat.h>".}

proc weakFor(text: string): ContentDigest =
  var payload = newSeq[byte](text.len)
  for i, ch in text:
    payload[i] = byte(ord(ch))
  blake3DomainDigest(payload, hdActionFingerprint)

proc kindOf(path: string): FingerprintedFileKind =
  observeFile(path, ffpTimestamp).metadata.kind

proc metadataOf(path: string): FileMetadata =
  observeFile(path, ffpTimestamp).metadata

# The retired generic branch, transcribed. See the MOCK POLICY note: this is
# a differential oracle, never a substitute for production.
proc retiredGenericBranch(path: string): FileMetadata =
  if not fileExists(path) and not dirExists(path):
    return FileMetadata(kind: ffkMissing)
  let info = getFileInfo(path, followSymlink = false)
  result.kind =
    case info.kind
    of pcFile, pcLinkToFile: ffkRegular
    of pcDir, pcLinkToDir: ffkDirectory
  result.sizeBytes = uint64(max(info.size, 0))
  let mtime = info.lastWriteTime
  result.mtimeNs = uint64(mtime.toUnix) * 1_000_000_000'u64 +
    uint64(mtime.nanosecond)
  if result.kind == ffkDirectory:
    result.sizeBytes = 0
    result.mtimeNs = 0

type Tree = object
  root: string

proc makeTree(): Tree =
  result.root = createTempDir("repro-fpmeta-", "")
  let r = result.root
  createDir(r / "dir")
  writeFile(r / "dir" / "inside.txt", "nested\n")
  writeFile(r / "file.txt", "hello\n")
  createSymlink(r / "file.txt", r / "link-to-file")
  createSymlink(r / "dir", r / "link-to-dir")
  createSymlink(r / "never-created.txt", r / "dangling")
  doAssert mkfifo((r / "fifo").cstring, 0o644.Mode) == 0,
    "could not create a FIFO; the special-file case cannot be tested"

proc recordFor(path: string): ActionResultRecord =
  ## A record carrying exactly one input, observed now.
  ActionResultRecord(
    weakFingerprint: weakFor("fpmeta." & path),
    policy: ffpTimestamp,
    inputs: @[observeFile(path, ffpTimestamp)])

suite "fingerprintMetadata classifies every POSIX entity":

  test "regular file, directory, symlinks, dangling link, FIFO, absent path":
    when not defined(posix):
      skip()
    else:
      let t = makeTree()
      defer: removeDir(t.root)

      # -- the five cases both classifiers agree on --------------------------
      check kindOf(t.root / "file.txt") == ffkRegular
      check metadataOf(t.root / "file.txt").sizeBytes == 6'u64
      check metadataOf(t.root / "file.txt").mtimeNs > 0'u64

      check kindOf(t.root / "dir") == ffkDirectory
      # A directory's size and mtime are deliberately zeroed: existence is the
      # dependency, membership is a separate fingerprint.
      check metadataOf(t.root / "dir").sizeBytes == 0'u64
      check metadataOf(t.root / "dir").mtimeNs == 0'u64

      # A symlink to a file is a regular file carrying the LINK's own size and
      # mtime -- Incremental-Invalidation.md §"Symlink outputs". The link's own
      # size is the length of the target string, which is not 6.
      check kindOf(t.root / "link-to-file") == ffkRegular
      check metadataOf(t.root / "link-to-file").sizeBytes ==
        uint64((t.root / "file.txt").len)
      check metadataOf(t.root / "link-to-file").sizeBytes != 6'u64
      check metadataOf(t.root / "link-to-file") !=
        metadataOf(t.root / "file.txt")

      # A link to a directory classifies as a directory, but is not recorded
      # as one: its `sizeBytes` carries the link's identity, a real
      # directory's is 0. `mtimeNs` stays 0, the "not membership-tracked"
      # value (`membershipTrackedDirectory`).
      check kindOf(t.root / "link-to-dir") == ffkDirectory
      check metadataOf(t.root / "link-to-dir").sizeBytes != 0'u64
      check metadataOf(t.root / "link-to-dir").mtimeNs == 0'u64
      check metadataOf(t.root / "link-to-dir") != metadataOf(t.root / "dir")

      check kindOf(t.root / "absent-entirely") == ffkMissing
      check metadataOf(t.root / "absent-entirely") ==
        FileMetadata(kind: ffkMissing)

      # -- divergence 1: a dangling symlink ---------------------------------
      # It IS an entity, `lstat` describes it, and its own size and mtime are
      # real facts. The retired branch called it absent. It is not a regular
      # file either: it has no content, and calling it one is what made its
      # target appearing invisible (see the last suite).
      check kindOf(t.root / "dangling") == ffkUnresolvedSymlink
      check metadataOf(t.root / "dangling").sizeBytes ==
        uint64((t.root / "never-created.txt").len)
      check metadataOf(t.root / "dangling").mtimeNs > 0'u64

      # -- divergence 2: a FIFO ---------------------------------------------
      # Not a file, not a directory, and it has no meaningful size or mtime.
      check kindOf(t.root / "fifo") == ffkOther

  test "the retired classifier agreed on four cases and disagreed on three":
    when not defined(posix):
      skip("symbolic links, lstat(2) and utimensat(2) are POSIX; " &
        "this case observes the POSIX fingerprint branch")
    else:
      let t = makeTree()
      defer: removeDir(t.root)

      # AGREEMENT. If widening the branch had changed any of these, the change
      # would not be the narrow one it claims to be.
      for name in ["file.txt", "dir", "link-to-file", "absent-entirely"]:
        let path = t.root / name
        checkpoint("agree on " & name)
        check metadataOf(path) == retiredGenericBranch(path)

      # DISAGREEMENT, both directions stated explicitly.
      let dangling = t.root / "dangling"
      check retiredGenericBranch(dangling) == FileMetadata(kind: ffkMissing)
      check metadataOf(dangling).kind == ffkUnresolvedSymlink
      check metadataOf(dangling) != retiredGenericBranch(dangling)

      let fifo = t.root / "fifo"
      check retiredGenericBranch(fifo) == FileMetadata(kind: ffkMissing)
      check metadataOf(fifo).kind == ffkOther
      check metadataOf(fifo) != retiredGenericBranch(fifo)

      let linkToDir = t.root / "link-to-dir"
      check retiredGenericBranch(linkToDir) ==
        FileMetadata(kind: ffkDirectory)
      check retiredGenericBranch(linkToDir) ==
        retiredGenericBranch(t.root / "dir")
      check metadataOf(linkToDir).kind == ffkDirectory
      check metadataOf(linkToDir) != retiredGenericBranch(linkToDir)

  test "a FIFO input is not recorded; a dangling symlink input is":
    when not defined(posix):
      skip()
    else:
      let t = makeTree()
      defer: removeDir(t.root)

      let cacheRoot = t.root / "cache"
      let casRoot = t.root / "cas"
      var cache = openActionCache(cacheRoot, attachShm = false)
      let cas = openLocalCas(casRoot)

      let record = recordActionResult(cache, cas,
        weak = weakFor("fpmeta.recordability"),
        policy = ffpTimestamp,
        inputPaths = [t.root / "file.txt", t.root / "dangling",
                      t.root / "fifo", t.root / "absent-entirely"],
        outputPaths = [],
        outputRoot = t.root,
        storeOutputBlobs = false)

      var recorded = initHashSet[string]()
      for input in record.inputs:
        recorded.incl(input.path)

      # `ffkOther` is dropped: recording a FIFO as a comparable input would
      # state a size and an mtime that mean nothing.
      check (t.root / "fifo") notin recorded
      # Everything else is recorded, INCLUDING the absent path (an absent-path
      # probe is a real dependency) and the dangling link.
      check (t.root / "file.txt") in recorded
      check (t.root / "dangling") in recorded
      check (t.root / "absent-entirely") in recorded
      check record.inputs.len == 3

suite "what the dangling-symlink classification buys and costs":

  test "BUYS: retargeting a dangling link to another absent target invalidates":
    when not defined(posix):
      skip()
    else:
      let t = makeTree()
      defer: removeDir(t.root)
      let link = t.root / "dangling"

      let record = recordFor(link)
      check hotMetadataRecordInputsUnchanged([record])

      # Same link, still dangling, different target. Under the retired
      # classifier both states were ffkMissing(0, 0) and this compared EQUAL --
      # the link's own size and mtime were the only evidence there was, and it
      # threw both away.
      removeFile(link)
      createSymlink(t.root / "a-different-target-that-also-does-not-exist",
        link)
      check not hotMetadataRecordInputsUnchanged([record])

  test "a dangling link whose target appears invalidates":
    when not defined(posix):
      skip("symlinks and lstat(2) are POSIX; this case observes a POSIX " &
        "dangling link")
    else:
      let t = makeTree()
      defer: removeDir(t.root)
      let link = t.root / "dangling"

      let record = recordFor(link)
      check hotMetadataRecordInputsUnchanged([record])

      # The target appears. `lstat` of the LINK is byte-identical before and
      # after -- same size, same mtime -- so while the dangling link was
      # classified `ffkRegular` this transition was invisible, and this test
      # asserted the hole on purpose ("COSTS: ... does NOT invalidate"),
      # naming the change that would close it. That change is the
      # `ffkUnresolvedSymlink` kind: the link's kind moves from unresolved to
      # regular, so the record no longer describes the filesystem.
      writeFile(t.root / "never-created.txt", "appeared\n")
      check fileExists(t.root / "never-created.txt")
      check metadataOf(link).kind == ffkRegular
      check not hotMetadataRecordInputsUnchanged([record])

  test "a symlink to a file tracks the LINK, not the file it points at":
    when not defined(posix):
      skip()
    else:
      let t = makeTree()
      defer: removeDir(t.root)
      let link = t.root / "link-to-file"

      let record = recordFor(link)
      check hotMetadataRecordInputsUnchanged([record])

      # Rewriting the TARGET with different content does not touch the link's
      # own inode. The link is not the dependency the content is carried by --
      # an action that read through it recorded the target path too. This is
      # asserted so the "link's own size and mtime" rule is not silently
      # traded for a follow-the-link one.
      writeFile(t.root / "file.txt",
        "a substantially longer body than before\n")
      check metadataOf(t.root / "file.txt").sizeBytes > 6'u64
      check hotMetadataRecordInputsUnchanged([record])

      # Retargeting the link itself, however, is visible.
      writeFile(t.root / "other.txt", "other\n")
      removeFile(link)
      createSymlink(t.root / "other.txt", link)
      check not hotMetadataRecordInputsUnchanged([record])

suite "a link to a directory is not the directory":
  # A path resolution (`realpath`, `readlink`, any open through the path)
  # depends on whether each directory on the way is a directory or a link,
  # and on where each link points. The monitor records every component it
  # walks through as a probe; these cases pin that such a probe's recorded
  # state actually moves when that fact does.

  test "a directory replaced by a link to an identical directory invalidates":
    when not defined(posix):
      skip("symbolic links, lstat(2) and utimensat(2) are POSIX; " &
        "this case observes the POSIX fingerprint branch")
    else:
      let t = makeTree()
      defer: removeDir(t.root)
      let component = t.root / "dir"

      let record = recordFor(component)
      check hotMetadataRecordInputsUnchanged([record])

      # Same names behind the path, so every file reached through it still
      # exists with the same content; `realpath(component / "inside.txt")`
      # now answers `elsewhere/inside.txt`.
      createDir(t.root / "elsewhere")
      writeFile(t.root / "elsewhere" / "inside.txt", "nested\n")
      removeDir(component)
      createSymlink(t.root / "elsewhere", component)
      check kindOf(component) == ffkDirectory
      check not hotMetadataRecordInputsUnchanged([record])

  test "a directory link retargeted with its own mtime restored invalidates":
    when not defined(posix):
      skip("symbolic links, lstat(2) and utimensat(2) are POSIX; " &
        "this case observes the POSIX fingerprint branch")
    else:
      let t = makeTree()
      defer: removeDir(t.root)
      let link = t.root / "link-to-dir"
      # The new target text has the SAME LENGTH as the old one, and the
      # link's own mtime is restored: nothing `lstat` reports moves.
      let other = t.root / "dis"
      check other.len == (t.root / "dir").len
      createDir(other)
      writeFile(other / "inside.txt", "nested\n")

      var before: Stat
      doAssert lstat(link.cstring, before) == 0
      let record = recordFor(link)
      check hotMetadataRecordInputsUnchanged([record])

      removeFile(link)
      createSymlink(other, link)
      var times = [before.st_atim, before.st_mtim]
      doAssert utimensat(AtFdcwd, link.cstring, addr times,
        AtSymlinkNofollow) == 0
      var after: Stat
      doAssert lstat(link.cstring, after) == 0
      check after.st_size == before.st_size
      check after.st_mtim.tv_sec == before.st_mtim.tv_sec
      check after.st_mtim.tv_nsec == before.st_mtim.tv_nsec
      check not hotMetadataRecordInputsUnchanged([record])

  test "an unchanged directory link stays a hit":
    when not defined(posix):
      skip("symbolic links, lstat(2) and utimensat(2) are POSIX; " &
        "this case observes the POSIX fingerprint branch")
    else:
      let t = makeTree()
      defer: removeDir(t.root)
      let link = t.root / "link-to-dir"
      let record = recordFor(link)
      # Its target's contents moving is not the link moving; membership of an
      # enumerated directory is a separate fingerprint.
      writeFile(t.root / "dir" / "added.txt", "added\n")
      check hotMetadataRecordInputsUnchanged([record])
      check metadataOf(link) == record.inputs[0].metadata

suite "a content-keyed policy sees a file link retargeted":

  when defined(posix):
    proc retargetToIdenticalContent(policy: FileFingerprintPolicy):
        ActionCacheLookupStatus =
      let t = makeTree()
      defer: removeDir(t.root)
      let link = t.root / "link-to-file"
      # Same content, different file: an action that opened through the link
      # read the same bytes, one that READ the link got a different answer.
      writeFile(t.root / "twin.txt", readFile(t.root / "file.txt"))
      var cache = openActionCache(t.root / "cache", attachShm = false)
      defer: cache.closeShmTier()
      let cas = openLocalCas(t.root / "cas")
      let weak = weakFor("fpmeta.link-retarget." & $policy)
      discard cache.recordActionResult(cas, weak, policy, [link], [])
      doAssert cache.lookupActionResult(cas, weak, policy).status == aclHit
      var before: Stat
      doAssert lstat(link.cstring, before) == 0
      removeFile(link)
      # The same target length ("twin.txt" / "file.txt"), so the link's own
      # size does not move.
      createSymlink(t.root / "twin.txt", link)
      # A retarget that happens later than the record moves the link's own
      # mtime; one that happens in the same timestamp tick does not. Linux
      # stamps from a coarse clock, so the two links here, created
      # milliseconds apart, can carry the SAME mtime -- a hit under
      # `ffpTimestamp`, and a metadata match under `ffpHybrid` that never
      # reaches the hash this suite is about. Set the new link's mtime one
      # second later explicitly, so every policy sees what a real retarget
      # shows it: only the mtime moved, and only a content-keyed policy has
      # to look further.
      var times = [before.st_atim, before.st_mtim]
      times[1].tv_sec = posix.Time(int(before.st_mtim.tv_sec) + 1)
      doAssert utimensat(AtFdcwd, link.cstring, addr times,
        AtSymlinkNofollow) == 0
      cache.lookupActionResult(cas, weak, policy).status

  test "ffpChecksum":
    when not defined(posix):
      skip("symbolic links, lstat(2) and utimensat(2) are POSIX; " &
        "this case observes the POSIX fingerprint branch")
    else:
      check retargetToIdenticalContent(ffpChecksum) == aclMissInputChanged

  test "ffpHybrid":
    when not defined(posix):
      skip("symbolic links, lstat(2) and utimensat(2) are POSIX; " &
        "this case observes the POSIX fingerprint branch")
    else:
      check retargetToIdenticalContent(ffpHybrid) == aclMissInputChanged

  test "ffpTimestamp":
    when not defined(posix):
      skip("symbolic links, lstat(2) and utimensat(2) are POSIX; " &
        "this case observes the POSIX fingerprint branch")
    else:
      check retargetToIdenticalContent(ffpTimestamp) == aclMissInputChanged
