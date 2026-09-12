## The memoized image digest must never hide a changed image.
##
## WHY IT IS MEMOIZED. `startUserDaemon` compares the digest of the `repro`
## image on disk against the digest the running daemon reports for the staged
## image it is executing, to catch a daemon running old code. Every
## `repro build` performs that comparison, and the on-disk side was re-hashed
## from scratch every time: 15.66 MiB, measured in situ at 16.5 ms of a
## 74.7 ms warm no-op -- the second-largest term in the invocation's fixed
## cost, re-deriving an answer that does not change between builds.
##
## THE DIRECTION THAT MATTERS IS ONE-SIDED. A cache that re-derives when it
## did not need to costs time. A cache that returns a stale digest makes a
## daemon running old code look current, which is the exact failure the
## comparison exists to prevent -- an old engine decoding new build-target
## payloads. So every case here asserts that the cached answer equals a fresh
## uncached digest after some mutation of the image, and the mutations are
## chosen to attack the cache key rather than to exercise the happy path.
##
## MOCK POLICY: no mocks, and none may be added. The subject is whether a
## `stat`-derived key tracks real content changes, so the images are real
## files mutated on a real filesystem in the ways a rebuild or a hook
## reconciliation actually mutates them: rewrite in place, rename-over,
## same-size edit, and same-size-and-timestamp rename-over. A fake
## filesystem would decide the question by fiat.
##
## `imageDigestHex` is the uncached reference and is exported already.

import std/[os, strutils, tempfiles, times, unittest]

when defined(posix):
  import std/posix
  # Nim's `std/posix` does not expose `utimensat`, and it is the only way to
  # restore a modification time to the nanosecond -- which is what the
  # inode-isolating case below needs.
  proc utimensatRaw(dirfd: cint; path: cstring; times: ptr Timespec;
                    flags: cint): cint
    {.importc: "utimensat", header: "<sys/stat.h>".}
  var atFdCwd {.importc: "AT_FDCWD", header: "<fcntl.h>".}: cint

import repro_daemon_core

proc config(root: string): UserDaemonConfig =
  result = defaultUserDaemonConfig(devMode = true)
  result.stateDir = root / "state"
  result.endpoint = root / "daemon.sock"

proc writeImage(path, content: string) =
  writeFile(path, content)
  when defined(posix):
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc renameOver(path, content: string) =
  ## How `writeExecutableIfChanged` replaces a file: stage beside it, then one
  ## rename. This yields a NEW INODE, which is why the key folds inode.
  let staged = path & ".staged"
  writeImage(staged, content)
  moveFile(staged, path)

