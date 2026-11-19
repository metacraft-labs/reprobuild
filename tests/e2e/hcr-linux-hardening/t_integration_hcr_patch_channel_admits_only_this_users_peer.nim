## Property: the HCR patch channel on Linux and macOS admits only a peer that
## runs as this user, and a derived agent socket never sits directly in a
## shared temporary directory.
##
## The channel carries executable code that the agent writes into the target
## process. A socket path is not an identity: whoever binds or reaches the
## name first answers on it. So both ends check the kernel's record of the
## peer (``SO_PEERCRED`` / ``getpeereid``) before any frame crosses, and the
## short path that replaces an over-long relative ``--hcr-agent-socket`` lives
## in a private ``0700`` per-user directory. reprobuild-pm
## ``spec/HCR/HCR-Overview.md`` §5.2 "Who may use the channel" and
## ``spec/HCR/CLI-Integration.md`` §"Agent Socket Path"; the defect was
## reprobuild-pm ``issues/2026-11-12-patch-channel-who-listens-where-and-with-what-authentication.md``.
##
## No mocks. The hostile peer is a real process of another account (uid
## 65534), forked from this one and ``setuid``. The coordinator and agent ends
## are the production code: ``repro_hcr_agent/ipc`` and
## ``libs/repro_hcr_agent/c/repro_hcr_agent.c``.
##
## WHERE THE SECOND UID COMES FROM. The kernel reports a peer's uid from its
## credentials, so the only way to make it report another one is to have a
## process that really runs as another uid. As root the test simply forks and
## ``setuid``s. On Linux, not as root (every HCR lane), the test re-executes
## itself in a user namespace, through ``unshare --map-root-user`` plus one
## subordinate uid and gid from ``/etc/subuid`` / ``/etc/subgid`` mapped to
## 65534 (``newuidmap`` / ``newgidmap`` do the privileged part). Inside it the
## test is root and 65534 is a real, distinct kernel uid, so the three attack
## cases run unchanged. A Linux host that cannot provide that namespace
## skips them with a ``HCR-CONDITIONS-NOT-MET:`` line, which the HCR lane
## reports as NO VERDICT rather than as a pass
## (``scripts/lib/hcr_lane_verdict.sh``). On macOS there is no such namespace,
## so a non-root run skips them with the loud UNSUPPORTED line naming the
## Linux lane; the two directory cases run everywhere POSIX.

import std/[net, os, osproc, streams, strtabs, strutils, unittest]
import repro_test_support/reasoned_skip

when defined(posix):
  import std/posix
  from repro_test_support/process_fixtures import shortSocketDirAtProcessExit
  from repro_test_support import announceHcrUnsupportedHost
  import repro_hcr_agent
  import repro_core/owned_directory

  const HostileUid = 65534

  const GateName = "integration_hcr_patch_channel_admits_only_this_users_peer"

  let isRoot = geteuid() == 0
  const NeedsRoot =
    "creating a peer of another uid needs root (setuid); this run is not root"

  var noHostileUidReason = NeedsRoot
    ## Why the attack cases cannot run here; refined below on Linux.

