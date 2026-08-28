## Shared, portable test helpers used by repository-level Nim tests.
##
## Many tests need to invoke ``repro``/``repro-daemon`` etc. with a
## specific working directory, a specific subprocess environment, and
## then assert against the merged stdout+stderr output. Each test had
## historically grown its own copy of:
##
##   proc shellCommand(args, env): string =
##     for (n,v) in env: parts.add(n & "=" & q(v))
##     for arg in args: parts.add(q(arg))
##     parts.join(" ")
##   proc runShell(command): (code, output) =
##     execCmdEx(command)
##
## That shape works under ``/bin/sh`` on POSIX (which honours the
## ``VAR=value cmd`` prefix syntax) but FAILS under Windows
## ``cmd.exe /c``: ``set`` cannot chain via ``&&`` through
## ``execCmdEx`` because Nim doesn't actually wrap the command in
## ``cmd.exe`` — it hands the whole string to ``CreateProcessW`` as
## the literal program name. The fix is structural: use
## ``startProcess(args = ..., env = ...)`` which sets per-child env
## vars through the OS env block directly, no shell required.
##
## All exported procs are deliberately tiny — they exist so each test
## file can do
##
##   import repro_test_support
##
## without duplicating the boilerplate; the behaviour is identical
## across Linux, macOS, and Windows.

import std/[os, osproc, streams, strtabs, strutils, unittest]

from repro_core/paths import extendedPath, runquotaEndpointPath

# Narrow, named import: ``runquota_ipc`` is RunQuota's own endpoint-trust
# module, and ``runquotaRendezvousDir`` below delegates the "where may a
# socket live" rule to it rather than keeping a second copy of the mode.
# Named symbols only — a wildcard import would drag ``connect``/``close``
# over ``std/net`` spellings a test file may also be using.
from runquota_ipc import ensureEndpointDir, unixEndpoint

when defined(windows):
  import std/winlean
else:
  import std/posix

type
  LoopbackSshLogin = object
    ## Outcome of the loopback-SSH login-shell capability probe.
    ## Deliberately NOT exported: the only supported way to consult it is
    ## ``requireLoopbackSshLogin``, which fails closed. An exported
    ## boolean predicate invites the ``if not available(): skip()`` shape
    ## that started this — and ``skip()`` does not return (the stdlib
    ## docstring says verbatim "The test code is still executed"), so the
    ## guarded body ran anyway and hard-failed with sshd's opaque
    ## "This account is currently not available".
    available: bool
    user: string
    shell: string

proc loopbackSshLogin(): LoopbackSshLogin =
  ## OpenSSH executes remote commands through the account's passwd shell.
  ## Self-hosted service accounts commonly use nologin/false, which makes a
  ## loopback sshd accept authentication but reject every command.
  result = LoopbackSshLogin(available: true, user: "", shell: "")
  when defined(posix):
    result.user = getEnv("USER")
    if result.user.len == 0:
      return
    let probe = execCmdEx("getent passwd " & quoteShell(result.user))
    if probe.exitCode != 0:
      return
    let fields = probe.output.strip().split(':')
    if fields.len < 7:
      return
    result.shell = fields[^1].strip()
    result.available = not (result.shell.endsWith("/nologin") or
      result.shell.endsWith("/false"))

proc requireLoopbackSshLogin*(gate: string) =
  ## Fail-closed preflight for the gates that drive a REAL user-owned
  ## loopback ``sshd`` (M71 phases C/D/E).
  ##
  ## A usable login shell is a HARD PREREQUISITE of these gates, in the
  ## same class as ``ssh`` / ``sshd`` / ``ssh-keygen`` being installed —
  ## which the same tests already treat as ``doAssert false`` blockers.
  ## The subject under test IS the SSH transport (bundle streaming,
  ## remote activation, ``enable --host --now``); there is no residual
  ## assertion worth making once the transport cannot run, so degrading
  ## to a partial run would be a green light over an unexercised gate.
  ##
  ## It therefore reports a deterministic FAILURE, never a skip: M0's
  ## exit gate requires a full-suite run with zero skips, so a
  ## ``[SKIPPED]`` is itself a gate failure. The message names the
  ## account, its shell, and the remedy, so the failure is actionable
  ## from the CI log alone instead of surfacing as sshd's opaque
  ## "This account is currently not available" 6 seconds into a probe
  ## loop.
  let probe = loopbackSshLogin()
  if probe.available:
    return
  doAssert false,
    gate & " blocker: this gate drives a real user-owned loopback sshd, " &
    "and OpenSSH runs every remote command through the account's passwd " &
    "login shell. Account '" & probe.user & "' has login shell '" &
    probe.shell & "', so sshd authenticates the connection and then " &
    "rejects every command with \"This account is currently not " &
    "available\".\n" &
    "  This is an environment defect, and it is deliberately NOT " &
    "skippable: M0's exit gate requires a full-suite run with zero " &
    "skips, so the gate fails hard rather than reporting a green or " &
    "skipped result over an SSH transport that never ran.\n" &
    "  Remedy: run the suite as an account with a real login shell, or " &
    "give this one a shell (e.g. `usermod -s /bin/sh " & probe.user &
    "`). Note the probe keys off $USER, so $USER must name the account " &
    "the suite actually runs as."

