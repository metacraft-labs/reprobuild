## TC-8c — the local certificate store is a bounded cache (test-certificates
## Transport §2.5, operator decision D4).
##
##   1. With 25 content directories, a prune keeps the newest 20 (by the
##      directory's modification time) and the current repository's
##      ``HEAD^{tree}`` directory, even when that one is the OLDEST.
##   2. A configured count of 5 (the user-level setting, read from
##      ``$XDG_CONFIG_HOME/reprobuild/config.toml``) keeps 5 plus
##      ``HEAD^{tree}``, through the producer's own publish-then-prune.
##
## And the races a prune must survive, each driven DETERMINISTICALLY through
## the writer's and the pruner's test seams (no sleeps, no threads):
##
##   3. A prune that took the content directory between the writer's create
##      and its rename costs the writer ONE retry: its temporary file went
##      with the directory, the rename failed, and the retry writes into a
##      fresh directory the removal can no longer reach.
##   4. A directory REPLACED at the same path (another producer recreated it
##      after a prune renamed the old one aside) is detected by identity, and
##      the writer retries into the new one.
##   5. A prune takes a directory out of the store in ONE step — renamed,
##      within its parent, to a dot-name — and deletes the tree only after
##      that: mid-removal, a reader already sees nothing at the content's
##      path, and the renamed tree still holds its file. A leftover dot-named
##      directory of a prune that died is deleted by the next prune.
##   6. A directory a writer is in — a fresh temporary file, or modified a
##      moment ago — is never pruned.
##   7. A content directory that exists but cannot be listed is UNREADABLE,
##      never "empty".
##
## Falsifiability: prune by name instead of by time, or forget the protected
## ``HEAD^{tree}`` directory → 1 fails; ignore the configured count → 2 fails;
## drop the writer's retry → 3 and 4 fail; delete in place instead of renaming
## aside → 5 fails; drop the being-written guard → 6 fails; ``walkDir``
## without ``checkDir`` → 7 fails.
##
## Real filesystem, real git (for ``HEAD^{tree}``). Skip rule: none — git is
## required, and its absence fails the case.

import repro_test_support/reasoned_skip
import std/[algorithm, os, osproc, sequtils, strutils, tempfiles, times,
            unittest]

import repro_cli_support

proc gitOut(dir: string; args: varargs[string]): string =
  var argv = @["git", "-C", dir]
  for a in args: argv.add(a)
  let res = execCmdEx(quoteShellCommand(argv))
  doAssert res.exitCode == 0, argv.join(" ") & " failed:\n" & res.output
  res.output.strip()

proc newRepo(scratch: string): string =
  result = scratch / "repo"
  createDir(result)
  discard gitOut(result, "init", "-q", "-b", "main")
  discard gitOut(result, "config", "user.email", "tester@example.invalid")
  discard gitOut(result, "config", "user.name", "TC8c Prune")
  writeFile(result / "a.txt", "a\n")
  discard gitOut(result, "add", "a.txt")
  discard gitOut(result, "commit", "-q", "-m", "a")

proc hexDigest(i: int): string =
  ## A 40-hex digest, distinct per ``i``.
  let h = toHex(i, 8).toLowerAscii()
  h & "0".repeat(32)

proc makeContentDir(root, digest: string; age: Duration): string =
  ## ``<root>/v1/git-tree-sha1/<digest>/`` holding one record, last modified
  ## ``age`` ago.
  result = "v1/git-tree-sha1/" & digest
  let dir = root / "v1" / "git-tree-sha1" / digest
  createDir(dir)
  writeFile(dir / ("0".repeat(64) & ".toml"), "[certificate]\n")
  setLastModificationTime(dir, getTime() - age)

proc readDirectoryProbe(path: string): bool =
  ## Whether this process can list ``path``.
  try:
    for _ in walkDir(path, checkDir = true):
      discard
    true
  except OSError:
    false

proc contentDirs(root: string): seq[string] =
  let base = root / "v1" / "git-tree-sha1"
  if not dirExists(base): return
  for kind, path in walkDir(base):
    if kind == pcDir:
      result.add(path.extractFilename)
  result.sort()

