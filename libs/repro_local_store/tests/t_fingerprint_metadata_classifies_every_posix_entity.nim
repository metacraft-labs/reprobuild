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
## THE TWO DELIBERATE DIVERGENCES, both asserted below:
##
##   dangling symlink   retired: ffkMissing(0, 0)   now: ffkRegular(link's
##                      own size and mtime)
##   FIFO / socket      retired: ffkMissing(0, 0)   now: ffkOther, and
##                      therefore not a recorded input at all
##
## Both follow the branch that was kept, and both are argued in the code
## comment beside it. The consequences run in the last two suites: what the
## new classification BUYS (a dangling link retargeted to another absent
## target now invalidates) and what it COSTS (a dangling link whose target
## appears no longer does). The cost is pinned by a test on purpose, so it is
## a known hole rather than a surprise.

import std/[os, posix, sets, tempfiles, times, unittest]

import repro_hash
import repro_local_store

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

      check kindOf(t.root / "link-to-dir") == ffkDirectory

      check kindOf(t.root / "absent-entirely") == ffkMissing
      check metadataOf(t.root / "absent-entirely") ==
        FileMetadata(kind: ffkMissing)

      # -- divergence 1: a dangling symlink ---------------------------------
      # It IS an entity, `lstat` describes it, and its own size and mtime are
      # real facts. The retired branch called it absent.
      check kindOf(t.root / "dangling") == ffkRegular
      check metadataOf(t.root / "dangling").sizeBytes ==
        uint64((t.root / "never-created.txt").len)
      check metadataOf(t.root / "dangling").mtimeNs > 0'u64

      # -- divergence 2: a FIFO ---------------------------------------------
      # Not a file, not a directory, and it has no meaningful size or mtime.
      check kindOf(t.root / "fifo") == ffkOther

  test "the retired classifier agreed on five cases and disagreed on two":
    when not defined(posix):
      skip()
    else:
      let t = makeTree()
      defer: removeDir(t.root)

      # AGREEMENT. If widening the branch had changed any of these, the change
      # would not be the narrow one it claims to be.
      for name in ["file.txt", "dir", "link-to-file", "link-to-dir",
                   "absent-entirely"]:
        let path = t.root / name
        checkpoint("agree on " & name)
        check metadataOf(path) == retiredGenericBranch(path)

      # DISAGREEMENT, both directions stated explicitly.
      let dangling = t.root / "dangling"
      check retiredGenericBranch(dangling) == FileMetadata(kind: ffkMissing)
      check metadataOf(dangling).kind == ffkRegular
      check metadataOf(dangling) != retiredGenericBranch(dangling)

      let fifo = t.root / "fifo"
      check retiredGenericBranch(fifo) == FileMetadata(kind: ffkMissing)
      check metadataOf(fifo).kind == ffkOther
      check metadataOf(fifo) != retiredGenericBranch(fifo)

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

  test "COSTS: a dangling link whose target appears does NOT invalidate":
    when not defined(posix):
      skip()
    else:
      let t = makeTree()
      defer: removeDir(t.root)
      let link = t.root / "dangling"

      let record = recordFor(link)
      check hotMetadataRecordInputsUnchanged([record])

      # The target appears. `lstat` of the LINK is byte-identical before and
      # after -- same size, same mtime, same kind -- so this transition is
      # invisible. It was invisible on Linux before this change and is now
      # invisible on macOS too. The retired macOS classifier DID see it
      # (ffkMissing -> ffkRegular), and that is the one thing lost.
      #
      # This test asserts the hole ON PURPOSE. Closing it needs a recorded
      # link target for INPUTS; Incremental-Invalidation.md already requires
      # one for outputs (`OutputWitness.linkTarget`) and `FileFingerprint` has
      # no equivalent field, so it is a record-format change, not a
      # classification change. If a future change adds that witness, this
      # expectation flips and the assertion below is where it says so.
      writeFile(t.root / "never-created.txt", "appeared\n")
      check fileExists(t.root / "never-created.txt")
      check hotMetadataRecordInputsUnchanged([record])

      # And the compensating fact: the link is still classified as an entity,
      # so it is still being compared at all. Under ffkMissing it would have
      # been compared as "absent", and the appearance above is exactly the
      # transition an absent-path probe exists to catch.
      check metadataOf(link).kind == ffkRegular

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