const
  isNixSupported* = defined(linux) or defined(macosx)
    ## True on platforms where `nix` / `nix build` is a realistic
    ## option for hermetic tool provisioning. The constant exists so
    ## tests can gate Nix-dependent fixtures at COMPILE time, e.g.
    ##   when isNixSupported:
    ##     proc requireFish(): string = ...
    ##     test "e2e_fish_hook":
    ##       discard requireFish()
    ## On Windows the test body is excluded from the binary entirely;
    ## the suite still compiles and the unrelated tests run. The
    ## previous pattern (`findExe("nix")` runtime probe) was both
    ## brittle (a stale `nix` shim on PATH hung the test) and led to
    ## test bodies that pretended to be portable when their
    ## production code was not. A single named constant lets the
    ## intent stay visible at every gate site and makes it
    ## trivial to grep for "everything that needs Nix".

  isIoMonitorSupported* = defined(linux) or defined(macosx) or defined(windows)
    ## True on platforms where the dev-env tests can wire in
    ## ``repro internal io monitor`` and the monitor shim end-to-end.
    ##
    ## Windows uses an IAT-patching DLL injected via
    ## ``CreateProcess(CREATE_SUSPENDED)`` + ``CreateRemoteThread``
    ## (see ``io-mon: io_mon/shim/windows_interpose.nim``).
    ## The shim depends on ct_interpose's ``hook_registry`` —
    ## The shim is graph-built by ``scripts/build_apps.sh`` / ``repro build
    ## test``; tests assert that artifact exists instead of compiling monitor
    ## components at runtime.

  ioMonitorCliArgs* = @["internal", "io", "monitor"]
    ## Subcommand selector used when tests invoke the consolidated ``repro``
    ## binary as the io-monitor driver.


type
  CmdSpec* = object
    ## Bundle of the program path, its argv, and any per-invocation
    ## env-var overrides. ``shellCommand`` returns this so call sites
    ## like ``requireSuccess(shellCommand(args, env), cwd)`` keep
    ## reading the same way they used to; only the underlying type
    ## changes from ``string`` (a shell command line) to ``CmdSpec``
    ## (a structured argv+env record).
    args*: seq[string]
    env*: seq[tuple[name, value: string]]

  CmdResult* = tuple[code: int; output: string]

proc shellCommand*(args: openArray[string];
                   env: openArray[tuple[name, value: string]] = []): CmdSpec =
  ## Bundle argv + env-var overrides into a ``CmdSpec``. The legacy
  ## name is retained so callers don't have to rename — the type
  ## change does the heavy lifting.
  result.args = @args
  result.env = @env

proc runShell*(cmd: CmdSpec; cwd = getCurrentDir()): CmdResult =
  ## Invoke ``cmd.args[0]`` with ``cmd.args[1..^1]`` under ``cwd``,
  ## merging stderr into stdout (the pre-refactor behaviour of
  ## ``execCmdEx`` with ``poStdErrToStdOut``).
  ##
  ## The subprocess inherits the parent environment, overlaid with
  ## ``cmd.env`` — matching the per-invocation override semantics
  ## the old ``VAR=value cmd`` shell prefix provided.
  if cmd.args.len == 0:
    raise newException(ValueError, "shellCommand returned an empty argv")
  var envTable = newStringTable()
  for k, v in envPairs(): envTable[k] = v
  for entry in cmd.env: envTable[entry.name] = entry.value
  # ``poUsePath`` makes ``startProcess`` resolve ``cmd.args[0]`` against
  # the inherited (and overlay-modified) ``PATH``. Without it the
  # subprocess receives the unresolved command name as ``argv[0]``,
  # ``execv`` fails with ``ENOENT``, and the OSError shows up as
  # ``Could not find command: 'git'`` etc. — exactly the regression the
  # post-test-support-sweep suite exhibited on Linux.
  let process = startProcess(cmd.args[0],
    workingDir = cwd,
    args = cmd.args[1..^1],
    env = envTable,
    options = {poStdErrToStdOut, poUsePath})
  defer: process.close()
  # Three interacting Nim 2.2.x pitfalls force this hand-rolled loop:
  #
  # (a) ``stream.readAll`` breaks the read loop the FIRST time
  #     ``readData`` returns fewer than the 1 KiB buffer's worth — fine
  #     for seekable file streams, catastrophic for pipes. On Windows
  #     each child write arrives as its own ReadFile completion, so the
  #     first short read aborts and everything after the child's first
  #     stdout line is dropped.
  #
  # (b) Tests that invoke ``repro build --daemon=require`` (or
  #     ``--daemon=auto`` with no running daemon) trigger
  #     ``startUserDaemon`` inside the child. Even with ``poDaemon`` the
  #     daemon grandchild inherits the child's stdout pipe handle on
  #     Windows (CreateProcess with bInheritHandles=TRUE inherits ALL
  #     inheritable handles in the calling process, including the
  #     child's stdout WRITE end). A naive drain loop that waits for
  #     the pipe to close hangs forever because the daemon stays alive
  #     after the test child exits.
  #
  # (c) ``ReadFile`` on a Windows pipe is blocking. ``readLine`` /
  #     ``readAll`` therefore wait indefinitely once the pipe has no
  #     data but its handle is still held by the daemon grandchild.
  #     ``execCmdEx`` itself hangs in this exact scenario.
  #
  # Cut through all three with the classic ``PeekNamedPipe`` poll:
  # only ``ReadFile`` when ``PeekNamedPipe`` reports bytes available,
  # otherwise check whether the IMMEDIATE child has exited and bail.
  # The pipe-handle-still-open-via-grandchild becomes a non-issue —
  # once the child's exit code materialises we walk away, leaving the
  # daemon to its independent lifecycle.
  when defined(windows):
    const PollSleepMs = 25
    let outHandle = Handle(process.outputHandle)
    var buf {.noinit.}: array[4096, char]
    while true:
      var bytesAvail: int32 = 0
      let peeked = peekNamedPipe(outHandle, lpTotalBytesAvail = addr bytesAvail)
      if not peeked:
        result.code = process.peekExitCode()
        if result.code != -1:
          break
        sleep(PollSleepMs)
        continue
      if bytesAvail == 0:
        result.code = process.peekExitCode()
        if result.code != -1:
          break
        sleep(PollSleepMs)
        continue
      var bytesRead: int32 = 0
      let toRead = min(int(bytesAvail), buf.len).int32
      let ok = readFile(outHandle, addr buf[0], toRead, addr bytesRead, nil)
      if ok == 0 or bytesRead == 0:
        result.code = process.peekExitCode()
        if result.code != -1:
          break
        sleep(PollSleepMs)
        continue
      let prev = result.output.len
      result.output.setLen(prev + bytesRead)
      copyMem(addr result.output[prev], addr buf[0], bytesRead)
  else:
    # POSIX mirror of the Windows ``PeekNamedPipe`` strategy documented in
    # (b)/(c) above, and for the SAME reason. A daemon grandchild — spawned
    # by ``repro build`` / ``repro watch`` in default daemon mode via
    # ``startUserDaemon`` — inherits the immediate child's stdout WRITE end
    # (``fork`` duplicates every open fd; the daemon's own ``poDaemon``-style
    # detach redirects its logging to a file but the inherited pipe fd stays
    # open). A blocking ``readLine``/``readAll`` then waits for an EOF that
    # never arrives, because the build child has long exited while the daemon
    # keeps the pipe's write end alive — hanging the test forever. This was
    # latent until the daemon control-plane suite first ran on macOS.
    #
    # Read NON-BLOCKING instead: drain whatever the child wrote, and once the
    # IMMEDIATE child has exited and the pipe yields no more buffered bytes,
    # stop — leaving the daemon to its independent lifecycle exactly as the
    # Windows branch does. The test's own ``stopDaemon`` defer reaps it.
    const PollSleepMs = 25
    let fd = cint(process.outputHandle)
    let prevFlags = fcntl(fd, F_GETFL)
    if prevFlags != -1:
      discard fcntl(fd, F_SETFL, prevFlags or O_NONBLOCK)
    # Drain every byte currently readable without blocking, appending to
    # ``sink``; returns true on a genuine EOF (all write ends closed), false
    # once the pipe would block. ``sink`` is an explicit ``var`` parameter so
    # the nested proc's own (bool) ``result`` does not shadow ``CmdResult``.
    proc drainAvailable(fd: cint; sink: var string): bool =
      var buf {.noinit.}: array[4096, char]
      while true:
        let n = read(fd, addr buf[0], buf.len)
        if n > 0:
          let prev = sink.len
          sink.setLen(prev + n)
          copyMem(addr sink[prev], addr buf[0], n)
        elif n == 0:
          return true
        else:
          if errno == EINTR:
            continue
          # EAGAIN/EWOULDBLOCK (no data right now) or an unexpected error:
          # either way there is nothing more to read this pass.
          return false
    result.code = -1
    while true:
      if drainAvailable(fd, result.output):
        # Genuine EOF: every write end (including any grandchild's) closed.
        result.code = process.peekExitCode()
        if result.code == -1:
          result.code = process.waitForExit()
        break
      # Pipe would block. If the immediate child is gone, do one final drain
      # to collect bytes that raced in just before it exited, then walk away
      # without waiting for the grandchild-held write end to close.
      result.code = process.peekExitCode()
      if result.code != -1:
        discard drainAvailable(fd, result.output)
        break
      sleep(PollSleepMs)