suite "TC-8c — local store retention":

  test "t_local_store_prune_keeps_newest_and_head_tree":
    let scratch = createTempDir("repro-tc8c-prune-", "")
    defer: removeDir(scratch)
    let repo = newRepo(scratch)
    let headTree = gitOut(repo, "rev-parse", "HEAD^{tree}")
    check headContentDir(repo) == "v1/git-tree-sha1/" & headTree

    # ---- 1. 25 directories: newest 20 + the (oldest) HEAD^{tree} ---------
    let root = scratch / "store"
    # The HEAD^{tree} directory is the OLDEST of all.
    discard makeContentDir(root, headTree, initDuration(days = 400))
    var byAge: seq[string]   # newest first
    for i in 1 .. 24:
      let d = hexDigest(i)
      discard makeContentDir(root, d, initDuration(hours = i))
      byAge.add(d)
    check contentDirs(root).len == 25
    let outcome = pruneStoreRoot(root, 20, [headContentDir(repo)])
    check outcome.errors.len == 0
    var expected = byAge[0 ..< 20] & @[headTree]
    expected.sort()
    check contentDirs(root) == expected
    check outcome.removed.len == 4
    for d in byAge[20 .. ^1]:
      check ("v1/git-tree-sha1/" & d) in outcome.removed
    # Nothing left aside.
    check toSeq(walkDir(root / "v1" / "git-tree-sha1")).allIt(
      not it.path.extractFilename.startsWith("."))

    # ---- 2. a configured count of 5 keeps 5 + HEAD^{tree} -----------------
    let configHome = scratch / "config"
    createDir(configHome / "reprobuild")
    writeFile(configHome / "reprobuild" / "config.toml",
      "# user-level settings\n[certificate_store]\nkeep = 5\n")
    putEnv("XDG_CONFIG_HOME", configHome)
    delEnv("REPRO_CERTIFICATE_STORE_KEEP")
    check certificateStoreRetention(
      proc(n: string): string = getEnv(n)).keep == 5
    let root2 = scratch / "store-configured"
    discard makeContentDir(root2, headTree, initDuration(days = 400))
    for i in 1 .. 24:
      discard makeContentDir(root2, hexDigest(i), initDuration(hours = i))
    # The producer's own path: deliver one certificate (a NEW content, so the
    # newest directory), then prune with the user's setting.
    let cert = TestCertificate(schema: testCertificateSchemaV1,
      framework: reprobuildFrameworkId, project: "p",
      platform: "linux/amd64", targets: @["t"], result: tcrPassed,
      issuedAt: "2026-10-11T00:00:00Z", issuer: "tc8c",
      vcs: TestCertificateVcs(repo: "p",
        content: "git-tree-sha1:" & "f".repeat(40)),
      commands: @[TestCertificateCommand(argv: @["true"])])
    let delivered = publishCertificateToLocalStore(cert, repo,
      CertificateStoreRoots(user: root2))
    check delivered.error == ""
    check delivered.written
    check delivered.pruned.errors.len == 0
    var expected2 = @["f".repeat(40)] & (1 .. 4).toSeq.mapIt(hexDigest(it)) &
      @[headTree]
    expected2.sort()
    check contentDirs(root2) == expected2

  test "a prune that takes the directory mid-write costs the writer one retry":
    let scratch = createTempDir("repro-tc8c-race-", "")
    defer: removeDir(scratch)
    let root = scratch / "store"
    let relative = "v1/git-tree-sha1/" & "a".repeat(40) & "/" &
      "1".repeat(64) & ".toml"
    var prunedDuring: seq[string]
    var calls: seq[int]
    let published = publishStoreRecord(root, relative, "[certificate]\n",
      signed = true,
      beforeRename = proc(attempt: int) =
        calls.add(attempt)
        if attempt == 0:
          # A prune that chose this directory before the temporary file
          # appeared: modelled by a clock two hours ahead, so neither the
          # directory nor the temporary file looks fresh to it.
          let p = pruneStoreRoot(root, 0, [],
            now = getTime() + initDuration(hours = 2))
          prunedDuring = p.removed)
    check prunedDuring == @["v1/git-tree-sha1/" & "a".repeat(40)]
    check calls == @[0, 1]
    check published.error == ""
    check published.retried
    check fileExists(root / relative)
    check readFile(root / relative) == "[certificate]\n"
    # The removal's renamed tree is gone and nothing is left aside.
    check toSeq(walkDir(root / "v1" / "git-tree-sha1")).mapIt(
      it.path.extractFilename) == @["a".repeat(40)]

  test "a directory replaced at the same path is detected and retried into":
    let scratch = createTempDir("repro-tc8c-replaced-", "")
    defer: removeDir(scratch)
    let root = scratch / "store"
    let digestDir = root / "v1" / "git-tree-sha1" / ("b".repeat(40))
    let relative = "v1/git-tree-sha1/" & "b".repeat(40) & "/" &
      "2".repeat(64) & ".toml"
    var calls: seq[int]
    let published = publishStoreRecord(root, relative, "x = 1\n",
      signed = false,
      beforeRename = proc(attempt: int) =
        calls.add(attempt)
        if attempt == 0:
          # A prune renamed the directory aside (taking the temporary file)
          # and another producer recreated it at the same path.
          moveDir(digestDir, digestDir.parentDir / ".aside")
          createDir(digestDir))
    check calls == @[0, 1]
    check published.error == ""
    check published.retried
    check readFile(root / relative) == "x = 1\n"
    # The renamed tree took the first attempt's temporary file with it: a
    # dot-name, which no reader lists as a record.
    let leftovers = toSeq(walkDir(digestDir.parentDir / ".aside")).mapIt(
      it.path.extractFilename)
    check leftovers.len == 1
    check leftovers.allIt(it.startsWith(".") and not it.endsWith(".toml"))
    # A dot-named directory is never a content directory: the next prune
    # deletes it.
    discard pruneStoreRoot(root, 20, [])
    check not dirExists(digestDir.parentDir / ".aside")
    check fileExists(root / relative)

  test "a prune renames a directory aside before deleting it":
    let scratch = createTempDir("repro-tc8c-aside-", "")
    defer: removeDir(scratch)
    let root = scratch / "store"
    let old = makeContentDir(root, "c".repeat(40), initDuration(days = 2))
    # A leftover of a prune that died after its rename aside.
    let leftover = root / "v1" / "git-tree-sha1" /
      ("." & "d".repeat(40) & RemovalMarker & "1-1")
    createDir(leftover)
    writeFile(leftover / "x.toml", "x\n")
    var detachedSeen = false
    var readerSawAbsent = false
    var asideHeldRecord = false
    let outcome = pruneStoreRoot(root, 0, [],
      onStep = proc(stage: PruneStage; relative: string) =
        if stage == psDetached:
          detachedSeen = true
          # Out of the store in one step: a reader finds nothing at the
          # content's path...
          readerSawAbsent =
            listStoreContentDir(root, relative).status == slsAbsent
          # ...and the renamed tree, a dot-name in the same parent, still
          # holds the record: deletion has not started.
          var aside: seq[string]
          for kind, path in walkDir(root / "v1" / "git-tree-sha1"):
            let name = path.extractFilename
            if name.startsWith("." & "c".repeat(40) & RemovalMarker):
              aside.add(path)
          asideHeldRecord = aside.len == 1 and
            toSeq(walkDir(aside[0])).len == 1)
    check detachedSeen
    check readerSawAbsent
    check asideHeldRecord
    check outcome.removed == @[old]
    check outcome.errors.len == 0
    check not dirExists(leftover)
    check toSeq(walkDir(root / "v1" / "git-tree-sha1")).len == 0

  test "a directory a writer is in is never pruned":
    let scratch = createTempDir("repro-tc8c-inuse-", "")
    defer: removeDir(scratch)
    let root = scratch / "store"
    # Old directory, but a writer's FRESH temporary file is inside it.
    let busy = makeContentDir(root, "e".repeat(40), initDuration(days = 3))
    let busyDir = root / busy
    writeFile(busyDir / ("." & "3".repeat(64) & ".toml" & TemporaryMarker &
      "77-1-1"), "partial")
    setLastModificationTime(busyDir, getTime() - initDuration(days = 3))
    # A directory modified a moment ago (a writer created it and has not yet
    # opened its temporary file).
    let fresh = makeContentDir(root, "9".repeat(40), initDuration(seconds = 0))
    # And an old, idle one, which does go.
    let idle = makeContentDir(root, "8".repeat(40), initDuration(days = 4))
    let outcome = pruneStoreRoot(root, 0, [])
    check outcome.removed == @[idle]
    check dirExists(root / busy)
    check dirExists(root / fresh)

  test "a content directory that cannot be listed is unreadable, not empty":
    when defined(windows):
      skip("POSIX permission bits are what make the directory unreadable here")
    else:
      let scratch = createTempDir("repro-tc8c-unreadable-", "")
      defer:
        for kind, path in walkDir(scratch / "store" / "v1" / "git-tree-sha1"):
          setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
        removeDir(scratch)
      let root = scratch / "store"
      let rel = makeContentDir(root, "7".repeat(40), initDuration(days = 1))
      check listStoreContentDir(root, rel).status == slsListed
      check listStoreContentDir(root, rel).files.len == 1
      setFilePermissions(root / rel, {})
      if readDirectoryProbe(root / rel):
        skip("this process can read a mode-000 directory (it runs as root), " &
          "so an unreadable directory cannot be constructed here")
      else:
        let listing = listStoreContentDir(root, rel)
        check listing.status == slsUnreadable
        check listing.problems.len == 1
        check listing.files.len == 0
