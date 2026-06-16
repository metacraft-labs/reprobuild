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

when defined(windows):
  import std/winlean

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

  isFsSnoopSupported* = defined(linux) or defined(macosx) or defined(windows)
    ## True on platforms where the dev-env tests can wire in
    ## ``repro-fs-snoop`` and the monitor shim end-to-end.
    ##
    ## Windows uses an IAT-patching DLL injected via
    ## ``CreateProcess(CREATE_SUSPENDED)`` + ``CreateRemoteThread``
    ## (see ``libs/repro_monitor_shim/src/repro_monitor_shim/windows_interpose.nim``).
    ## The shim depends on ct_interpose's ``hook_registry`` —
    ## ``prepareMonitorTools`` below threads ``--path:<ct_interpose_src>``
    ## into the per-test ``compileNim`` invocation the same way
    ## ``scripts/build_apps.sh`` does for the production build.


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
    let outp = process.outputStream
    result.code = -1
    var line = newStringOfCap(120)
    while true:
      if outp.readLine(line):
        result.output.add(line)
        result.output.add("\n")
      else:
        result.code = process.peekExitCode()
        if result.code != -1:
          break

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
  ## right transport: a Unix-socket path under ``/tmp`` on POSIX, a
  ## Named-Pipe name in the kernel namespace on Windows. ``runquotad``
  ## auto-maps a ``.sock``-shaped argument to a deterministic
  ## ``\\.\pipe\runquota-<token>`` on Windows, but tests still need
  ## to thread the SAME string into ``RUNQUOTA_SOCKET`` so the client
  ## connects to the same instance.
  when defined(windows):
    r"\\.\pipe\runquotad-" & name.replace('\\', '_').replace('/', '_')
  else:
    "/tmp" / (name & ".sock")

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

type
  MonitorTools* = object
    fsSnoop*: string
    shim*: string

proc ctInterposeSrcPath*(repoRoot: string): string =
  ## Locate the stackable-hooks source tree the Windows monitor shim
  ## depends on. The legacy name is preserved (used by 25+ existing
  ## tests) so callers don't need a rename pass — the source-of-truth
  ## moved from codetracer-native-recorder/ct_interpose to
  ## metacraft-labs/nim-stackable-hooks, but the resolver shape is
  ## unchanged. Honours ``STACKABLE_HOOKS_SRC`` (the same env knob
  ## ``scripts/build_apps.sh`` and ``env.ps1`` honour), then falls
  ## back to the sibling checkout, then the in-tree vendor copy.
  ## Returns the empty string when nothing is found — the caller's
  ## compileNim call will then surface the missing
  ## ``stackable_hooks.nim`` path as a normal compile error rather
  ## than silently degrading.
  let explicit = getEnv("STACKABLE_HOOKS_SRC")
  if explicit.len > 0 and dirExists(explicit):
    return explicit
  let sibling = repoRoot.parentDir / "nim-stackable-hooks" / "src"
  if dirExists(sibling):
    return sibling
  let vendored = repoRoot / "libs" / "repro_monitor_shim" / "vendor" /
    "nim-stackable-hooks" / "src"
  if dirExists(vendored):
    return vendored
  ""

type MissingTestFixtureError* = object of CatchableError

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

proc fsSnoopWrapperSource*(repoRoot, cacheKey: string): string =
  ## Executable-Consolidation M1 deleted the standalone
  ## ``apps/repro-fs-snoop/repro_fs_snoop.nim`` entry point: the internal
  ## filesystem-monitor role now ships inside ``repro`` and is reached via
  ## ``repro internal fs-snoop`` (build/monitor self-spawn) or
  ## ``repro debug fs-snoop`` (user-facing). Tests that set ``REPRO_FS_SNOOP``
  ## to a standalone driver path still need a single-binary fs-snoop image
  ## whose argv is ``<bin> --depfile … -- <cmd>`` (no subcommand prefix). This
  ## synthesizes the same four-line wrapper the deleted entry point carried —
  ## ``runThinApp("repro-fs-snoop")`` routes through the retained compat
  ## program-name branch to the identical ``runFsSnoopCli`` path — and returns
  ## its path so callers can ``compileNim`` it exactly as they compiled the
  ## former source. The file is written UNDER ``repoRoot`` so Nim's
  ## ``config.nims`` path setup resolves as it did for the original source.
  let wrapperDir = repoRoot / "build" / "test-fs-snoop" / cacheKey
  createDir(wrapperDir)
  result = wrapperDir / "repro_fs_snoop.nim"
  writeFile(result,
    "import repro_cli_support\n\n" &
    "when isMainModule:\n" &
    "  quit runThinApp(\"repro-fs-snoop\")\n")

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
  ## Resolve the monitor shim (a graph-built ``test-fixtures`` artifact)
  ## and compile the per-test ``repro-fs-snoop`` binary on demand.
  ##
  ## Test-Fixtures-In-Build-Graph M2: the monitor shim is no longer
  ## compiled here. It is produced once by the
  ## ``reprobuild.test_fixtures.monitor_shim`` graph edge (the
  ## ``test-fixtures`` collection in ``repro.nim``, built by
  ## ``scripts/run_tests.sh`` before the suite runs) at the stable path
  ## ``monitorShimPath`` returns; this proc asserts its presence via
  ## ``requireBinary`` instead of shelling out to ``nim c --app:lib`` on
  ## every call. The fs-snoop wrapper compile (Executable-Consolidation
  ## M1) stays runtime for now — M3 hoists it.
  ##
  ## ``cacheKey`` differentiates per-suite ``nimcache`` directories
  ## so two dev-env suites compiled into the same process don't
  ## stomp each other's IR.
  let binDir = tempRoot / "bin"
  createDir(binDir)
  result.fsSnoop = binDir / addFileExt("repro-fs-snoop", ExeExt)
  result.shim = requireBinary(monitorShimPath(repoRoot),
    "reprobuild.test_fixtures.monitor_shim")

  # Executable-Consolidation M1: compile the synthesized fs-snoop wrapper
  # (see ``fsSnoopWrapperSource``) instead of the deleted standalone entry
  # point source.
  let fsSnoopArgs = @[
    "nim", "c", "--threads:on", "--verbosity:0", "--hints:off",
    "--warnings:off",
    "--nimcache:" & repoRoot / "build" / "nimcache" / (cacheKey & "-fs-snoop"),
    "--out:" & result.fsSnoop,
    fsSnoopWrapperSource(repoRoot, cacheKey)
  ]
  discard requireSuccess(shellCommand(fsSnoopArgs), repoRoot)