proc requireSuccess*(cmd: CmdSpec; cwd = getCurrentDir()): string =
  ## Run ``cmd`` and assert exit-code 0. Returns the merged output so
  ## callers can keep chaining ``.contains("...")`` checks.
  let res = runShell(cmd, cwd)
  if res.code != 0:
    checkpoint(res.output)
  check res.code == 0
  res.output

proc requireFailure*(cmd: CmdSpec; cwd = getCurrentDir()): string =
  ## Mirror of ``requireSuccess`` for the negative-path callers that
  ## previously checked ``res.code != 0`` themselves.
  let res = runShell(cmd, cwd)
  if res.code == 0:
    checkpoint(res.output)
  check res.code != 0
  res.output

proc testCaseScratchSlug*(): string =
  ## Suffix that makes a test binary's scratch directory private to the
  ## process executing ONE test case.
  ##
  ## Under the binary-runner protocol a test binary is executed once per
  ## case (``<binary> --run "<suite>::<test>"``), so sibling cases of the
  ## same binary run as CONCURRENT processes. A scratch path baked in as
  ## a module-level constant is therefore shared mutable state across
  ## processes: the suite-level reset performed by one case deletes the
  ## fixture another case is part-way through using. That is not a
  ## hypothetical — it is what made ``t_adapter_chain``,
  ## ``t_integration_apply_lock_serializes`` and
  ## ``t_integration_pointer_envelope_and_history_enumeration`` fail the
  ## moment the suite gained per-case granularity, and each of them
  ## reproduces standalone at ``--threads=8`` and passes at
  ## ``--threads=1``.
  ##
  ## Keying on the ``--run`` name rather than on the pid is deliberate:
  ## it keeps the set of scratch directories BOUNDED (one per case, not
  ## one per execution) and stable across runs, so the tree does not
  ## grow without limit and a failed run's fixture is still there to
  ## inspect. Whole-binary execution — one process, cases strictly
  ## sequential — keeps the single shared directory it always had.
  ##
  ## The full case name is hashed rather than embedded so the result
  ## stays a short, filesystem-legal, collision-free component
  ## regardless of how long or how punctuated the suite/test names are.
  var runName = ""
  var i = 1
  while i <= paramCount():
    let p = paramStr(i)
    if p == "--run" and i < paramCount():
      runName = paramStr(i + 1)
      break
    elif p.startsWith("--run="):
      runName = p["--run=".len .. ^1]
      break
    inc i
  if runName.len == 0:
    return "whole"
  var h: uint32 = 2166136261'u32
  for c in runName:
    h = h xor uint32(ord(c))
    h = h * 16777619'u32
  "case-" & toHex(h, 8).toLowerAscii

proc isTransientDirectoryNotEmpty(e: ref OSError): bool =
  ## Nim's OSError does not expose the failing errno portably. Keep this
  ## deliberately narrow: retry only the ENOTEMPTY-shaped cleanup race the
  ## full suite has observed, and re-raise every other cleanup failure.
  let msg = e.msg.toLowerAscii()
  msg.contains("directory not empty") or msg.contains("directory is not empty")

