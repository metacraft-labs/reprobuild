## Real filesystem and cross-process locks only: no mocked acquisition. The
## holder acknowledges ownership before the contender enters the production
## template and retains it until explicitly released. Exercise the default
## 120-second deadline without any test override.
import std/[os, osproc, streams, strutils, tempfiles, unittest]
from repro_test_support/process_fixtures import releaseDirAtProcessExit
when defined(posix):
  from repro_test_support/process_fixtures import terminateAtProcessExit
import shared_clones

if paramCount() == 3 and paramStr(1) == "--hold-vcs-lock":
  let root = paramStr(2)
  var held = acquireVcsFileLock(root / "entry.repro-lock")
  var bareHeld = acquireVcsFileLock(cacheEntryLockPath(
    sharedBarePath(root / "cache", paramStr(3))))
  doAssert held.acquired and bareHeld.acquired
  stdout.writeLine("locked")
  stdout.flushFile()
  discard stdin.readLine()
  releaseVcsFileLock(bareHeld)
  releaseVcsFileLock(held)
  quit(0)

if paramCount() == 3 and paramStr(1) == "--refresh-contender":
  let root = paramStr(2)
  let upstream = paramStr(3)
  let res = refreshSharedBare(findExe("git"), root / "cache", upstream)
  doAssert not res.ok, "refresh ran without lock ownership"
  doAssert res.diagnostic.startsWith("could not lock shared bare:")
  doAssert not dirExists(sharedBarePath(root / "cache", upstream)),
    "refresh mutated the locked cache entry"
  quit(0)

if paramCount() == 2 and paramStr(1) == "--probe-vcs-lock":
  var probe = acquireVcsFileLock(paramStr(2), timeoutMs = 0)
  doAssert probe.acquired, "the previous body leaked lock ownership"
  releaseVcsFileLock(probe)
  quit(0)

proc independentlyAcquire(path: string): int =
  let res = execCmdEx(quoteShell(getAppFilename()) &
    " --probe-vcs-lock " & quoteShell(path))
  if res.exitCode != 0:
    stderr.write(res.output)
  res.exitCode