suite "the memoized image digest tracks the image":
  test "a warm cache returns exactly the uncached digest":
    let root = createTempDir("repro-digest-", "")
    defer: removeDir(root)
    let cfg = config(root)
    let image = root / "repro"
    writeImage(image, "image-one")
    let fresh = imageDigestHex(image)
    check fresh.len > 0
    # First call populates, second is served from the cache; both must equal
    # the uncached reference.
    check expectedDaemonRunningDigestHexForTest(cfg, image) == fresh
    check expectedDaemonRunningDigestHexForTest(cfg, image) == fresh

  test "a rewrite in place is not hidden by the cache":
    let root = createTempDir("repro-digest-", "")
    defer: removeDir(root)
    let cfg = config(root)
    let image = root / "repro"
    writeImage(image, "image-one")
    discard expectedDaemonRunningDigestHexForTest(cfg, image)
    writeImage(image, "image-two-different-length")
    checkpoint("after in-place rewrite")
    check expectedDaemonRunningDigestHexForTest(cfg, image) ==
      imageDigestHex(image)

  test "a rename-over is not hidden by the cache":
    # The mechanism `writeExecutableIfChanged` actually uses. A key that
    # folded only size and mtime could miss this; the inode moves.
    let root = createTempDir("repro-digest-", "")
    defer: removeDir(root)
    let cfg = config(root)
    let image = root / "repro"
    writeImage(image, "image-one")
    discard expectedDaemonRunningDigestHexForTest(cfg, image)
    renameOver(image, "image-two")
    checkpoint("after rename-over")
    check expectedDaemonRunningDigestHexForTest(cfg, image) ==
      imageDigestHex(image)

  test "a same-size change is not hidden by the cache":
    # Size alone cannot separate these; the mtime and inode must.
    let root = createTempDir("repro-digest-", "")
    defer: removeDir(root)
    let cfg = config(root)
    let image = root / "repro"
    writeImage(image, "AAAAAAAAAA")
    let before = expectedDaemonRunningDigestHexForTest(cfg, image)
    writeImage(image, "BBBBBBBBBB")
    check getFileSize(image) == 10
    checkpoint("same size, different bytes")
    let after = expectedDaemonRunningDigestHexForTest(cfg, image)
    check after != before
    check after == imageDigestHex(image)

  test "a same-size rename-over with a restored timestamp is not hidden":
    # THE HARDEST CASE FOR THE KEY. Same size, and the modification time put
    # back to what it was, so as little as possible distinguishes the two
    # images.
    #
    # It does NOT fully isolate the inode, and saying so is the point:
    # `setLastModificationTime` restores the timestamp only to the resolution
    # the API carries, while `fileIdentityStamp` folds mtime at full
    # nanosecond resolution, so the sub-second component still differs. A
    # test that claimed to prove the inode load-bearing would be claiming
    # more than it can construct through this API. The inode's role rests on
    # `fileIdentityStamp`'s construction and on the mutation run against it;
    # what this case does establish is that a same-size rename-over with the
    # timestamp restored as far as it can be is still not hidden.
    let root = createTempDir("repro-digest-", "")
    defer: removeDir(root)
    let cfg = config(root)
    let image = root / "repro"
    writeImage(image, "AAAAAAAAAA")
    let originalTime = getLastModificationTime(image)
    let before = expectedDaemonRunningDigestHexForTest(cfg, image)
    renameOver(image, "BBBBBBBBBB")
    setLastModificationTime(image, originalTime)
    check getFileSize(image) == 10
    check getLastModificationTime(image).toUnix == originalTime.toUnix
    checkpoint("same size, mtime restored to second resolution, new inode")
    let after = expectedDaemonRunningDigestHexForTest(cfg, image)
    check after != before
    check after == imageDigestHex(image)

  when defined(posix):
    test "a rename-over with the mtime restored to the NANOSECOND is not hidden":
      # THE CASE THAT ISOLATES THE INODE, and it needs `utimensat` to build:
      # `setLastModificationTime` does not restore the sub-second component,
      # so every other case here leaves mtime differing and cannot tell
      # whether the inode is carrying any weight. Here size is equal and mtime
      # is restored exactly, so the inode is the only field left that differs.
      #
      # Verified by mutation: removing the inode from `fileIdentityStamp`
      # reddens THIS case and no other.
      let root = createTempDir("repro-digest-", "")
      defer: removeDir(root)
      let cfg = config(root)
      let image = root / "repro"
      writeImage(image, "AAAAAAAAAA")
      var before: Stat
      check stat(image.cstring, before) == 0
      let firstDigest = expectedDaemonRunningDigestHexForTest(cfg, image)

      renameOver(image, "BBBBBBBBBB")
      var times: array[2, Timespec]
      times[0].tv_sec = before.st_atim.tv_sec
      times[0].tv_nsec = before.st_atim.tv_nsec
      times[1].tv_sec = before.st_mtim.tv_sec
      times[1].tv_nsec = before.st_mtim.tv_nsec
      check utimensatRaw(atFdCwd, image.cstring, addr times[0], 0) == 0

      var after: Stat
      check stat(image.cstring, after) == 0
      # The preconditions that make this case meaningful: identical size,
      # identical mtime to the nanosecond, different inode.
      check after.st_size == before.st_size
      check after.st_mtim.tv_sec == before.st_mtim.tv_sec
      check after.st_mtim.tv_nsec == before.st_mtim.tv_nsec
      check after.st_ino != before.st_ino
      checkpoint("size=" & $after.st_size &
        " mtime identical to ns, inode " & $before.st_ino & " -> " &
        $after.st_ino)

      let afterDigest = expectedDaemonRunningDigestHexForTest(cfg, image)
      check afterDigest != firstDigest
      check afterDigest == imageDigestHex(image)

  test "an unreadable image never answers from the cache":
    # A probe failure must not be able to make a stale daemon look current.
    # With no stamp the cache is bypassed entirely, so the answer is whatever
    # the uncached digest says -- including empty.
    let root = createTempDir("repro-digest-", "")
    defer: removeDir(root)
    let cfg = config(root)
    let image = root / "repro"
    writeImage(image, "image-one")
    let warm = expectedDaemonRunningDigestHexForTest(cfg, image)
    check warm.len > 0
    removeFile(image)
    checkpoint("image removed after the cache was warm")
    check expectedDaemonRunningDigestHexForTest(cfg, image) ==
      imageDigestHex(image)

  test "a corrupt cache file re-derives rather than answering wrongly":
    let root = createTempDir("repro-digest-", "")
    defer: removeDir(root)
    let cfg = config(root)
    let image = root / "repro"
    writeImage(image, "image-one")
    let fresh = imageDigestHex(image)
    discard expectedDaemonRunningDigestHexForTest(cfg, image)
    # Scribble over every cache file this config could have written.
    let cacheDir = cfg.stateDir / "image-digests"
    var scribbled = 0
    for kind, path in walkDir(cacheDir):
      if kind == pcFile:
        writeFile(path, "not-a-stamp\n")
        inc scribbled
    check scribbled > 0
    checkpoint("cache files scribbled: " & $scribbled)
    check expectedDaemonRunningDigestHexForTest(cfg, image) == fresh
