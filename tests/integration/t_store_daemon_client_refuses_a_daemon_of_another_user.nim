## A dev store-daemon client trusts only a daemon run by its own user, and its
## default endpoint lives in a directory no other account can own.
##
## THE ATTACK. Before this was fixed, ``connectDevDaemon`` connected to
## whatever listened on the predictable default endpoint and believed every
## answer, and with ``XDG_RUNTIME_DIR`` unset that endpoint was
## ``$TMPDIR/reprostore-<uid>.sock`` -- straight in a shared temporary
## directory (``/tmp``) that every local account can create entries in. A
## second local user binds that path first and answers the handshake and a
## realize with a ``realizedPrefixPath`` of their choosing; the victim's
## launchers then run the attacker's files. (reprobuild-pm
## ``issues/2026-11-12-dev-store-daemon-clients-never-authenticate-the-daemon-and-the-endpoint-can-fall-into-tmp.md``.)
##
## THE RULES ASSERTED are reprobuild-pm
## ``spec/Store-Daemon-And-Multi-User-Coordination.md`` §"IPC Protocol":
## "Development socket paths", "The per-user endpoint directory is private"
## and "A client authenticates the daemon", and ``spec/CLI/store/daemon.md``
## §"Development Store Mode":
##
##   (a) an attacker who reaches the default endpoint first gets nothing used:
##       the victim's realize raises the refusal, naming both uids, and never
##       returns the attacker's path; the fallback realize goes direct;
##   (b) an explicit ``REPROSTORED_ENDPOINT`` is used verbatim and its
##       directory is NOT checked, but the kernel's peer credentials still
##       are: a socket another uid listens on is refused before ``Hello`` is
##       sent (the attacker's log proves it received nothing);
##   (c) the status of an endpoint another account holds is a refusal, never
##       "not running" -- through ``queryDevStatus`` and through
##       ``repro store daemon status --dev``, which exits non-zero;
##   (d) the ``reprostore-<uid>/`` directory is admitted only when ``lstat``
##       says it is a real directory, owned by this user, with no group or
##       other bits; a foreign one, a ``0750`` one and a symlink in its place
##       are each refused, by the client and by the daemon, naming the
##       directory, its owner and its mode, and are never repaired; a
##       directory that cannot be created at all is an absent daemon, not a
##       refusal;
##   (e) positive control: a real dev daemon of the same user, started on the
##       default endpoint, is reached through that endpoint; the directory it
##       created is ``0700`` and holds both the socket and the status file.
##
## A REAL SECOND OS USER, NOT A FAKE ONE. The attacker must be a different
## kernel uid, because the property under test is exactly what the KERNEL
## reports about the listener (``SO_PEERCRED``). So the binary re-executes
## itself under ``unshare --user --map-root-user --map-auto``: inside, this
## account is uid 0 and the subordinate range is mapped to uids 1..65536.
## Each attacker is a ``fork`` of this process that drops to uid/gid 1 with
## ``setresgid``/``setresuid`` and checks that it did -- a genuinely different
## uid to the kernel, owning every file it creates. The victim is this
## process (uid 0 in the namespace, the real user outside). Being root in the
## namespace lets the victim enter the attacker's directories, which a real
## victim could not; that only ever makes the attack EASIER, so it cannot make
## a case pass that should fail. Where user namespaces or subordinate ids are
## unavailable the cases skip, naming why.
##
## MOCK POLICY. The attacker's server is a forged daemon, and that is the
## point of the test, not a substitute for a collaborator: it is the hostile
## party the issue describes, speaking the real wire protocol through the
## product's own framing (``writeFrame``/``helloAckBody``/...), on a real
## AF_UNIX socket bound by the real ``bindIpcListener``, as a real other uid.
## Everything on the victim's side is production code: ``connectDevDaemon``,
## ``realizeSyntheticViaDaemon``, ``realizeSyntheticWithFallback``,
## ``queryDevStatus``, ``runDevDaemonForeground`` and the ``repro`` CLI.
##
## THE ``/tmp`` CONDITION is recreated in a fresh mode-``1777`` directory under
## ``/tmp`` used as ``TMPDIR``, with ``XDG_RUNTIME_DIR``,
## ``REPROSTORED_ENDPOINT`` and the other temp variables unset. Nothing is
## bound in the real ``/tmp``.
##
## Linux only: macOS's ``getpeereid`` path and Windows' named-pipe owner SID
## cannot be exercised on a Linux host, and macOS has no user namespaces.