proc removeDirEventually*(path: string; attempts = 25; sleepMs = 40) =
  ## Remove a test scratch directory, tolerating only transient ENOTEMPTY.
  ##
  ## Some production paths briefly leave background filesystem activity in
  ## `.repro` / `.git` trees after all test assertions have passed. A plain
  ## `removeDir` can lose that race and fail with "Directory not empty". This
  ## helper gives that narrow condition a bounded chance to settle, then
  ## re-raises the final OSError so cleanup regressions stay visible.
  ##
  ## ENOTEMPTY on Windows has a SECOND cause that no amount of waiting fixes,
  ## and the two are indistinguishable from the error alone. `removeDir` walks
  ## with `FindFirstFileW`, which without the `\\?\` prefix cannot enumerate
  ## entries whose full path exceeds `MAX_PATH` (260). Such entries are not
  ## reported as an error — they are simply not yielded, so the walk deletes
  ## nothing, and the following `RemoveDirectory` fails on a directory the
  ## walk believed was empty. A workspace fork writes engine action-cache
  ## records at `…/hot-records/0-1-<64 hex>.rbar/<64 hex>.rec`, which is ~277
  ## characters under a `%TEMP%` fixture root — past the limit — so every fork
  ## test failed teardown on a host without `LongPathsEnabled` while its
  ## assertions had all passed. Retrying the extended-length form is what
  ## actually clears it, so a persistent ENOTEMPTY escalates to that before
  ## the error is allowed to stand.
  if path.len == 0 or not dirExists(path):
    return
  var last: ref OSError
  for attempt in 0 ..< attempts:
    try:
      removeDir(path)
      return
    except OSError as e:
      if not isTransientDirectoryNotEmpty(e):
        raise
      if not dirExists(path):
        return
      last = e
      if attempt + 1 < attempts:
        sleep(sleepMs)
  # Waiting did not help: try the long-path form before giving up. Kept as an
  # escalation rather than the default so the ordinary path stays exercised.
  when defined(windows):
    try:
      removeDir(extendedPath(path))
      return
    except OSError:
      discard
    if not dirExists(path):
      return
  if last != nil:
    raise last

proc registryRootEnv*(scratchDir: string): tuple[k, v: string] =
  ## Env-var entry that redirects HKCU registry writes made by a
  ## `repro home apply` subprocess into a per-test fake hive under
  ## `scratchDir / "registry"`. Intended use:
  ##
  ## ```nim
  ## let baseEnv = @[
  ##   (k: "REPRO_HOME_STATE_DIR", v: stateDir),
  ##   ...,
  ##   registryRootEnv(tempRoot)]
  ## ```
  ##
  ## Without this, e2e tests that exercise `env.userPath` /
  ## `env.userVariable` / `windows.registryValue` resources leak PATH
  ## entries into the host's real `HKCU\Environment\Path` (see project
  ## memory: reprobuild user PATH pollution, 2026-06-06).
  (k: "REPRO_REGISTRY_ROOT", v: scratchDir / "registry")

proc fileUrl*(path: string): string =
  ## Build an RFC 8089 ``file://`` URL for a fixture path that is then
  ## interpolated into a TOML basic string (a manifest, lock, project
  ## file, etc.) AND/OR passed to ``git clone`` as a remote.
  ##
  ## On POSIX, ``path`` already starts with ``/`` so a plain
  ## ``"file://" & path`` already yields the canonical three-slash form
  ## ``file:///abs/path``. On Windows ``path`` looks like ``C:\Users\...``
  ## and the same concatenation produces ``file://C:\Users\...`` — which
  ## is doubly wrong:
  ##
  ## - RFC 8089 requires three slashes plus forward separators
  ##   (``file:///C:/Users/...``); a two-slash form reads ``C:`` as the
  ##   authority component.
  ## - More damaging in practice: a TOML basic string interprets ``\U``
  ##   as the start of an 8-hex-digit Unicode escape and ``\u`` as a
  ##   4-hex-digit one. ``\Users`` is an invalid escape, so the strict
  ##   reader rejects every workspace.toml / projects/*.toml fixture
  ##   that was assembled with the raw concatenation. The toml-
  ##   serialization library raises with an empty message in this case,
  ##   making the failure mode opaque on Linux-reviewed tests when they
  ##   run on a Windows host.
  ##
  ## The helper normalises both: forward slashes (TOML-safe + RFC-correct)
  ## and the explicit three-slash prefix on Windows. ``git`` accepts the
  ## normalised form on every supported host, so callers that previously
  ## passed ``"file://" & path`` straight to ``git clone`` keep working.
  when defined(windows):
    "file:///" & path.replace('\\', '/')
  else:
    "file://" & path

proc tomlBasicString*(value: string): string =
  ## ``value`` spelled as the BODY of a TOML basic string (``"..."``).
  ##
  ## The sibling of ``fileUrl`` for values that are NOT URLs: a native
  ## filesystem path written into a fixture manifest (``program = "..."``,
  ## ``local_path = "..."``), or an expected value asserted against TOML that
  ## reprobuild itself wrote.
  ##
  ## On POSIX this is the identity for every path a test produces, which is
  ## exactly why the omission is invisible there. On Windows a path is
  ## ``C:\Users\...`` and a lone ``\`` is not legal inside a basic string —
  ## ``\U`` starts an 8-hex-digit Unicode escape, ``\b`` / ``\t`` / ``\n`` are
  ## control escapes, and anything else is a hard parse error which the
  ## toml-serialization library reports with an EMPTY message.
  ##
  ## Matches what reprobuild's own writers emit (``repro_lock.tomlEscape``,
  ## ``develop_overrides.tomlEscape``, ``workspace_branch.tomlEscape``), so it
  ## is equally the right spelling for an assertion of the form
  ## ``check ("url = \"" & tomlBasicString(u) & "\"") in lockBody``.
  ##
  ## The alternative the reader's own diagnostic offers — a TOML LITERAL
  ## string ``'...'`` — is not used here because a literal string cannot
  ## express a value containing ``'`` and gives no escape hatch.
  result = newStringOfCap(value.len + 8)
  for ch in value:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    of '\b': result.add("\\b")
    of '\f': result.add("\\f")
    else: result.add(ch)

proc daemonSocketEndpoint*(name: string): string =
  ## Portable per-test endpoint name. AF_UNIX socket paths are picked
  ## under ``/tmp`` on POSIX; on Windows the equivalent name lives in
  ## the kernel-managed named-pipe namespace.
  when defined(windows):
    r"\\.\pipe\" & name.replace('\\', '_').replace('/', '_')
  else:
    "/tmp" / (name & ".sock")

