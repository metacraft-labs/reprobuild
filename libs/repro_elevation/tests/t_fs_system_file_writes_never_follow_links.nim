## ``fs.systemFile`` writes never follow a link and never land in a
## directory an ordinary user controls. The allowlist (``/etc``,
## ``/usr/local/etc``, ``${PROGRAMDATA}``) checks only a path's text, and
## a write that opened the path by name followed every link on it, so a
## link planted on the path redirected root's write to any file; a
## directory an ordinary user can write lets that user replace whatever
## root writes there.
##
## Two halves:
##
## * The pure rules every platform's driver applies -- which directory
##   owners, modes and ACLs are trusted (``dirIsTrusted`` for POSIX,
##   ``untrustedReason`` for Windows), and where the macOS walk starts
##   (``systemFileHostPath``) -- tested on every platform.
## * The real driver, ``applyFsSystemFile``, writing a real ``/etc`` as
##   root. Each case runs in a forked child that enters a new user and
##   mount namespace (where it is root over its own files only), mounts a
##   tmpfs, builds ``/etc``, ``/usr/local/etc`` and an ``/outside`` there
##   and ``chroot``s into it, so the allowlisted paths are real paths and
##   nothing on the host is touched. Before the fix a world-writable
##   directory on the path was written into; that is what the
##   ``untrusted`` cases show.
##
## The Windows half of the driver (reparse points, DACLs) is exercised on
## Windows by ``tests/windows/windows_fs_system_file_never_follows_reparse_points.nim``.
##
## *Mocking.* None. Real files, links and directories; the real driver; a
## real chroot. The namespaces only stand in for a disposable host.

import std/[os, posix, strutils, unittest]

import repro_test_support/reasoned_skip

import repro_elevation/errors
import repro_elevation/fixture_driver
import repro_elevation/nofollow_write
import repro_elevation/operations
import repro_elevation/posix_system_driver
import repro_elevation/posix_system_parse
import repro_elevation/windows_nofollow_write