import repro_test_support/reasoned_skip
import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

when defined(linux):
  import std/posix
  import repro_store_daemon

  const
    InUsernsEnv = "REPRO_T_STORE_PEER_IN_USERNS"
      ## Set on the re-executed copy that runs inside the user namespace.
    AttackerId = 1
      ## The uid and gid the attacker drops to inside the namespace.
    ScrubbedVars = ["XDG_RUNTIME_DIR", "REPROSTORED_ENDPOINT", "TMPDIR",
      "TEMP", "TMP", "TEMPDIR"]
    RealizationA =
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  proc setresuid(r, e, s: Uid): cint {.importc, header: "<unistd.h>".}
  proc setresgid(r, e, s: Gid): cint {.importc, header: "<unistd.h>".}
  proc setgroups(size: csize_t; list: ptr Gid): cint {.
    importc, header: "<grp.h>".}

  var usernsUnavailable = ""
    ## Why the cases cannot run here; empty when they can.

  if getEnv(InUsernsEnv) != "1":
    # Re-execute under a user namespace with subordinate ids mapped, so that
    # the attacker can be a different kernel uid. The outer process runs no
    # test and writes nothing; the inner one answers every runner flag.
    let unshare = findExe("unshare")
    let probe =
      if unshare.len == 0: (output: "unshare is not on PATH", exitCode: 127)
      else: execCmdEx(quoteShellCommand([unshare, "--user",
        "--map-root-user", "--map-auto", "true"]))
    if probe.exitCode == 0:
      putEnv(InUsernsEnv, "1")
      let inner = startProcess(unshare, args = @["--user", "--map-root-user",
        "--map-auto", "--", getAppFilename()] & commandLineParams(),
        options = {poParentStreams})
      quit(inner.waitForExit())
    usernsUnavailable = "needs a Linux user namespace with subordinate " &
      "uid/gid ranges (`unshare --user --map-root-user --map-auto`) to run " &
      "the attacker as a second real uid; the probe failed: " &
      probe.output.strip()

  proc victimUid(): int = int(geteuid())

  type
    Scratch = object
      tmp: string       ## the mode-1777 stand-in for ``/tmp`` (``TMPDIR``)
      storeRoot: string ## the victim's store root
      saved: seq[(string, bool, string)]

  proc newScratch(): Scratch =
    ## A fresh sticky world-writable directory under ``/tmp`` used as
    ## ``TMPDIR``, with every other variable the endpoint derivation reads
    ## unset; ``dispose`` restores them.
    result.tmp = createTempDir("rsp-", "", "/tmp")
    doAssert chmod(result.tmp.cstring, Mode(0o1777)) == 0
    result.storeRoot = result.tmp / "victim-store"
    for name in ScrubbedVars:
      result.saved.add((name, existsEnv(name), getEnv(name)))
      delEnv(name)
    putEnv("TMPDIR", result.tmp)

  proc dispose(s: Scratch) =
    for (name, wasSet, value) in s.saved:
      if wasSet: putEnv(name, value) else: delEnv(name)
    try: removeDir(s.tmp) except OSError: discard

  proc privateDir(s: Scratch): string =
    ## The directory the spec says the default endpoint lives in, stated
    ## here independently of the product's derivation.
    s.tmp / ("reprostore-" & $victimUid())

  proc expectedDefaultEndpoint(s: Scratch): string =
    s.privateDir / ("reprostore-" & $victimUid() & ".sock")

  proc syntheticReq(s: Scratch): SyntheticRealizeRequest =
    SyntheticRealizeRequest(storeRoot: s.storeRoot,
      realizationIdHex: RealizationA, packageName: "peer-check",
      version: "1.0.0", payload: "the victim's own payload\n",
      holderId: "holder-a", rootId: "root-a")

  type
    Attacker = object
      pid: Pid
      endpoint: string
      forgedPath: string ## the prefix the attacker wants the victim to run
      log: string        ## one line per frame the attacker received

  proc becomeAttacker() =
    ## Drop this (forked) process to the attacker's uid and gid, for good.
    if setgroups(0, nil) != 0 or
        setresgid(Gid(AttackerId), Gid(AttackerId), Gid(AttackerId)) != 0 or
        setresuid(Uid(AttackerId), Uid(AttackerId), Uid(AttackerId)) != 0 or
        getuid() != Uid(AttackerId) or geteuid() != Uid(AttackerId):
      stderr.writeLine("attacker: cannot become uid " & $AttackerId & ": " &
        $strerror(errno))
      exitnow(97)

  proc serveForged(a: Attacker; ready: cint) =
    ## The hostile daemon: answer every handshake with a forged dev-profile
    ## ``HelloAck`` and every status or realize with forged data. Signals
    ## ``ready`` once the endpoint accepts connections (``bindIpcListener``
    ## publishes it only after ``listen``).
    var listener = bindIpcListener(a.endpoint)
    discard chmod(a.endpoint.cstring, Mode(0o777))
    var token = 'r'
    discard posix.write(ready, addr token, 1)
    discard posix.close(ready)
    while true:
      var conn = listener.acceptIpc()
      try:
        let hello = conn.readFrame()
        writeFile(a.log, readFile(a.log) & $hello.kind & "\n")
        conn.writeFrame(sdkHelloAck,
          helloAckBody(StoreDaemonProfileDev, "/attacker/store", 4242))
        let req = conn.readFrame()
        writeFile(a.log, readFile(a.log) & $req.kind & "\n")
        case req.kind
        of sdkStatus:
          conn.writeFrame(sdkStatusResponse, statusBody(StoreDaemonStatus(
            running: true, protocolVersion: StoreDaemonProtocolVersion,
            daemonProfile: StoreDaemonProfileDev, endpoint: a.endpoint,
            storeRoot: "/attacker/store", pid: 4242)))
        else:
          conn.writeFrame(sdkRealizeResponse, realizeResponseBody(
            StoreDaemonRealizeResult(status: "realized",
              realizedPrefixPath: a.forgedPath,
              realizationHashHex: RealizationA, rootId: "attacker",
              writerMode: "daemon", installMethod: "synthetic",
              selectedStorePath: a.forgedPath)))
      except CatchableError:
        discard
      conn.closeIpcConn()

  proc startAttacker(endpoint, workDir: string;
                     dirMode = 0o700): Attacker =
    ## Fork an attacker that, as uid ``AttackerId``, creates ``workDir`` and
    ## the endpoint's directory (``dirMode``) where they are missing, plants a
    ## prefix of its own, binds ``endpoint`` and serves forged answers.
    ## Returns once it listens.
    result.endpoint = endpoint
    result.forgedPath = workDir / "attacker-prefix"
    result.log = workDir / "attacker-received.log"
    var ready: array[2, cint]
    doAssert pipe(ready) == 0
    let pid = fork()
    doAssert pid >= 0
    if pid == 0:
      discard posix.close(ready[0])
      try:
        becomeAttacker()
        for dir in [workDir, parentDir(endpoint)]:
          if not dirExists(dir):
            createDir(dir)
            discard chmod(dir.cstring, Mode(dirMode))
        createDir(result.forgedPath / "bin")
        writeFile(result.forgedPath / "bin" / "tool",
          "#!/bin/sh\necho attacker code runs as the victim\n")
        writeFile(result.log, "")
        serveForged(result, ready[1])
      except CatchableError as err:
        stderr.writeLine("attacker failed: " & err.msg)
      exitnow(0)
    discard posix.close(ready[1])
    var token: char
    let n = posix.read(ready[0], addr token, 1)
    discard posix.close(ready[0])
    if n != 1:
      var status: cint
      discard waitpid(pid, status, 0)
    doAssert n == 1, "the attacker never started listening on " & endpoint
    result.pid = pid

  proc stop(a: Attacker) =
    discard kill(a.pid, SIGKILL)
    var status: cint
    discard waitpid(a.pid, status, 0)

  proc daemonRefusal(config: DevDaemonConfig): string =
    ## Run the real ``runDevDaemonForeground`` in a child of this user and
    ## return why it refused to start, or ``"started"`` when it began serving
    ## (it is then stopped). A child, so a daemon that wrongly starts cannot
    ## hang the test.
    let why = getTempDir() / "daemon-refusal.txt"
    removeFile(why)
    let pid = fork()
    doAssert pid >= 0
    if pid == 0:
      var rc = 0
      try:
        rc = runDevDaemonForeground(config)
        writeFile(why, "returned " & $rc)
      except CatchableError as err:
        writeFile(why, err.msg)
      exitnow(0)
    var status: cint
    for _ in 0 ..< 400:
      if waitpid(pid, status, WNOHANG) == pid:
        return readFile(why)
      sleep(25)
    discard kill(pid, SIGKILL)
    discard waitpid(pid, status, 0)
    "started"

  proc attackerReceived(a: Attacker): string =
    try: readFile(a.log).strip() except IOError: "<no log>"

  proc refusalOf(body: proc ()): ref CatchableError =
    ## The exception ``body`` raised, or nil when it returned.
    try:
      body()
    except CatchableError as err:
      return err
    nil

  proc isEndpointRefusal(err: ref CatchableError): bool =
    ## A refusal of the endpoint (an account that is not this user holds it),
    ## distinct from a daemon that is merely absent. Checked by the
    ## exception's type name so this file compiles against a client that
    ## predates the type, which is what lets it be run red.
    err != nil and $err.name == "StoreDaemonEndpointRefused"

  proc modeOf(path: string): int =
    var info: Stat
    if lstat(path.cstring, info) != 0:
      return -1
    int(info.st_mode) and 0o7777

  proc reproCli(): string =
    getCurrentDir() / "build" / "bin" / addFileExt("repro", ExeExt)