proc runquotaSocketEndpoint*(name: string): string =
  ## Per-test ``runquotad --socket`` argument that always lands on the
  ## right transport: a Unix socket inside a private per-test directory
  ## on POSIX, a Named-Pipe name in the kernel namespace on Windows.
  ## Tests thread the SAME string into ``RUNQUOTA_SOCKET`` so the client
  ## connects to the instance the test started.
  ##
  ## The rule about WHERE that socket may live is
  ## ``repro_core/paths.runquotaEndpointPath`` and is shared with the
  ## product's own daemon spawn, because a test that binds somewhere the
  ## shipped code would not is a test of something nobody runs.
  runquotaEndpointPath(name)

proc runquotaRendezvousDir*(root: string): string =
  ## THE one place a test that owns a scratch tree decides where a
  ## locally spawned ``runquotad`` may bind. Returns the directory; the
  ## caller appends its own socket file name.
  ##
  ## WHY A DIRECTORY OF ITS OWN, AND NOT ``root`` ITSELF. The socket's
  ## PARENT DIRECTORY is the rendezvous point RunQuota verifies — the
  ## daemon before it binds and every client before it connects — and it
  ## must be owned by the configured owner and never group- or
  ## world-writable. A socket dropped straight into ``getTempDir()`` fails
  ## both halves: ``/tmp`` is root-owned ``1777``, so ``runquotad`` exits
  ## with ``runquota endpoint directory /tmp: refusing a path owned by uid
  ## 0 with mode 1777`` before it ever prints its listening line. That
  ## refusal is right — a rendezvous any local user can write is one any
  ## local user can REPLACE — so this is a path change, never a flag that
  ## turns the check off.
  ##
  ## THE MODE IS NOT WRITTEN DOWN HERE, and that is the point of routing
  ## through ``runquota_ipc.ensureEndpointDir`` instead of a local
  ## ``createDir`` + ``setFilePermissions(0700)``. The required mode is a
  ## FUNCTION OF THE HOST: ``rendezvousPolicy()`` yields ``0700``/owner-only
  ## on a host with no ``runquota`` group, and ``0750`` group-gated on a
  ## host that has one. Four copies of this helper had ``0700`` hard-coded
  ## and were silently correct only in the first case; on a provisioned
  ## host they would have created a directory the daemon then refuses for
  ## the OPPOSITE reason (``refusing mode 0700, required 0750``). Asking
  ## RunQuota to provision and verify its own rendezvous keeps the test on
  ## exactly the rule the product enforces, with no second copy of it.
  ##
  ## ``ensureEndpointDir`` VERIFIES as well as creates, and raises
  ## ``EndpointTrustError`` carrying the refusal text when it cannot. A
  ## caller must let that propagate: a fixture that cannot get a
  ## trustworthy rendezvous has not "skipped", it has failed to set up.
  result = root / "ep"
  when defined(posix):
    ensureEndpointDir(unixEndpoint(result / "runquota.sock"))
  else:
    # Windows: named pipes live in the kernel object namespace and carry
    # their own ACL, so there is no directory to own and no mode to
    # widen. The directory is still created because callers put other
    # per-daemon scratch beside the endpoint.
    createDir(result)