suite "the trust rules (pure)":
  test "POSIX: a directory only root or the writer can modify is trusted":
    check dirIsTrusted(0, 0, 0o755, 1000, false)
    check dirIsTrusted(1000, 1000, 0o700, 1000, false)   # the writer's own
    check dirIsTrusted(0, 0, 0o775, 1000, false)         # root's group
    check dirIsTrusted(0, 5, 0o755, 1000, true)          # ACL, no group write

  test "POSIX: another owner, other-write or a foreign group-write is not":
    # Intel Homebrew: /usr/local/etc owned by the installing user.
    check not dirIsTrusted(501, 80, 0o755, 0, false)
    check not dirIsTrusted(0, 0, 0o777, 0, false)
    check not dirIsTrusted(0, 0, 0o1777, 0, false)       # sticky is no help
    check not dirIsTrusted(0, 80, 0o775, 0, false)       # admin group-write
    # With an ACL the group bits are the mask of every named entry.
    check not dirIsTrusted(0, 0, 0o775, 0, true)
    # A macOS ACL entry granting add_file etc. is not bounded by the mode.
    check not dirIsTrusted(0, 0, 0o755, 0, false, aclGrantsModify = true)

  test "POSIX: an ancestor of the allowlist root is judged by mode alone":
    # In a user namespace the host's / is owned by the overflow uid.
    check modeIsTrusted(65534, 0o755, false)
    check not modeIsTrusted(0, 0o777, false)
    check not modeIsTrusted(80, 0o775, false)
    check not modeIsTrusted(0, 0o755, false, aclGrantsModify = true)

  const
    System = "S-1-5-18"
    Admins = "S-1-5-32-544"
    Users = "S-1-5-32-545"
    Everyone = "S-1-1-0"
    Writer = "S-1-5-21-1-2-3-1001"
    Someone = "S-1-5-21-1-2-3-1002"

  test "Windows: the stock ProgramData DACL is trusted":
    # SYSTEM, Administrators: full; CREATOR OWNER inherit-only; Users:
    # read/execute and create files/folders (WD, AD, WEA, WA).
    let aces = [
      AceView(allow: true, sid: System, mask: 0x1F01FF),
      AceView(allow: true, sid: Admins, mask: 0x1F01FF),
      AceView(allow: true, inheritOnly: true, sid: "S-1-3-0", mask: 0x10000000),
      AceView(allow: true, sid: Users, mask: 0x1200A9),
      AceView(allow: true, sid: Users, mask: 0x000116)]
    check untrustedReason(System, true, aces, Writer) == ""
    check untrustedReason(Writer, true, aces, Writer) == ""

  test "Windows: a user-owned folder, a NULL DACL or a takeover grant is not":
    check "owned by " & Someone in untrustedReason(Someone, true, [], Writer)
    check "no DACL" in untrustedReason(Admins, false, [], Writer)
    for mask in [0x1F01FF'u32, 0x10000000'u32, 0x40000'u32, 0x80000'u32,
                 0x10000'u32, 0x40'u32]:
      check Everyone in untrustedReason(Admins, true,
        [AceView(allow: true, sid: Everyone, mask: mask)], Writer)

  test "Windows: an ACE type the check cannot read fails closed":
    check aceViewKind(0) == (allow: true, unknown: false)
    check aceViewKind(9) == (allow: true, unknown: false)     # callback allow
    for t in [1'u8, 6, 10, 12]:
      check aceViewKind(t) == (allow: false, unknown: false)  # deny types
    for t in [5'u8, 11, 17]:
      check aceViewKind(t).unknown
    check "type 5" in untrustedReason(Admins, true,
      [AceView(unknown: true, aceType: 5)], Writer)
    check untrustedReason(Admins, true,
      [AceView(unknown: true, inheritOnly: true, aceType: 5)], Writer) == ""

  test "Windows: only an administrator's restrictive DACL is carried over":
    let restricted = [AceView(allow: true, sid: System, mask: 0x1F01FF),
                      AceView(allow: true, sid: Admins, mask: 0x1F01FF),
                      AceView(allow: true, sid: Users, mask: 0x1200A9)]
    check keepsDacl(Admins, 1, true, restricted, Writer)
    check keepsDacl(Writer, 1, true, restricted, Writer)
    check not keepsDacl(Someone, 1, true, restricted, Writer)  # planted
    check not keepsDacl(Admins, 2, true, restricted, Writer)   # hard link
    check not keepsDacl(Admins, 1, false, restricted, Writer)  # NULL DACL
    for mask in [0x2'u32, 0x4'u32, 0x40000000'u32, 0x1F01FF'u32]:
      check not keepsDacl(Admins, 1, true,
        [AceView(allow: true, sid: Everyone, mask: mask)], Writer)
    check not keepsDacl(Admins, 1, true,
      [AceView(unknown: true, aceType: 11)], Writer)
    # A deny ACE grants nothing; an inherit-only ACE is not this folder's.
    check untrustedReason(Admins, true,
      [AceView(allow: false, sid: Everyone, mask: 0x1F01FF),
       AceView(allow: true, inheritOnly: true, sid: Everyone,
               mask: 0x1F01FF)], Writer) == ""

  test "macOS: /etc is walked as /private/etc, nothing else is rewritten":
    check systemFileHostPath("/etc/x.conf", darwin = true) ==
      "/private/etc/x.conf"
    check systemFileHostPath("/usr/local/etc/x", darwin = true) ==
      "/usr/local/etc/x"
    check systemFileHostPath("/etc/x.conf", darwin = false) == "/etc/x.conf"

  test "the trust check starts at the allowlist root the path is under":
    check systemFileTrustRoot("/etc/app/x.conf") == "/etc"
    check systemFileTrustRoot("/private/etc/x.conf") == "/private/etc"
    check systemFileTrustRoot("/usr/local/etc/a/b") == "/usr/local/etc"

# ---------------------------------------------------------------------------
# The driver, as root, in a throwaway root filesystem.
# ---------------------------------------------------------------------------

when defined(linux):
  proc c_unshare(flags: cint): cint {.importc: "unshare", header: "<sched.h>".}
  proc c_mount(src, target, fstype: cstring; flags: culong;
               data: cstring): cint {.importc: "mount", header: "<sys/mount.h>".}
  proc c_chroot(path: cstring): cint {.importc: "chroot", header: "<unistd.h>".}

  const
    CloneNewUser = 0x1000_0000.cint
    CloneNewNs = 0x0002_0000.cint
    MsRec = 16384.culong
    MsPrivate = (1 shl 18).culong
    NamespacesUnavailable = 77

  proc sysFile(path, content: string; destroy = false): PrivilegedOperation =
    PrivilegedOperation(kind: pokFsSystemFile, address: "fs.systemFile:" & path,
      sfPath: path, sfContent: content, sfDestroy: destroy)

  proc refusal(op: PrivilegedOperation): string =
    ## The driver's refusal message, or "" when it wrote.
    try:
      discard applyFsSystemFile(FixtureContext(), op)
      ""
    except EProtocol as e:
      e.msg

  proc fail(msg: string) {.noreturn.} =
    stderr.writeLine("jail case failed: " & msg)
    exitnow(1)

  proc ensure(cond: bool; msg: string) =
    if not cond: fail(msg)

  proc enterJail(jail: string) =
    ## Become root of a new user namespace, mount a tmpfs at ``jail`` in a
    ## private mount namespace, and make it ``/``.
    let uid = getuid()
    let gid = getgid()
    if c_unshare(CloneNewUser or CloneNewNs) != 0:
      stderr.writeLine("unshare(CLONE_NEWUSER|CLONE_NEWNS): " &
        osErrorMsg(osLastError()))
      exitnow(NamespacesUnavailable)
    writeFile("/proc/self/setgroups", "deny")
    writeFile("/proc/self/uid_map", "0 " & $uid & " 1")
    writeFile("/proc/self/gid_map", "0 " & $gid & " 1")
    ensure c_mount(nil, "/", nil, MsRec or MsPrivate, nil) == 0, "make / private"
    ensure c_mount("tmpfs", jail.cstring, "tmpfs", 0, "mode=0755") == 0,
      "mount tmpfs: " & osErrorMsg(osLastError())
    for d in ["etc", "usr/local/etc", "outside/dir"]:
      createDir(jail / d)
    writeFile(jail / "outside/victim", "victim\n")
    ensure c_chroot(jail.cstring) == 0, "chroot: " & osErrorMsg(osLastError())
    ensure chdir("/") == 0, "chdir /"

  proc inJail(body: proc ()): int =
    ## Run ``body`` in a forked child inside a fresh jail; its exit status.
    let jail = getTempDir() / ("repro-fs-system-file-jail-" &
      $getCurrentProcessId())
    createDir(jail)
    defer: removeDir(jail)
    let pid = fork()
    if pid == 0:
      try:
        enterJail(jail)
        body()
      except CatchableError as e:
        fail($e.name & ": " & e.msg)
      exitnow(0)
    var status: cint
    discard waitpid(pid, status, 0)
    if WIFEXITED(status): int(WEXITSTATUS(status)) else: -1

  template jailCase(body: untyped): int =
    ## Run ``body`` as root over a throwaway ``/etc`` (``inJail``) and
    ## return the child's exit status: 0 when every ``ensure`` held. On a
    ## kernel that refuses an unprivileged user namespace the enclosing
    ## test is skipped here, with the reason, and the status is
    ## ``NamespacesUnavailable``; the test then checks for either.
    let rc = inJail(proc () = body)
    if rc == NamespacesUnavailable:
      skip("this kernel refuses an unprivileged user namespace, so " &
           "the driver cannot be run as root over a throwaway /etc")
    rc

  proc mode(path: string): int =
    var st: Stat
    doAssert lstat(path.cstring, st) == 0, path
    int(st.st_mode) and 0o7777

  suite "fs.systemFile as root over a real /etc":
    test "a plain write lands, with its directories, mode 0644, atomically":
      let rc = jailCase:
        ensure refusal(sysFile("/etc/app/sub/a.conf", "hello\n")) == "",
          "the write was refused"
        ensure readFile("/etc/app/sub/a.conf") == "hello\n", "content"
        ensure mode("/etc/app/sub/a.conf") == 0o644, "mode"
        for f in walkDir("/etc/app/sub"):
          ensure f.path == "/etc/app/sub/a.conf", "left behind: " & f.path
        ensure refusal(sysFile("/etc/app/sub/a.conf", "again\n")) == "",
          "the rewrite was refused"
        ensure readFile("/etc/app/sub/a.conf") == "again\n", "rewritten content"
      check rc in [0, NamespacesUnavailable]

    test "a link as the file is refused and its target is untouched":
      let rc = jailCase:
        createSymlink("/outside/victim", "/etc/leaf.conf")
        let why = refusal(sysFile("/etc/leaf.conf", "redirected\n"))
        ensure "symbolic link" in why and "/etc/leaf.conf" in why, why
        ensure readFile("/outside/victim") == "victim\n", "victim changed"
        ensure symlinkExists("/etc/leaf.conf"), "the link went away"
      check rc in [0, NamespacesUnavailable]

    test "a link as a directory on the path is refused, naming it":
      let rc = jailCase:
        createSymlink("/outside/dir", "/etc/linked")
        let why = refusal(sysFile("/etc/linked/x.conf", "redirected\n"))
        ensure "symbolic link" in why and "/etc/linked" in why, why
        ensure not fileExists("/outside/dir/x.conf"), "written through the link"
      check rc in [0, NamespacesUnavailable]

    test "a world-writable directory under /etc is refused, naming it":
      let rc = jailCase:
        createDir("/etc/open")
        setFilePermissions("/etc/open", {fpUserRead, fpUserWrite, fpUserExec,
          fpGroupRead, fpGroupWrite, fpGroupExec, fpOthersRead, fpOthersWrite,
          fpOthersExec})
        let why = refusal(sysFile("/etc/open/x.conf", "content\n"))
        ensure "refuses to write under /etc/open" in why, why
        ensure not fileExists("/etc/open/x.conf"), "written anyway"
      check rc in [0, NamespacesUnavailable]

    test "a world-writable ancestor of an allowlisted root is refused":
      let rc = jailCase:
        # /usr/local/etc itself is root's, but whoever can write /usr/local
        # can move it aside and put their own directory in its place.
        ensure chmod("/usr/local", Mode(0o777)) == 0, "chmod /usr/local"
        let why = refusal(sysFile("/usr/local/etc/x.conf", "content\n"))
        ensure "refuses to write under /usr/local" in why, why
        ensure not fileExists("/usr/local/etc/x.conf"), "written anyway"
      check rc in [0, NamespacesUnavailable]

    test "an allowlisted root an ordinary user can write is refused":
      let rc = jailCase:
        # Intel Homebrew hands /usr/local/etc to the installing user; a
        # root-owned file written there is still under that user's control.
        ensure chmod("/usr/local/etc", Mode(0o777)) == 0, "chmod /usr/local/etc"
        let why = refusal(sysFile("/usr/local/etc/x.conf", "content\n"))
        ensure "refuses to write under /usr/local/etc" in why, why
        ensure not fileExists("/usr/local/etc/x.conf"), "written anyway"
      check rc in [0, NamespacesUnavailable]

    test "a directory writable by root's group is trusted":
      let rc = jailCase:
        createDir("/etc/wheel")
        ensure chmod("/etc/wheel", Mode(0o775)) == 0, "chmod /etc/wheel"
        ensure refusal(sysFile("/etc/wheel/x.conf", "content\n")) == "",
          "refused"
        ensure readFile("/etc/wheel/x.conf") == "content\n", "content"
      check rc in [0, NamespacesUnavailable]

    test "destroy removes the file, and never through a link":
      let rc = jailCase:
        ensure refusal(sysFile("/etc/gone.conf", "x\n")) == "", "write refused"
        ensure refusal(sysFile("/etc/gone.conf", "", destroy = true)) == "",
          "destroy refused"
        ensure not fileExists("/etc/gone.conf"), "still there"
        writeFile("/outside/dir/kept.conf", "kept\n")
        createSymlink("/outside/dir", "/etc/linked2")
        let why = refusal(sysFile("/etc/linked2/kept.conf", "", destroy = true))
        ensure "symbolic link" in why, why
        ensure readFile("/outside/dir/kept.conf") == "kept\n", "removed through"
      check rc in [0, NamespacesUnavailable]
else:
  suite "fs.systemFile as root over a real /etc":
    test "the driver cases need Linux namespaces":
      skip("the throwaway /etc is built with Linux user and mount " &
           "namespaces. The Windows driver runs in tests/windows/" &
           "windows_fs_system_file_never_follows_reparse_points.nim; the " &
           "macOS driver shares the POSIX writer run here on Linux, but " &
           "nothing runs it on macOS")