when defined(linux):
  const InUserNamespaceEnv = "REPRO_HCR_PEER_TEST_IN_USERNS"
    ## Set in the re-executed child so it never tries to nest again.

  proc firstSubordinateId(file, name: string; id: int): int =
    ## The first id of this account's range in ``/etc/subuid`` or
    ## ``/etc/subgid`` (``name:start:count`` or ``id:start:count``), or -1.
    ## Format: subuid(5).
    try:
      for line in lines(file):
        let fields = line.strip().split(':')
        if fields.len == 3 and (fields[0] == name or fields[0] == $id) and
            parseInt(fields[2]) >= 1:
          return parseInt(fields[1])
    except IOError, OSError, ValueError:
      discard
    -1

  proc runInUserNamespace(): int =
    ## Re-execute this test binary as root of a fresh user namespace in which
    ## ``HostileUid`` maps to one of this account's subordinate ids. Returns
    ## the child's exit code, or -1 (with ``noHostileUidReason`` set) when the
    ## host cannot provide the namespace.
    let unshareExe = findExe("unshare")
    if unshareExe.len == 0:
      noHostileUidReason = NeedsRoot & ", and `unshare` is not on PATH to " &
        "create a user namespace instead"
      return -1
    let pw = getpwuid(geteuid())
    let name = if pw.isNil: "" else: $pw.pw_name
    let subUid = firstSubordinateId("/etc/subuid", name, int(geteuid()))
    let subGid = firstSubordinateId("/etc/subgid", name, int(getegid()))
    if subUid < 0 or subGid < 0:
      noHostileUidReason = NeedsRoot & ", and this account has no " &
        "subordinate uid/gid range in /etc/subuid and /etc/subgid to map " &
        "uid " & $HostileUid & " in a user namespace"
      return -1
    let nsArgs = @["--map-root-user",
      "--map-users=" & $HostileUid & ":" & $subUid & ":1",
      "--map-groups=" & $HostileUid & ":" & $subGid & ":1", "--"]
    let probe = execCmdEx(quoteShellCommand(@[unshareExe] & nsArgs & @["true"]))
    if probe.exitCode != 0:
      noHostileUidReason = NeedsRoot & ", and a user namespace mapping uid " &
        $HostileUid & " could not be created (" & unshareExe & " exited " &
        $probe.exitCode & ": " & probe.output.strip() & ")"
      return -1
    putEnv(InUserNamespaceEnv, "1")
    flushFile(stdout); flushFile(stderr)
    let child = startProcess(unshareExe,
      args = nsArgs & @[getAppFilename()] & commandLineParams(),
      options = {poParentStreams})
    result = child.waitForExit()
    child.close()

  if not isRoot and getEnv(InUserNamespaceEnv).len == 0:
    let code = runInUserNamespace()
    if code >= 0:
      quit(code)

when defined(posix):
  template skipWithoutHostileUid(caseName: string) =
    ## Skip an attack case that has no second uid to attack with, in the
    ## form the HCR lane reads (scripts/lib/hcr_lane_verdict.sh).
    when defined(linux):
      echo "HCR-CONDITIONS-NOT-MET: " & GateName & ": " & caseName & ": " &
        noHostileUidReason
    else:
      announceHcrUnsupportedHost(GateName & ": " & caseName,
        "Linux x86_64, or root", "the linux-x86_64 HCR lane")
    skip(noHostileUidReason)

  proc unixAddr(path: string): Sockaddr_un =
    result.sun_family = TSa_Family(AF_UNIX)
    doAssert path.len < result.sun_path.len
    for i, ch in path:
      result.sun_path[i] = ch

  proc setgroups(size: csize_t; list: ptr Gid): cint {.
    importc, header: "<grp.h>".}

  proc becomeHostile() =
    # Drop root's supplementary groups first, so the child is uid 65534 and
    # nothing else.
    if setgroups(0, nil) != 0 or setgid(Gid(HostileUid)) != 0 or
        setuid(Uid(HostileUid)) != 0:
      exitnow(90)

  proc countUntilEof(fd: cint): int =
    ## Bytes the peer sent before it closed, waiting at most 5 s for each.
    var buf: array[4096, char]
    while true:
      var pfd = TPollfd(fd: fd, events: POLLIN)
      if poll(addr pfd, 1, 5000) <= 0:
        return result
      let n = read(fd, addr buf[0], buf.len)
      if n <= 0:
        return result
      result += n

  proc report(fd: cint; value: int) =
    let text = $value & "\n"
    discard write(fd, text.cstring, text.len)

  proc readReport(fd: cint): int =
    var buf: array[64, char]
    var text = ""
    while true:
      let n = read(fd, addr buf[0], buf.len)
      if n <= 0: break
      for i in 0 ..< n: text.add buf[i]
    parseInt(text.strip())

  proc waitChild(pid: Pid): cint =
    var status: cint
    discard waitpid(pid, status, 0)
    status

  proc hostileListener(path: string): tuple[pid: Pid, reportFd: cint] =
    ## A process of uid 65534 listening on ``path``. It accepts one
    ## connection and reports how many bytes arrived on it before EOF.
    var ready, rep: array[2, cint]
    doAssert pipe(ready) == 0 and pipe(rep) == 0
    var a = unixAddr(path) # before fork: a failed assert must not run in the child
    flushFile(stdout); flushFile(stderr)
    let pid = fork()
    if pid == 0:
      discard close(ready[0]); discard close(rep[0])
      becomeHostile()
      let s = socket(AF_UNIX, SOCK_STREAM, 0)
      if bindSocket(SocketHandle(s), cast[ptr SockAddr](addr a),
          SockLen(sizeof(a))) != 0: exitnow(91)
      if listen(SocketHandle(s), 1) != 0: exitnow(92)
      discard write(ready[1], "r".cstring, 1)
      let c = accept(SocketHandle(s), nil, nil)
      if c.cint < 0: exitnow(93)
      report(rep[1], countUntilEof(c.cint))
      exitnow(0)
    discard close(ready[1]); discard close(rep[1])
    var b: char
    doAssert read(ready[0], addr b, 1) == 1, "hostile listener did not start"
    discard close(ready[0])
    (pid, rep[0])

  proc hostileClient(path: string): tuple[pid: Pid, reportFd: cint] =
    ## A process of uid 65534 that connects to ``path`` and reports how many
    ## bytes it was sent before EOF.
    var rep: array[2, cint]
    doAssert pipe(rep) == 0
    var a = unixAddr(path) # before fork: a failed assert must not run in the child
    flushFile(stdout); flushFile(stderr)
    let pid = fork()
    if pid == 0:
      discard close(rep[0])
      becomeHostile()
      let s = socket(AF_UNIX, SOCK_STREAM, 0)
      if connect(SocketHandle(s), cast[ptr SockAddr](addr a),
          SockLen(sizeof(a))) != 0: exitnow(94)
      report(rep[1], countUntilEof(s.cint))
      exitnow(0)
    discard close(rep[1])
    (pid, rep[0])

  proc openTo(path: string; mode: int) =
    doAssert chmod(path.cstring, Mode(mode)) == 0