proc runquotaEndpointReachable*(endpoint: string): bool =
  ## Polled readiness check used by ``ensureRunQuotaDaemon`` helpers
  ## across the suite. The POSIX path is "the socket file appeared";
  ## on Windows there is no file — the named pipe lives in
  ## ``\\.\pipe\`` — so we fall back to ``fileExists`` on POSIX and
  ## treat the daemon as ready on Windows once the process has not
  ## crashed (the caller's process-alive check is the real signal
  ## there).
  when defined(windows):
    endpoint.startsWith(r"\\.\pipe\") or endpoint.startsWith(r"\\?\pipe\")
  else:
    fileExists(endpoint)

const ReprobuildRepoRoot* =
  currentSourcePath().parentDir().parentDir().parentDir().parentDir()
  ## ``libs/repro_test_support/src/repro_test_support.nim`` -> the checkout
  ## root. ``currentSourcePath()`` is absolute on both compilers (measured in
  ## W14 on stock 2.2.8 and on the codetracer fork, from two working
  ## directories, with the source given both relatively and absolutely), so
  ## this is the repository that CONTAINS this file — never the directory the
  ## test process happened to be launched from.

type HostBinaryFormat* = enum
  ## Machine format of a file on disk, decided by its magic bytes.
  ##
  ## This exists because neither the NAME nor the mode bit answers the
  ## question a test actually needs answered before it executes something.
  ## ``build/`` is gitignored and shared between this host's Windows
  ## checkout (``M:\m\dev\reprobuild``) and the WSL view of the same tree
  ## (``/mnt/m/m/dev/reprobuild``), so a ``nix develop`` build drops an ELF
  ## beside the PE and 12 names exist in both forms. An extension-less path
  ## therefore names *whichever platform built last*, and on Windows
  ## ``fileExists`` says true, ``executableFile`` says true, and the exec
  ## then fails with "%1 is not a valid Win32 application" — a product-shaped
  ## error with a filesystem-residue cause.
  hbfMissing    ## no such file
  hbfUnknown    ## a file, but not a machine image this repo produces
  hbfElf
  hbfPe
  hbfMachO

proc binaryFormatOf*(path: string): HostBinaryFormat =
  ## Classify ``path`` by its header bytes. Reads at most 68 bytes.
  if path.len == 0 or not fileExists(path):
    return hbfMissing
  var f: File
  if not open(f, path, fmRead):
    return hbfUnknown
  defer: f.close()
  var head: array[64, uint8]
  let n = f.readBuffer(addr head[0], head.len)
  if n < 4:
    return hbfUnknown
  if head[0] == 0x7f'u8 and head[1] == uint8('E') and
      head[2] == uint8('L') and head[3] == uint8('F'):
    return hbfElf
  let magic32 = uint32(head[0]) or (uint32(head[1]) shl 8) or
    (uint32(head[2]) shl 16) or (uint32(head[3]) shl 24)
  case magic32
  of 0xfeedface'u32, 0xfeedfacf'u32, 0xcefaedfe'u32, 0xcffaedfe'u32,
     0xcafebabe'u32, 0xbebafeca'u32:
    return hbfMachO
  else: discard
  if head[0] == uint8('M') and head[1] == uint8('Z'):
    # A DOS stub is not a PE image. The PE signature sits at the offset
    # stored in the little-endian uint32 at 0x3C; a bare ``MZ`` (a truncated
    # copy, or a DOS-era stub) must NOT be accepted as this platform's
    # artefact just because the first two bytes look right.
    if n < 0x40:
      return hbfUnknown
    let lfanew = int(uint32(head[0x3c]) or (uint32(head[0x3d]) shl 8) or
      (uint32(head[0x3e]) shl 16) or (uint32(head[0x3f]) shl 24))
    if lfanew <= 0 or lfanew > int(getFileSize(f)) - 4:
      return hbfUnknown
    f.setFilePos(int64(lfanew))
    var sig: array[4, uint8]
    if f.readBuffer(addr sig[0], sig.len) != 4:
      return hbfUnknown
    if sig[0] == uint8('P') and sig[1] == uint8('E') and
        sig[2] == 0'u8 and sig[3] == 0'u8:
      return hbfPe
    return hbfUnknown
  hbfUnknown

func hostBinaryFormat*(): HostBinaryFormat =
  ## The machine format an executable must have to run on THIS host.
  when defined(windows): hbfPe
  elif defined(macosx): hbfMachO
  else: hbfElf

func hostBinaryName*(stem: string): string =
  ## ``stem`` with the host's executable suffix. The one spelling.
  stem.addFileExt(ExeExt)

proc reproBinaryPath*(stem = "repro"): string =
  ## The single supported way for a test to name a binary that
  ## ``scripts/build_apps.sh`` / the ``apps`` collection produced.
  ##
  ## Source-anchored (not cwd-relative) and extension-correct. W14 fixed
  ## 69 files that each spelled ``build/bin/repro`` their own way; this is
  ## the helper it recommended so there is ONE spelling left to search for.
  ## The literal ``build/bin/repro`` below is load-bearing for
  ## ``scripts/generate_test_edges.nim``'s ``detectReproBinaryUsage``, which
  ## substring-scans sources to decide ``requiresReproBinary``.
  ReprobuildRepoRoot / "build" / "bin" / hostBinaryName(stem)

proc describeBinaryFormat*(path: string): string =
  ## A diagnostic that names what is actually on disk, for the failure
  ## message of ``requireHostBinary``.
  case binaryFormatOf(path)
  of hbfMissing: "missing"
  of hbfUnknown: "not a recognised executable image"
  of hbfElf: "ELF (Linux)"
  of hbfPe: "PE (Windows)"
  of hbfMachO: "Mach-O (macOS)"

proc requireHostBinary*(path: string): string {.discardable.} =
  ## Prove the binary about to be executed is THIS platform's — presence is
  ## not the property. Deliberately ``doAssert`` and not ``check``: this is
  ## called from helper procs, and on stock Nim 2.2.8 (the Windows pin) a
  ## ``check`` outside a ``test`` body prints and then reports ``[OK]``.
  let actual = binaryFormatOf(path)
  doAssert actual != hbfMissing,
    "required binary not found: " & path &
    "\n  build it with `just bootstrap` (or `bash scripts/build_apps.sh`)."
  doAssert actual == hostBinaryFormat(),
    "wrong machine format for this host: " & path &
    "\n  on disk: " & describeBinaryFormat(path) &
    "\n  required: " & (case hostBinaryFormat()
                        of hbfPe: "PE (Windows)"
                        of hbfMachO: "Mach-O (macOS)"
                        else: "ELF (Linux)") &
    "\n  `build/` is gitignored and shared across platforms on this host," &
    " so an artefact of the other platform can occupy this path."
  path

proc executableFile*(path: string): bool =
  if path.len == 0 or not fileExists(path):
    return false
  when defined(posix):
    let perms = getFilePermissions(path)
    result = fpUserExec in perms or fpGroupExec in perms or fpOthersExec in perms
  else:
    result = true

proc executableFromEnvOrPath*(envName, exeName: string): string =
  ## Resolve a test fixture executable from an explicit environment variable
  ## first, then PATH. Returns the empty string when neither location works.
  let fromEnv = getEnv(envName)
  if fromEnv.len > 0:
    if fileExists(fromEnv) and not executableFile(fromEnv):
      raise newException(OSError, envName & " is not executable: " & fromEnv)
    if executableFile(fromEnv):
      return normalizedPath(fromEnv)
  let fromPath = findExe(exeName)
  if fromPath.len > 0:
    return normalizedPath(fromPath)
  ""

proc workspaceRootForRepo*(repoRoot: string): string

proc runquotaSourceRoot*(repoRoot: string): string =
  ## Locate a built runquota checkout for tests that need to spawn their own
  ## daemon. The full test harness may run from a temporary reprobuild
  ## worktree, so ``repoRoot.parentDir / "runquota"`` is not always valid.
  let fromEnv = getEnv("RUNQUOTA_SRC")
  let sibling = repoRoot.parentDir / "runquota"
  let workspaceSibling = workspaceRootForRepo(repoRoot) / "runquota"
  if fromEnv.len > 0 and dirExists(fromEnv):
    let normalized = normalizedPath(fromEnv)
    let envDaemon = normalized / "build" / "bin" /
      addFileExt("runquotad", ExeExt)
    if not normalized.startsWith("/nix/store/") or fileExists(envDaemon):
      return normalized
  if dirExists(workspaceSibling):
    return normalizedPath(workspaceSibling)
  if dirExists(sibling):
    return normalizedPath(sibling)
  if fromEnv.len > 0 and dirExists(fromEnv):
    return normalizedPath(fromEnv)
  ""

proc absoluteCandidate(base, path: string): string =
  if path.len == 0:
    return ""
  if path.isAbsolute:
    normalizedPath(path)
  else:
    normalizedPath(base / path)

proc isCodeTracerSourceRoot(path: string): bool =
  path.len > 0 and
    fileExists(path / "src" / "frontend" / "tests" /
      "ipc_registry_test.nim") and
    fileExists(path / "test-programs" / "c_sudoku_solver" / "main.c")

proc gitCommonDir(repoRoot: string): string =
  try:
    let process = startProcess("git", workingDir = repoRoot,
      args = ["rev-parse", "--path-format=absolute", "--git-common-dir"],
      options = {poUsePath, poStdErrToStdOut})
    defer: process.close()
    let output =
      if process.outputStream != nil: process.outputStream.readAll()
      else: ""
    if process.waitForExit() == 0:
      result = output.strip()
  except OSError:
    discard

proc hasKnownWorkspaceSibling(path: string): bool =
  dirExists(path / "reprobuild-examples") or
    dirExists(path / "reprobuild-cmake") or
    dirExists(path / "runquota") or
    isCodeTracerSourceRoot(path / "codetracer")

proc repoManagedWorkspace(commonDir: string): string =
  ## Android ``repo`` keeps project Git directories below
  ## ``<workspace>/.repo/projects`` (or ``project-objects``). A linked
  ## worktree's common dir therefore cannot use the ordinary
  ## ``<repo>/.git -> <workspace>`` parent walk.
  let portable = commonDir.replace('\\', '/')
  for marker in ["/.repo/projects/", "/.repo/project-objects/"]:
    let markerPos = portable.find(marker)
    if markerPos > 0:
      return normalizedPath(commonDir[0 ..< markerPos])

proc workspaceRootForRepo*(repoRoot: string): string =
  ## Locate the workspace root that owns ``repoRoot`` and its sibling repos.
  ## A temporary Git worktree may live outside the repo-managed workspace; in
  ## that case ``repoRoot.parentDir`` is only the temp parent. Follow the Git
  ## common dir back to the primary checkout and use its parent as the
  ## workspace root.
  let direct = repoRoot.parentDir
  let commonDir = gitCommonDir(repoRoot)
  if commonDir.len > 0:
    let repoWorkspace = repoManagedWorkspace(commonDir)
    if repoWorkspace.len > 0 and dirExists(repoWorkspace):
      return repoWorkspace
    let workspace = commonDir.parentDir.parentDir
    if hasKnownWorkspaceSibling(workspace):
      return normalizedPath(workspace)

  if hasKnownWorkspaceSibling(direct):
    return normalizedPath(direct)

  normalizedPath(direct)

proc codeTracerSourceRoot*(repoRoot: string): string =
  ## Locate a Codetracer checkout for integration tests that copy a small,
  ## real source subset. Tests may run from a temporary reprobuild worktree, so
  ## the normal sibling checkout is not always adjacent to ``repoRoot``.
  var candidates: seq[string]

  let envRoot = getEnv("CODETRACER_ROOT")
  if envRoot.len > 0:
    candidates.add(absoluteCandidate(repoRoot, envRoot))

  let envSrc = getEnv("CODETRACER_SRC")
  if envSrc.len > 0:
    let sourcePath = absoluteCandidate(repoRoot, envSrc)
    candidates.add(sourcePath)
    candidates.add(sourcePath.parentDir)

  candidates.add(repoRoot.parentDir / "codetracer")
  candidates.add(workspaceRootForRepo(repoRoot) / "codetracer")

  let commonDir = gitCommonDir(repoRoot)
  if commonDir.len > 0:
    candidates.add(commonDir.parentDir.parentDir / "codetracer")

  for candidate in candidates:
    if isCodeTracerSourceRoot(candidate):
      return normalizedPath(candidate)

proc requireCodeTracerSourceRoot*(repoRoot: string): string =
  result = codeTracerSourceRoot(repoRoot)
  if result.len == 0:
    raise newException(OSError,
      "Codetracer checkout missing; set CODETRACER_ROOT to the checkout " &
      "root or CODETRACER_SRC to its src directory")

proc resolveRunQuotaExecutable*(repoRoot, envName, exeName: string): string =
  ## Resolve runquota tools from env/PATH first, then a built source checkout.
  let executableName = addFileExt(exeName, ExeExt)
  result = executableFromEnvOrPath(envName, executableName)
  if result.len > 0:
    return
  let src = runquotaSourceRoot(repoRoot)
  if src.len > 0:
    let candidate = src / "build" / "bin" / executableName
    if fileExists(candidate) and not executableFile(candidate):
      raise newException(OSError,
        "runquota source candidate is not executable: " & candidate)
    if executableFile(candidate):
      return normalizedPath(candidate)

proc requireRunQuotaSourceRoot*(repoRoot: string): string =
  ## A runquota checkout is a declared fixture dependency for cross-project
  ## build cases. Resolve it through the canonical workspace identity so a
  ## linked reprobuild worktree still reaches the workspace's runquota member;
  ## absence is a hard, actionable fixture error rather than a skipped test.
  result = runquotaSourceRoot(repoRoot)
  if result.len == 0:
    raise newException(OSError,
      "runquota checkout missing; set RUNQUOTA_SRC or add runquota to the " &
      "workspace that owns " & repoRoot)

proc requireRunQuotaDaemonBin*(repoRoot: string): string =
  result = resolveRunQuotaExecutable(repoRoot, "RUNQUOTAD_BIN", "runquotad")
  if result.len == 0:
    raise newException(OSError,
      "runquotad binary missing; set RUNQUOTAD_BIN, put runquotad on PATH, " &
      "or set RUNQUOTA_SRC to a built runquota checkout")

proc requireRunQuotaCliBin*(repoRoot: string): string =
  result = resolveRunQuotaExecutable(repoRoot, "RUNQUOTA_BIN", "runquota")
  if result.len == 0:
    raise newException(OSError,
      "runquota binary missing; set RUNQUOTA_BIN, put runquota on PATH, " &
      "or set RUNQUOTA_SRC to a built runquota checkout")

type
  MonitorTools* = object
    monitorCliPath*: string
    monitorCliArgs*: seq[string]
    shim*: string

proc ctInterposeSrcPath*(repoRoot: string): string =
  ## Locate the stackable-hooks source tree the Windows monitor shim
  ## depends on. The legacy name is preserved (used by 25+ existing
  ## tests) so callers don't need a rename pass — the source-of-truth
  ## moved from codetracer-native-recorder/ct_interpose to
  ## metacraft-labs/nim-stackable-hooks, but the resolver shape is
  ## unchanged. Honours ``STACKABLE_HOOKS_SRC`` (the same env knob
  ## ``scripts/build_apps.sh`` and ``env.ps1`` honour), then falls
  ## back to the sibling checkout (Incremental-Test-Runner M7 removed the
  ## former in-tree ``repro_monitor_shim/vendor`` copy).
  ## Returns the empty string when nothing is found — the caller's
  ## compileNim call will then surface the missing
  ## ``stackable_hooks.nim`` path as a normal compile error rather
  ## than silently degrading.
  let explicit = getEnv("STACKABLE_HOOKS_SRC")
  if explicit.len > 0 and dirExists(explicit):
    return explicit
  # Incremental-Test-Runner M7: the monitor shim moved to the io-mon sibling;
  # nim-stackable-hooks is resolved from $STACKABLE_HOOKS_SRC then the sibling
  # checkout (the deleted ``repro_monitor_shim/vendor`` fallback is gone).
  let sibling = repoRoot.parentDir / "nim-stackable-hooks" / "src"
  if dirExists(sibling):
    return sibling
  ""

type MissingTestFixtureError* = object of CatchableError

proc reproBinaryPath*(repoRoot: string): string =
  ## Absolute path to the graph-built ``repro`` CLI inside ``repoRoot``,
  ## produced by build-graph edge ``reprobuild.apps.repro``. Every helper
  ## in this module that needs the CLI goes through here.
  ##
  ## That funnel is load-bearing, not tidiness.
  ## ``scripts/repro_binary_reachability.nim`` decides which tests get
  ## ``build/bin/repro`` declared as a typed input on their EXECUTE edge,
  ## and it SEEDS on a source spelling the binary's location — this one.
  ## Taint then propagates along symbol references, so a test that only
  ## calls ``prepareMonitorTools`` still gets the dependency, and a
  ## rebuild of the CLI invalidates it instead of the engine serving the
  ## test as up to date against a stale binary.
  ##
  ## Consequence for anyone adding a helper here: resolve the CLI through
  ## this proc and the analysis follows you for free. Assemble the path
  ## some other way and every test calling your helper silently loses its
  ## dependency on the binary.
  ##
  ## Spelled componentwise rather than by joining a ``"build/bin/repro"``
  ## const so the result carries the host path separator — callers compare
  ## this against paths they built the same way, and on Windows the two
  ## spellings are not equal.
  repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)