suite "dev store-daemon client refuses a daemon of another user":
  test "an attacker on the default endpoint is refused and its path is never used":
    when defined(linux):
      if usernsUnavailable.len > 0:
        skip(usernsUnavailable)
      else:
        let s = newScratch()
        defer: s.dispose()
        let endpoint = defaultDevEndpoint()
        checkpoint("default endpoint: " & endpoint)
        let attacker = startAttacker(endpoint, s.tmp / "attacker")
        defer: attacker.stop()

        var realized: StoreDaemonRealizeResult
        let err = refusalOf(proc () =
          realized = realizeSyntheticViaDaemon(s.syntheticReq))
        checkpoint("realize returned path '" & realized.realizedPrefixPath &
          "', raised: " & (if err == nil: "nothing" else: err.msg))
        check realized.realizedPrefixPath != attacker.forgedPath
        check err.isEndpointRefusal
        if err != nil:
          check ("uid " & $AttackerId) in err.msg
          check ("uid " & $victimUid()) in err.msg
          check s.privateDir in err.msg or endpoint in err.msg
        check attacker.attackerReceived == ""

        let fallback = realizeSyntheticWithFallback(s.syntheticReq)
        checkpoint("fallback returned " & fallback.realizedPrefixPath)
        check fallback.realizedPrefixPath != attacker.forgedPath
        check fallback.realizedPrefixPath.startsWith(s.storeRoot)
        check fallback.writerMode == "direct"
        check attacker.attackerReceived == ""
    else:
      skip("needs Linux user namespaces to run a second real uid; macOS getpeereid and the Windows pipe owner SID cannot be driven from this host")

  test "an explicit endpoint is used verbatim but its listener must be this user":
    when defined(linux):
      if usernsUnavailable.len > 0:
        skip(usernsUnavailable)
      else:
        let s = newScratch()
        defer: s.dispose()
        # The explicit endpoint's directory is the attacker's, mode 0777:
        # the spec leaves it unchecked, so only the peer check can stop this.
        let endpoint = s.tmp / "explicit" / "store.sock"
        putEnv("REPROSTORED_ENDPOINT", endpoint)
        check defaultDevEndpoint() == endpoint
        let attacker = startAttacker(endpoint, s.tmp / "explicit",
          dirMode = 0o777)
        defer: attacker.stop()

        var realized: StoreDaemonRealizeResult
        let err = refusalOf(proc () =
          realized = realizeSyntheticViaDaemon(s.syntheticReq, endpoint))
        checkpoint("realize returned path '" & realized.realizedPrefixPath &
          "', raised: " & (if err == nil: "nothing" else: err.msg))
        check realized.realizedPrefixPath != attacker.forgedPath
        check err.isEndpointRefusal
        if err != nil:
          check endpoint in err.msg
          check ("uid " & $AttackerId) in err.msg
          check ("uid " & $victimUid()) in err.msg
          check "directory" notin err.msg
        # Refused before Hello: the forged daemon read nothing at all.
        check attacker.attackerReceived == ""

        let connectErr = refusalOf(proc () =
          connectDevDaemon(endpoint).closeIpcConn())
        check connectErr.isEndpointRefusal

        let fallback = realizeSyntheticWithFallback(s.syntheticReq, endpoint)
        check fallback.realizedPrefixPath != attacker.forgedPath
        check fallback.realizedPrefixPath.startsWith(s.storeRoot)
        check fallback.writerMode == "direct"
        check attacker.attackerReceived == ""

        # The victim's own daemon refuses to take the endpoint over: it
        # neither unlinks nor replaces the other account's socket.
        let daemonWhy = daemonRefusal(DevDaemonConfig(endpoint: endpoint,
          storeRoot: s.storeRoot))
        checkpoint("daemon on a foreign-held endpoint: " & daemonWhy)
        check "another account" in daemonWhy
        check ("uid " & $AttackerId) in daemonWhy
        var info: Stat
        check lstat(endpoint.cstring, info) == 0
        check int(info.st_uid) == AttackerId
        check attacker.attackerReceived == ""
    else:
      skip("needs Linux user namespaces to run a second real uid; macOS getpeereid and the Windows pipe owner SID cannot be driven from this host")

  test "an endpoint another account holds is reported as held, never as not running":
    when defined(linux):
      if usernsUnavailable.len > 0:
        skip(usernsUnavailable)
      else:
        let s = newScratch()
        defer: s.dispose()
        let endpoint = s.tmp / "explicit" / "store.sock"
        let attacker = startAttacker(endpoint, s.tmp / "explicit",
          dirMode = 0o777)
        defer: attacker.stop()

        var status: StoreDaemonStatus
        let err = refusalOf(proc () = status = queryDevStatus(endpoint))
        checkpoint("status: running=" & $status.running & " storeRoot='" &
          status.storeRoot & "', raised: " &
          (if err == nil: "nothing" else: err.msg))
        check err.isEndpointRefusal
        check status.storeRoot != "/attacker/store"
        check attacker.attackerReceived == ""

        check fileExists(reproCli())
        let cli = execCmdEx(quoteShellCommand([reproCli(), "store", "daemon",
          "status", "--dev", "--endpoint", endpoint,
          "--store-root", s.storeRoot]))
        checkpoint("repro store daemon status --dev (exit " &
          $cli.exitCode & "):\n" & cli.output)
        check cli.exitCode != 0
        check "not-running" notin cli.output
        check "/attacker/store" notin cli.output
        check "another account" in cli.output
        check ("uid " & $AttackerId) in cli.output
        check attacker.attackerReceived == ""

        # The same for the default endpoint, held through its directory.
        let defaultAttacker = startAttacker(defaultDevEndpoint(),
          s.tmp / "attacker")
        defer: defaultAttacker.stop()
        let defaultCli = execCmdEx(quoteShellCommand([reproCli(), "store",
          "daemon", "status", "--dev", "--store-root", s.storeRoot]))
        checkpoint("default endpoint status (exit " & $defaultCli.exitCode &
          "):\n" & defaultCli.output)
        check defaultCli.exitCode != 0
        check "not-running" notin defaultCli.output
        check "/attacker/store" notin defaultCli.output
        check ("uid " & $AttackerId) in defaultCli.output
    else:
      skip("needs Linux user namespaces to run a second real uid; macOS getpeereid and the Windows pipe owner SID cannot be driven from this host")

  test "the per-user endpoint directory is admitted only when private and ours":
    when defined(linux):
      if usernsUnavailable.len > 0:
        skip(usernsUnavailable)
      else:
        let s = newScratch()
        defer: s.dispose()
        check defaultDevEndpoint() == s.expectedDefaultEndpoint
        let config = DevDaemonConfig(endpoint: defaultDevEndpoint(),
          storeRoot: s.storeRoot)

        # 1. Another account created it first (mode 0700, owned by uid 1).
        block foreignOwner:
          let attacker = startAttacker(defaultDevEndpoint(),
            s.tmp / "attacker")
          defer: attacker.stop()
          let err = refusalOf(proc () =
            connectDevDaemon().closeIpcConn())
          checkpoint("foreign dir: " &
            (if err == nil: "accepted" else: err.msg))
          check err.isEndpointRefusal
          if err != nil:
            check s.privateDir in err.msg
            check ("uid " & $AttackerId) in err.msg
            check "0700" in err.msg
          let daemonWhy = daemonRefusal(config)
          checkpoint("daemon on foreign dir: " & daemonWhy)
          check s.privateDir in daemonWhy
          check ("uid " & $AttackerId) in daemonWhy
          check attacker.attackerReceived == ""
          # Never repaired: still the attacker's, still its mode.
          var info: Stat
          check lstat(s.privateDir.cstring, info) == 0
          check int(info.st_uid) == AttackerId
          check modeOf(s.privateDir) == 0o700
        removeDir(s.privateDir)
        removeDir(s.tmp / "attacker")

        # 2. Ours, but it grants group permissions (0750).
        block groupBits:
          createDir(s.privateDir)
          check chmod(s.privateDir.cstring, Mode(0o750)) == 0
          let err = refusalOf(proc () =
            connectDevDaemon().closeIpcConn())
          checkpoint("0750 dir: " & (if err == nil: "accepted" else: err.msg))
          check err.isEndpointRefusal
          if err != nil:
            check s.privateDir in err.msg
            check "0750" in err.msg
            check ("uid " & $victimUid()) in err.msg
          let daemonWhy = daemonRefusal(config)
          checkpoint("daemon on 0750 dir: " & daemonWhy)
          check s.privateDir in daemonWhy
          check "0750" in daemonWhy
          check not fileExists(s.expectedDefaultEndpoint)
          check modeOf(s.privateDir) == 0o750
        removeDir(s.privateDir)

        # 3. A symlink in its place, to a private directory of ours.
        block symlinked:
          let target = s.tmp / "elsewhere"
          createDir(target)
          check chmod(target.cstring, Mode(0o700)) == 0
          createSymlink(target, s.privateDir)
          let err = refusalOf(proc () =
            connectDevDaemon().closeIpcConn())
          checkpoint("symlinked dir: " &
            (if err == nil: "accepted" else: err.msg))
          check err.isEndpointRefusal
          if err != nil:
            check s.privateDir in err.msg
            check "symlink" in err.msg
          check symlinkExists(s.privateDir)
          check toSeq(walkDir(target)).len == 0

        # 4. A directory that cannot be created at all (its TMPDIR is
        #    missing) is an unreachable daemon, not a refusal: nothing can
        #    listen there and nobody else's directory was found.
        block uncreatable:
          let missing = s.tmp / "no-such-tmp"
          putEnv("TMPDIR", missing)
          defer: putEnv("TMPDIR", s.tmp)
          var status: StoreDaemonStatus
          let err = refusalOf(proc () = status = queryDevStatus())
          checkpoint("missing TMPDIR: " &
            (if err == nil: "running=" & $status.running else: err.msg))
          check err == nil
          check not status.running
          check not dirExists(missing)
    else:
      skip("needs Linux user namespaces to run a second real uid; macOS getpeereid and the Windows pipe owner SID cannot be driven from this host")

  test "a real dev daemon of the same user is reached through the default endpoint":
    when defined(linux):
      if usernsUnavailable.len > 0:
        skip(usernsUnavailable)
      else:
        let s = newScratch()
        defer: s.dispose()
        let endpoint = defaultDevEndpoint()
        check endpoint == s.expectedDefaultEndpoint
        let pid = fork()
        doAssert pid >= 0
        if pid == 0:
          var rc = 1
          try:
            rc = runDevDaemonForeground(DevDaemonConfig(endpoint: endpoint,
              storeRoot: s.storeRoot))
          except CatchableError as err:
            stderr.writeLine("daemon failed: " & err.msg)
          exitnow(cint(rc))
        defer:
          try: requestDevShutdown(endpoint) except CatchableError: discard
          var status: cint
          discard waitpid(pid, status, 0)

        var status: StoreDaemonStatus
        for _ in 0 ..< 400:
          status = queryDevStatus(endpoint)
          if status.running: break
          sleep(25)
        check status.running
        check status.storeRoot == s.storeRoot

        let res = realizeSyntheticViaDaemon(s.syntheticReq)
        check res.writerMode == "daemon"
        check res.realizedPrefixPath.startsWith(s.storeRoot)
        check readFile(res.realizedPrefixPath / "bin" / "tool") ==
          "the victim's own payload\n"

        var info: Stat
        check lstat(s.privateDir.cstring, info) == 0
        check S_ISDIR(info.st_mode)
        check int(info.st_uid) == victimUid()
        check modeOf(s.privateDir) == 0o700
        check fileExists(s.privateDir / (endpoint.extractFilename & ".status"))
    else:
      skip("needs Linux user namespaces to run a second real uid; macOS getpeereid and the Windows pipe owner SID cannot be driven from this host")