suite "HCR patch channel admits only this user's peer":
  test "the coordinator refuses an agent that runs as another user":
    when defined(posix):
      if not isRoot:
        skipWithoutHostileUid("the coordinator refuses an agent that runs as another user")
      else:
        let dir = shortSocketDirAtProcessExit("hcp-")
        let path = dir / "c.sock"
        var listener = listenHcrAgentUnixSocket(path)
        defer: listener.close()
        # The explicit-path case: a socket another account can reach.
        openTo(dir, 0o711)
        openTo(path, 0o777)
        let (pid, reportFd) = hostileClient(path)
        # Fail rather than hang in accept if the hostile client never connects.
        var pfd = TPollfd(fd: listener.socket.getFd().cint, events: POLLIN)
        require poll(addr pfd, 1, 10_000) == 1
        var message = ""
        try:
          discard listener.acceptHcrAgentConnection()
        except HcrAgentPeerError as err:
          message = err.msg
        check message.contains("runs as uid " & $HostileUid)
        check message.contains("not as this user")
        check readReport(reportFd) == 0
        discard close(reportFd)
        check waitChild(pid) == 0
    else:
      skip("the Unix-socket channel exists on Linux and macOS only")

  test "an agent refuses a coordinator that runs as another user":
    when defined(posix):
      if not isRoot:
        skipWithoutHostileUid("an agent refuses a coordinator that runs as another user")
      else:
        let dir = shortSocketDirAtProcessExit("hcp-")
        openTo(dir, 0o777)
        let path = dir / "s.sock"
        let (pid, reportFd) = hostileListener(path)
        var message = ""
        try:
          discard connectHcrAgentUnixSocket(path)
        except HcrAgentPeerError as err:
          message = err.msg
        check message.contains("runs as uid " & $HostileUid)
        check readReport(reportFd) == 0
        discard close(reportFd)
        check waitChild(pid) == 0
    else:
      skip("the Unix-socket channel exists on Linux and macOS only")

  test "the C agent sends nothing to a coordinator that runs as another user":
    when defined(linux):
      if not isRoot:
        skipWithoutHostileUid("the C agent sends nothing to a coordinator that runs as another user")
      elif findExe("gcc").len == 0:
        skip("gcc is needed to build a target with the C agent and is not on PATH")
      else:
        let repoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
        let agentDir = repoRoot / "libs" / "repro_hcr_agent" / "c"
        let dir = shortSocketDirAtProcessExit("hcp-")
        let bin = dir / "target"
        let build = execCmdEx(quoteShellCommand(["gcc", "-O1",
          "-I", agentDir, "-o", bin,
          currentSourcePath().parentDir / "hcr_peer_target.c",
          agentDir / "repro_hcr_agent.c", "-lpthread"]))
        check build.exitCode == 0
        if build.exitCode != 0:
          echo build.output
        else:
          openTo(dir, 0o777)
          let path = dir / "s.sock"
          let (pid, reportFd) = hostileListener(path)
          let p = startProcess(bin, args = [HcrLinuxX86_64DirectSupportProfile],
            env = newStringTable({ReproHcrAgentSocketEnv: path,
              "PATH": getEnv("PATH")}),
            options = {poStdErrToStdOut})
          let output = p.outputStream.readAll()
          let code = p.waitForExit()
          p.close()
          check code == 0
          check output.contains("refusing the HCR coordinator listening on " & path)
          check output.contains("runs as uid " & $HostileUid)
          check output.contains("session_open=0")
          # Nothing, not even the hello, reached the foreign listener.
          check readReport(reportFd) == 0
          discard close(reportFd)
          check waitChild(pid) == 0
    else:
      when defined(posix):
        announceHcrUnsupportedHost(GateName & ": the C agent case",
          "Linux x86_64", "the linux-x86_64 HCR lane")
      skip("the C agent's Unix-socket target is built here on Linux only")

  test "a derived agent socket lives in this user's private directory":
    when defined(posix):
      let root = shortSocketDirAtProcessExit("hcp-")
      let resolved = "/a/long/project/root/" & repeat("x", 80) & "/.repro/hcr/agent.sock"
      let derived = hcrAgentDerivedSocketPath(resolved, root)
      check derived.parentDir == hcrAgentPrivateSocketDir(root)
      check derived.parentDir == root / ("repro-hcr-" & $int(geteuid()))
      check derived.extractFilename.len == 16 + ".sock".len
      check hcrAgentDerivedSocketPath(resolved & "2", root) != derived
      admitHcrAgentPrivateSocketDir(root)
      var st: Stat
      check lstat(derived.parentDir.cstring, st) == 0
      check (int(st.st_mode) and 0o777) == 0o700
      check int(st.st_uid) == int(geteuid())
      # Admitting it again is a no-op.
      admitHcrAgentPrivateSocketDir(root)
    else:
      skip("the Unix-socket channel exists on Linux and macOS only")

  test "a planted or widened per-user socket directory is refused, not repaired":
    when defined(posix):
      let root = shortSocketDirAtProcessExit("hcp-")
      let dir = hcrAgentPrivateSocketDir(root)
      createDir(dir)
      openTo(dir, 0o755)
      expect OwnedDirectoryError:
        admitHcrAgentPrivateSocketDir(root)
      var st: Stat
      check lstat(dir.cstring, st) == 0
      check (int(st.st_mode) and 0o777) == 0o755
      if isRoot:
        openTo(dir, 0o700)
        doAssert chown(dir.cstring, Uid(HostileUid), Gid(HostileUid)) == 0
        var message = ""
        try:
          admitHcrAgentPrivateSocketDir(root)
        except OwnedDirectoryError as err:
          message = err.msg
        check message.contains("owned by uid " & $HostileUid)
        removeDir(dir)
        createSymlink(root, dir)
        expect OwnedDirectoryError:
          admitHcrAgentPrivateSocketDir(root)
    else:
      skip("the Unix-socket channel exists on Linux and macOS only")
