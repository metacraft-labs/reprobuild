## The trust boundary of canonical work trees (reprobuild-pm
## `spec/Hermetic-Builds-And-Path-Independence.md` §"Canonical work trees").
##
## A root every account can create entries in is safe only in one form, and a
## key directory only when it is this user's and private. Anything else is
## REFUSED, left as it is, and the work tree falls back to the per-user
## location; a held key is busy, never a fallback.
##
## No mocks: real directories under private temporary directories, with the
## system root and the per-user root passed in so the test never touches the
## host's real `C:\repro-exec` or `/var/tmp/repro-exec`. Each unsafe case is
## constructed for real (a world-writable non-sticky directory, a symbolic
## link, an ACE granting Everyone write) and must change the outcome; the
## matching safe case beside it is the control.

import std/[os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_core/canonical_work_dir
import repro_core/paths

when defined(posix):
  import std/posix

proc freshRoots(tag: string): tuple[base, system, user: string] =
  let base = createTempDir("canonical-work-" & tag & "-", "")
  (base, base / "system-root", base / "user-cache" / ExecRootDirName)

proc cleanup(base: string) =
  # The system root is sticky (POSIX) or carries an explicit DACL (Windows);
  # both are removable by their creator.
  try: removeDir(base)
  except OSError: discard

suite "canonical work keys":
  test "a key is one safe path component":
    check isValidCanonicalWorkKey("node-build-0123456789abcdef")
    check isValidCanonicalWorkKey("a_b")
    check not isValidCanonicalWorkKey("")
    check not isValidCanonicalWorkKey("-x")
    check not isValidCanonicalWorkKey("..")
    check not isValidCanonicalWorkKey("a/b")
    check not isValidCanonicalWorkKey("a\\b")
    check not isValidCanonicalWorkKey("a.b")
    check not isValidCanonicalWorkKey(repeat('a', MaxCanonicalWorkKeyLen + 1))

  test "an invalid key is refused, not placed":
    let r = freshRoots("badkey")
    defer: cleanup(r.base)
    let outcome = tryAcquireCanonicalWork("../escape", r.system, r.user)
    check outcome.status == cwsRefused
    check "invalid canonical work key" in outcome.reason
    check not dirExists(r.system)

suite "canonical work trees: the safe path":
  test "a fresh root is created, the key placed under it, and locked":
    let r = freshRoots("fresh")
    defer: cleanup(r.base)
    var outcome = tryAcquireCanonicalWork("k-fresh", r.system, r.user)
    require outcome.status == cwsAcquired
    check outcome.lease.placement == cwpSystemRoot
    check outcome.lease.fallbackReason == ""
    check outcome.lease.workDir == r.system / "k-fresh" / "work"
    check verifyExecRoot(r.system) == ""
    check verifyCanonicalKeyDir(r.system / "k-fresh") == ""
    when defined(posix):
      var st: Stat
      require stat(r.system.cstring, st) == 0
      check (int(st.st_mode) and 0o7777) == 0o1777
      require stat((r.system / "k-fresh").cstring, st) == 0
      check (int(st.st_mode) and 0o777) == 0o700
    # The second build of the same key is deferred, not sent elsewhere.
    let second = tryAcquireCanonicalWork("k-fresh", r.system, r.user)
    check second.status == cwsBusy
    check not dirExists(r.user)
    discard outcome.lease.releaseCanonicalWork(removeTree = false)
    var third = tryAcquireCanonicalWork("k-fresh", r.system, r.user)
    check third.status == cwsAcquired
    discard third.lease.releaseCanonicalWork(removeTree = false)

  test "the tree is emptied before use and removed after a successful run":
    let r = freshRoots("empty")
    defer: cleanup(r.base)
    var outcome = tryAcquireCanonicalWork("k-empty", r.system, r.user)
    require outcome.status == cwsAcquired
    createDir(outcome.lease.workDir / "node_modules")
    writeFile(outcome.lease.workDir / "stale.txt", "from a failed run")
    check emptyCanonicalWorkTree(outcome.lease) == ""
    check dirExists(outcome.lease.workDir)
    check not fileExists(outcome.lease.workDir / "stale.txt")
    writeFile(outcome.lease.workDir / "built.txt", "x")
    check outcome.lease.releaseCanonicalWork(removeTree = true) == ""
    check not dirExists(outcome.lease.workDir)
    # The key directory and its lock stay: removing them could let two
    # builds each lock a different file.
    check dirExists(r.system / "k-empty")
    check fileExists(r.system / "k-empty" / "lock")

  test "a tree nested past MAX_PATH is emptied and removed whole":
    # An npm tree nests far past 260 characters. The first gemini-cli run
    # with canonical trees left 131 MB behind: the removal used the plain
    # path and stopped at the first file too deep to name on Windows.
    let r = freshRoots("deep")
    defer: cleanup(r.base)
    var outcome = tryAcquireCanonicalWork("k-deep", r.system, r.user)
    require outcome.status == cwsAcquired
    check emptyCanonicalWorkTree(outcome.lease) == ""
    proc deepTree(root: string): string =
      result = root
      for i in 0 ..< 12:
        result = result / ("node_modules-" & repeat('d', 20) & $i)
      createDir(extendedPath(result))
      writeFile(extendedPath(result / "index.js"), "deep")
    let deep = deepTree(outcome.lease.workDir)
    check deep.len > 300
    writeFile(outcome.lease.workDir / "top.txt", "x")
    check emptyCanonicalWorkTree(outcome.lease) == ""
    check not fileExists(extendedPath(deep / "index.js"))
    check not fileExists(outcome.lease.workDir / "top.txt")
    check dirExists(outcome.lease.workDir)
    let deep2 = deepTree(outcome.lease.workDir)
    check outcome.lease.releaseCanonicalWork(removeTree = true) == ""
    check not fileExists(extendedPath(deep2 / "index.js"))
    check not dirExists(outcome.lease.workDir)

  test "a failed run's tree is kept for inspection":
    let r = freshRoots("kept")
    defer: cleanup(r.base)
    var outcome = tryAcquireCanonicalWork("k-kept", r.system, r.user)
    require outcome.status == cwsAcquired
    check emptyCanonicalWorkTree(outcome.lease) == ""
    writeFile(outcome.lease.workDir / "partial.txt", "x")
    check outcome.lease.releaseCanonicalWork(removeTree = false) == ""
    check fileExists(outcome.lease.workDir / "partial.txt")

suite "canonical work trees: an unsafe root falls back":
  test "a world-writable root that is not sticky":
    when defined(posix):
      let r = freshRoots("nosticky")
      defer: cleanup(r.base)
      createDir(r.system)
      require chmod(r.system.cstring, Mode(0o777)) == 0
      var outcome = tryAcquireCanonicalWork("k-nosticky", r.system, r.user)
      require outcome.status == cwsAcquired
      check outcome.lease.placement == cwpUserFallback
      check "not sticky" in outcome.lease.fallbackReason
      check outcome.lease.workDir == r.user / "k-nosticky" / "work"
      # Refused and left as it was: nothing was created inside it, and its
      # mode was not repaired.
      check not dirExists(r.system / "k-nosticky")
      var st: Stat
      require stat(r.system.cstring, st) == 0
      check (int(st.st_mode) and 0o7777) == 0o777
      discard outcome.lease.releaseCanonicalWork(removeTree = false)
    else:
      skip("the mode/sticky-bit rule is POSIX; the Windows ACL case is " &
        "`a root whose ACL lets other accounts write it`")

  test "a root whose ACL lets other accounts write it":
    when defined(windows):
      let r = freshRoots("aclroot")
      defer: cleanup(r.base)
      createDir(r.system)
      # Everyone (S-1-1-0) may modify: rename, replace, delete-child.
      let (output, code) = execCmdEx("icacls \"" & r.system &
        "\" /grant *S-1-1-0:(OI)(CI)(M)")
      require code == 0
      checkpoint(output)
      check verifyExecRoot(r.system).len > 0
      var outcome = tryAcquireCanonicalWork("k-aclroot", r.system, r.user)
      require outcome.status == cwsAcquired
      check outcome.lease.placement == cwpUserFallback
      check "S-1-1-0" in outcome.lease.fallbackReason
      check not dirExists(r.system / "k-aclroot")
      discard outcome.lease.releaseCanonicalWork(removeTree = false)
    else:
      skip("the ACL rule is Windows'; the POSIX case is `a world-writable " &
        "root that is not sticky`")

  test "a root that is a link, not a real directory":
    let r = freshRoots("link")
    defer: cleanup(r.base)
    let elsewhere = r.base / "elsewhere"
    createDir(elsewhere)
    when defined(windows):
      let (output, code) = execCmdEx("cmd /c mklink /J \"" & r.system &
        "\" \"" & elsewhere & "\"")
      require code == 0
      checkpoint(output)
    else:
      createSymlink(elsewhere, r.system)
    var outcome = tryAcquireCanonicalWork("k-link", r.system, r.user)
    require outcome.status == cwsAcquired
    check outcome.lease.placement == cwpUserFallback
    check outcome.lease.fallbackReason.len > 0
    check not dirExists(elsewhere / "k-link")
    discard outcome.lease.releaseCanonicalWork(removeTree = false)

suite "canonical work trees: a key directory that is not ours falls back":
  test "a key directory another account owns is refused":
    # A directory this user certainly does not own: the filesystem root on
    # POSIX (when not running as root), the Windows directory elsewhere.
    when defined(posix):
      if geteuid() == 0:
        skip("running as root, which owns `/`; the foreign-owner check " &
          "needs a directory another account owns")
      else:
        let why = verifyCanonicalKeyDir("/")
        check "belongs to another account" in why
    else:
      let winDir = getEnv("SystemRoot", "C:\\Windows")
      let why = verifyCanonicalKeyDir(winDir)
      checkpoint(why)
      check "belongs to another account" in why

  test "a foreign-owned key directory under a safe root falls back":
    when defined(posix):
      if geteuid() != 0:
        skip("creating a directory another account owns needs root (chown); " &
          "the check itself is covered by `a key directory another account " &
          "owns is refused`")
      else:
        let r = freshRoots("foreign")
        defer: cleanup(r.base)
        check ensureExecRoot(r.system) == ""
        createDir(r.system / "k-foreign")
        require chown((r.system / "k-foreign").cstring, Uid(65534),
          Gid(65534)) == 0
        var outcome = tryAcquireCanonicalWork("k-foreign", r.system, r.user)
        require outcome.status == cwsAcquired
        check outcome.lease.placement == cwpUserFallback
        check "another account" in outcome.lease.fallbackReason
        discard outcome.lease.releaseCanonicalWork(removeTree = false)
    else:
      skip("a non-elevated Windows account cannot make another account own " &
        "a directory; the check itself is covered by `a key directory " &
        "another account owns is refused`, and the flow by `a key " &
        "directory that grants another account access`")

  test "a key directory that grants another account access":
    let r = freshRoots("keyacl")
    defer: cleanup(r.base)
    check ensureExecRoot(r.system) == ""
    let keyDir = r.system / "k-keyacl"
    when defined(windows):
      createDir(keyDir)
      let (output, code) = execCmdEx("icacls \"" & keyDir &
        "\" /grant *S-1-1-0:(OI)(CI)(R)")
      require code == 0
      checkpoint(output)
    else:
      createDir(keyDir)
      require chmod(keyDir.cstring, Mode(0o755)) == 0
    check verifyCanonicalKeyDir(keyDir).len > 0
    var outcome = tryAcquireCanonicalWork("k-keyacl", r.system, r.user)
    require outcome.status == cwsAcquired
    check outcome.lease.placement == cwpUserFallback
    check outcome.lease.fallbackReason.len > 0
    # Refused, not repaired, and nothing put inside it.
    check not fileExists(keyDir / "lock")
    discard outcome.lease.releaseCanonicalWork(removeTree = false)

  test "refused everywhere: the action is refused with both reasons":
    when defined(posix):
      let r = freshRoots("both")
      defer: cleanup(r.base)
      createDir(r.system)
      require chmod(r.system.cstring, Mode(0o777)) == 0
      createDir(parentDir(r.user))
      createDir(r.user)
      require chmod(r.user.cstring, Mode(0o755)) == 0
      let outcome = tryAcquireCanonicalWork("k-both", r.system, r.user)
      check outcome.status == cwsRefused
      check "not sticky" in outcome.reason
      check "per-user fallback was refused" in outcome.reason
    else:
      skip("the per-user root on Windows is checked only for being a real " &
        "directory (the profile ACL admits only its user), so the double " &
        "refusal is constructed on POSIX")