suite "required VCS locks exclude mutations on failure":
  test "another process owns the lock throughout the refused mutation":
    let root = genTempPath("vcs-lock-exclusion-", "")
    releaseDirAtProcessExit(root)
    createDir(root)
    defer: removeDir(root)
    let path = root / "entry.repro-lock"
    let marker = root / "protected-mutation"
    let upstream = root / "upstream.git"
    let gitBin = findExe("git")
    require gitBin.len > 0
    require execCmdEx(quoteShell(gitBin) & " init --bare --quiet " &
      quoteShell(upstream)).exitCode == 0
    let holder = startProcess(getAppFilename(),
      args = @["--hold-vcs-lock", root, upstream], options = {poStdErrToStdOut})
    when defined(posix):
      terminateAtProcessExit(holder.processID)
    defer:
      holder.inputStream.writeLine("release")
      holder.inputStream.flush()
      discard holder.waitForExit()
      holder.close()
    require holder.outputStream.readLine() == "locked"
    # Two contenders at most: the primitive below and the actual cache owner.
    # Both wait on the unchanged production deadline while the holder sleeps.
    let refresh = startProcess(getAppFilename(),
      args = @["--refresh-contender", root, upstream], options = {poStdErrToStdOut})
    when defined(posix):
      terminateAtProcessExit(refresh.processID)
    defer: refresh.close()
    var refused = false
    try:
      withVcsFileLock(path):
        writeFile(marker, "mutation while another process owns lock")
    except IOError:
      refused = true
    check refused
    check not fileExists(marker)
    let refreshOutput = refresh.outputStream.readAll()
    checkpoint(refreshOutput)
    check refresh.waitForExit() == 0
    check not dirExists(sharedBarePath(root / "cache", upstream))
    check holder.running
    var probe = acquireVcsFileLock(path, timeoutMs = 0)
    check not probe.acquired
    releaseVcsFileLock(probe)

  test "parent creation failure excludes mutation":
    let root = genTempPath("vcs-lock-parent-", "")
    releaseDirAtProcessExit(root)
    createDir(root)
    defer: removeDir(root)
    let blocker = root / "file"
    writeFile(blocker, "not a directory")
    let marker = root / "protected-mutation"
    var refused = false
    try:
      withVcsFileLock(blocker / "entry.repro-lock"):
        writeFile(marker, "unlocked mutation")
    except IOError:
      refused = true
    check refused
    check not fileExists(marker)

  test "success and same-thread reentrancy release normally":
    let root = genTempPath("vcs-lock-success-", "")
    releaseDirAtProcessExit(root)
    createDir(root)
    defer: removeDir(root)
    let path = root / "entry.repro-lock"
    var count = 0
    withVcsFileLock(path):
      inc count
      withVcsFileLock(path):
        inc count
    check count == 2
    check independentlyAcquire(path) == 0
    var again = acquireVcsFileLock(path, timeoutMs = 0)
    check again.acquired
    releaseVcsFileLock(again)

  test "empty optional path still executes the body":
    var ran = false
    withVcsFileLock(""):
      ran = true
    check ran

  test "lock expressions are evaluated once and body exceptions release ownership":
    let root = genTempPath("vcs-lock-release-", "")
    releaseDirAtProcessExit(root)
    createDir(root)
    defer: removeDir(root)
    let path = root / "entry.repro-lock"
    var evaluations = 0
    proc lockPath(): string =
      inc evaluations
      path
    expect ValueError:
      withVcsFileLock(lockPath()):
        raise newException(ValueError, "body failed")
    check evaluations == 1
    check independentlyAcquire(path) == 0
    var again = acquireVcsFileLock(path, timeoutMs = 0)
    check again.acquired
    releaseVcsFileLock(again)
    let blocker = root / "file"
    writeFile(blocker, "not a directory")
    evaluations = 0
    proc badLockPath(): string =
      inc evaluations
      blocker / "entry.repro-lock"
    expect IOError:
      withVcsFileLock(badLockPath()):
        fail()
    check evaluations == 1

  test "cache owners return structured refusals when the lock parent is a file":
    let root = genTempPath("vcs-lock-api-", "")
    releaseDirAtProcessExit(root)
    createDir(root)
    defer: removeDir(root)
    let blocker = root / "file"
    writeFile(blocker, "not a directory")
    let gitBin = findExe("git")
    require gitBin.len > 0
    let refreshed = refreshSharedBare(gitBin, blocker, "https://example.invalid/repo")
    check not refreshed.ok
    check refreshed.diagnostic.startsWith("could not lock shared bare:")
    let manifest = ensureManifestCache(gitBin, blocker, "https://example.invalid/repo")
    check not manifest.ok
    check manifest.diagnostic.startsWith("could not lock manifest cache:")
    let pool = blocker / "pool.git"
    check not registerBorrower(pool, root / "leaf")
    check pruneBorrowers(pool).len == 0
    let maintained = maintainSharedBare(gitBin, pool, @[], force = true)
    check not maintained.ok
    check not maintained.ran
    check maintained.diagnostic.startsWith("could not lock shared bare:")
    check readFile(blocker) == "not a directory"

  test "checkout owners refuse an uncreatable required worktree lock":
    # A damaged linked-worktree commondir names a regular file. This real
    # filesystem shape gives a nonempty required lock whose parent creation
    # fails immediately, without shortening the production retry deadline.
    let root = genTempPath("vcs-lock-checkout-", "")
    releaseDirAtProcessExit(root)
    createDir(root)
    defer: removeDir(root)
    let leaf = root / "leaf"
    let gd = root / "gitdir"
    let blocker = root / "file"
    let pool = root / "pool.git"
    createDir(leaf)
    createDir(gd)
    createDir(pool / "objects")
    writeFile(blocker, "not a directory")
    writeFile(leaf / ".git", "gitdir: " & gd & "\n")
    writeFile(gd / "commondir", blocker & "\n")
    check checkoutLockPath(leaf) == blocker / "repro-vcs-lock"
    let wired = wireAlternates(leaf, pool)
    check not wired.ok
    check wired.diagnostic.startsWith("could not lock checkout:")
    let detected = checkLeaf("git", leaf, lcmRepair, pool = pool)
    check not detected.registered
    check not detected.configured
    check detected.findings.len == 0
    check detected.diagnostic.startsWith("could not lock checkout:")
    check registerLeafWithPool("git", leaf, pool).startsWith("could not lock checkout:")
    check not fileExists(pool / "repro" / "borrowers")
    check not fileExists(gd / "objects" / "info" / "alternates")
    check readFile(blocker) == "not a directory"