proc requireBinary*(path, edgeName: string): string {.discardable.} =
  ## Test-Fixtures-In-Build-Graph: assert that a graph-built fixture binary
  ## already exists, instead of compiling it at test runtime. Returns ``path``
  ## on success; raises ``MissingTestFixtureError`` with a fail-fast diagnostic
  ## (the expected path + the build-graph edge that produces it) otherwise.
  ##
  ## Fixtures (the ``repro`` binary, the monitor shim, fixture providers, …)
  ## are built by ``repro build test`` as graph edges and are cached across
  ## runs; test code must depend on them and assert their presence here, never
  ## invoke a compiler. This replaces the per-test ``proc compileNim`` shell-outs
  ## (see ``Test-Fixtures-In-Build-Graph.md``).
  if not fileExists(path):
    raise newException(MissingTestFixtureError,
      "required test fixture binary not found: " & path & "\n" &
      "  it is produced by build-graph edge '" & edgeName & "'.\n" &
      "  run `repro build test` (which builds the fixture) before this test, " &
      "or declare that edge as a dependency of this test's execute edge.")
  path

proc monitorShimPath*(repoRoot: string): string =
  ## Test-Fixtures-In-Build-Graph M2: the stable on-disk location of the
  ## graph-built monitor-shim library. This is the exact path
  ## ``scripts/build_apps.sh`` writes and the ``test-fixtures`` collection
  ## in ``repro.nim`` (edge ``reprobuild.test_fixtures.monitor_shim``)
  ## produces, so ``prepareMonitorTools`` and the self-shim outlier tests
  ## resolve the same artifact rather than each compiling their own copy.
  ## Centralised here so the path convention lives in one place.
  let libDir = repoRoot / "build" / "lib"
  when defined(linux): libDir / "librepro_monitor_shim.so"
  elif defined(windows): libDir / "librepro_monitor_shim.dll"
  else: libDir / "librepro_monitor_shim.dylib"

proc prepareMonitorTools*(repoRoot, tempRoot, cacheKey: string): MonitorTools =
  ## Resolve the graph-built ``repro`` monitor driver and monitor shim.
  ##
  ## Test-Fixtures-In-Build-Graph M2: the monitor shim is no longer
  ## compiled here. It is produced once by the
  ## ``reprobuild.test_fixtures.monitor_shim`` graph edge (the
  ## ``test-fixtures`` collection in ``repro.nim``, built by
  ## ``scripts/run_tests.sh`` before the suite runs) at the stable path
  ## ``monitorShimPath`` returns; this proc asserts its presence via
  ## ``requireBinary`` instead of shelling out to ``nim c --app:lib`` on
  ## every call. The io-monitor driver is the graph-built ``repro`` binary
  ## reached through ``internal io monitor``; tests must not synthesize or
  ## compile a standalone monitor wrapper at runtime.
  ##
  discard tempRoot
  discard cacheKey
  result.monitorCliPath = requireBinary(
    reproBinaryPath(repoRoot),
    "reprobuild.apps.repro")
  result.monitorCliArgs = ioMonitorCliArgs
  result.shim = requireBinary(monitorShimPath(repoRoot),
    "reprobuild.test_fixtures.monitor_shim")
