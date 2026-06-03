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
  result.output = process.outputStream.readAll()
  result.code = process.waitForExit()

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
  ## Locate the ct_interpose source tree the Windows monitor shim
  ## depends on. Honours ``CT_INTERPOSE_SRC`` (the same env knob
  ## ``scripts/build_apps.sh`` honours), then falls back to the
  ## codetracer-native-recorder sibling checkout, then the in-tree
  ## vendor copy. Returns the empty string when nothing is found —
  ## the caller's compileNim call will then surface the missing
  ## ``hook_registry.nim`` path as a normal compile error rather
  ## than silently degrading.
  let explicit = getEnv("CT_INTERPOSE_SRC")
  if explicit.len > 0 and dirExists(explicit):
    return explicit
  let sibling = repoRoot.parentDir / "codetracer-native-recorder" /
    "ct_interpose" / "src"
  if dirExists(sibling):
    return sibling
  let vendored = repoRoot / "libs" / "repro_monitor_shim" / "vendor" /
    "ct_interpose" / "src"
  if dirExists(vendored):
    return vendored
  ""

proc prepareMonitorTools*(repoRoot, tempRoot, cacheKey: string): MonitorTools =
  ## Compile the per-test ``repro-fs-snoop`` binary AND the monitor
  ## shim library on demand. The same surface that ``compileRepro``
  ## (above) uses for the per-test ``repro`` binary, but for the
  ## fs-snoop + shim pair.
  ##
  ## ``cacheKey`` differentiates per-suite ``nimcache`` directories
  ## so two dev-env suites compiled into the same process don't
  ## stomp each other's IR.
  let binDir = tempRoot / "bin"
  let libDir = tempRoot / "lib"
  createDir(binDir)
  createDir(libDir)
  result.fsSnoop = binDir / addFileExt("repro-fs-snoop", ExeExt)
  result.shim =
    when defined(linux): libDir / "librepro_monitor_shim.so"
    elif defined(windows): libDir / "repro_monitor_shim.dll"
    else: libDir / "librepro_monitor_shim.dylib"
  let shimSource =
    when defined(linux):
      repoRoot / "libs" / "repro_monitor_shim" / "src" /
        "repro_monitor_shim" / "linux_preload.nim"
    elif defined(windows):
      repoRoot / "libs" / "repro_monitor_shim" / "src" /
        "repro_monitor_shim" / "windows_interpose.nim"
    else:
      repoRoot / "libs" / "repro_monitor_shim" / "src" /
        "repro_monitor_shim" / "macos_interpose.nim"

  var shimArgs = @[
    "nim", "c", "--app:lib", "--threads:on", "--verbosity:0",
    "--hints:off", "--warnings:off",
    "--nimcache:" & repoRoot / "build" / "nimcache" /
      (cacheKey & "-monitor-shim"),
    "--out:" & result.shim
  ]
  when defined(windows):
    # Same shape as the Windows arm of ``scripts/build_apps.sh`` so
    # the in-test shim build picks up the IAT patcher's stack.
    let ctInterpose = ctInterposeSrcPath(repoRoot)
    shimArgs.add(["--mm:orc", "--cc:gcc",
      "--path:" & repoRoot / "libs" / "repro_monitor_depfile" / "src",
      "--path:" & repoRoot / "libs" / "repro_core" / "src",
      "--path:" & repoRoot / "libs" / "repro_monitor_shim" / "src"])
    if ctInterpose.len > 0:
      shimArgs.add("--path:" & ctInterpose)
  shimArgs.add(shimSource)
  discard requireSuccess(shellCommand(shimArgs), repoRoot)

  let fsSnoopArgs = @[
    "nim", "c", "--threads:on", "--verbosity:0", "--hints:off",
    "--warnings:off",
    "--nimcache:" & repoRoot / "build" / "nimcache" / (cacheKey & "-fs-snoop"),
    "--out:" & result.fsSnoop,
    repoRoot / "apps" / "repro-fs-snoop" / "repro_fs_snoop.nim"
  ]
  discard requireSuccess(shellCommand(fsSnoopArgs), repoRoot)
