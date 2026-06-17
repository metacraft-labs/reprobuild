import std/[locks, os, osproc, streams, strutils, tables]

type
  HostPlatform* = object
    os*: string
    cpu*: string

proc currentHost*(): HostPlatform =
  HostPlatform(os: hostOS, cpu: hostCPU)

# ---------------------------------------------------------------------------
# MSVC dev-env activation (MR8)
# ---------------------------------------------------------------------------
#
# Mirrors env.ps1's ``Activate-VsDevEnvForSwift`` (env.ps1 lines 683-1001):
# find ``vswhere.exe``, query the latest VS install with the
# ``Microsoft.VisualStudio.Component.VC.Tools.x86.x64`` component, invoke
# ``Common7\Tools\VsDevCmd.bat -arch=x64 -host_arch=x64 -no_logo && set``
# through ``cmd.exe`` and capture the resulting env diff as a Table.
#
# Why this exists inside reprobuild and not in env.ps1:
# the reprobuild daemon spawns user-facing actions (cargo / cc-rs / cl /
# link / etc.) from its own process tree. Without VsDevCmd in the daemon
# environment, cc-rs picks ``gcc.exe`` from the engine's tool-store
# gcc-winlibs prefix, emits ``.o`` files referencing gcc helpers like
# ``___chkstk_ms``, and the downstream MSVC ``link.exe`` then fails with
# ``LNK2001: unresolved external symbol ___chkstk_ms`` while linking
# Rust test executables. Activating VsDevCmd puts ``cl.exe`` on PATH so
# cc-rs uses the MSVC compiler end-to-end and the link step resolves.
#
# Cached for the lifetime of the host process (typically the
# ``runquotad`` / ``repro`` daemon): VsDevCmd activation costs ~2-3s on
# a warm cache, and an in-process daemon may run thousands of actions —
# we pay it once. A ``Once``-style guard plus a lock protects against
# concurrent first-callers. Result is an ``Option``-shaped pair so
# repeated failure attempts (no VS installed) are not retried per call.

type
  MsvcDevEnv* = object
    available*: bool
    env*: Table[string, string]
      ## Key/value diff produced by ``VsDevCmd.bat``. Empty when
      ## ``available`` is ``false`` (no VS Build Tools detected or
      ## activation failed). Callers should merge this on top of their
      ## desired base env, allowing their own overrides to win.

when defined(windows):
  var msvcDevEnvLock: Lock
  var msvcDevEnvCached {.guard: msvcDevEnvLock.}: MsvcDevEnv
  var msvcDevEnvComputed {.guard: msvcDevEnvLock.}: bool
  initLock(msvcDevEnvLock)

proc warnOnce(message: string) =
  ## Emit an activation-failure diagnostic. ``computeMsvcDevEnvLocked``
  ## only ever invokes this once per daemon lifetime (the cache flag
  ## is set unconditionally), so the call name is literal — no manual
  ## deduplication required.
  ##
  ## We write to stderr AND to ``$TEMP/repro-msvc-activation.log``
  ## because the user daemon's Windows launch path passes
  ## ``poDaemon`` to ``startProcess`` (repro_daemon_core/runtime.nim
  ## ~line 1708), which detaches stdin / stdout / stderr from the
  ## launcher. A stderr line written from the daemon's address space
  ## therefore vanishes; the temp-file mirror gives the user a path
  ## to the failure reason when ``repro build`` reports a downstream
  ## LNK2001 / "cl.exe not found" and they need to know *why* the
  ## auto-activation didn't kick in (no VS Build Tools, vswhere
  ## missing, VsDevCmd.bat failed, etc.).
  try:
    stderr.writeLine("repro: " & message)
    stderr.flushFile()
  except IOError:
    discard
  try:
    let diagPath = getTempDir() / "repro-msvc-activation.log"
    let prev =
      try: readFile(diagPath)
      except CatchableError: ""
    writeFile(diagPath, prev & "repro: " & message & "\n")
  except CatchableError: discard

when defined(windows):
  proc readSetOutputFile(path: string): seq[string] =
    ## Read the ``set`` dump that ``VsDevCmd.bat`` writes via ``> tempFile``.
    ## Each ``KEY=VALUE`` line is returned verbatim; blank lines are
    ## filtered. cmd.exe writes the file as CP1252 / OEM by default but
    ## env names + values are ASCII for the variables we consume here
    ## (PATH / INCLUDE / LIB / LIBPATH / VS* / WindowsSdk* / VCTools* /
    ## UCRT* / etc.).
    if not fileExists(path):
      return @[]
    var raw: string
    try:
      raw = readFile(path)
    except IOError:
      return @[]
    for line in raw.splitLines:
      let stripped = line.strip(leading = false, trailing = true)
      if stripped.len == 0:
        continue
      if stripped.find('=') <= 0:
        continue
      result.add(stripped)

  proc locateVsWhere(): string =
    ## ``vswhere.exe`` ships with the VS Installer at a stable path under
    ## ``${ProgramFiles(x86)}``. We do not probe PATH because env.ps1
    ## activation isn't running (that's the whole point of MR8) and
    ## clean-shell PATH wouldn't have it.
    let pfx86 = getEnv("ProgramFiles(x86)")
    if pfx86.len == 0:
      return ""
    let candidate = pfx86 / "Microsoft Visual Studio" / "Installer" /
      "vswhere.exe"
    if fileExists(candidate):
      return candidate
    ""

  proc queryVsInstallPath(vswhere: string): string =
    ## Run ``vswhere -latest -products * -requires
    ## Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property
    ## installationPath``. Returns the first non-empty line of stdout, or
    ## "" on any failure.
    let (output, exitCode) = execCmdEx(quoteShell(vswhere) &
      " -latest -products * -requires " &
      "Microsoft.VisualStudio.Component.VC.Tools.x86.x64 " &
      "-property installationPath")
    if exitCode != 0:
      return ""
    for line in output.splitLines:
      let stripped = line.strip()
      if stripped.len > 0:
        return stripped
    ""

  proc invokeVsDevCmd(vsDevCmd: string): seq[string] =
    ## Write a tiny ``.bat`` wrapper that invokes ``VsDevCmd.bat`` then
    ## dumps ``set`` to ``tmpFile`` (with VsDevCmd's own stdout / stderr
    ## routed to ``vsdevcmdLog``), and execute the wrapper via
    ## ``cmd.exe /D /C wrapper.bat``. The wrapper indirection sidesteps
    ## the per-arg quoting that ``startProcess`` performs on Windows:
    ## passing the whole command as one ``/C`` argument led
    ## ``buildCommandLine`` to escape every embedded ``"`` as ``\"``,
    ## which ``cmd.exe`` does not understand inside its own quoting
    ## rules and refused to recognise the ``VsDevCmd.bat`` path
    ## (``'\"...VsDevCmd.bat\"' is not recognized as an internal or
    ## external command``). Writing the literal cmd lines into a
    ## ``.bat`` file bypasses the round-trip entirely and matches the
    ## pattern env.ps1 (lines 845-877) uses on the PowerShell side.
    let cmdExe = getEnv("SystemRoot") / "System32" / "cmd.exe"
    if not fileExists(cmdExe):
      warnOnce("MSVC dev-env activation skipped: " & cmdExe & " not found")
      return @[]
    let tmpDir = getTempDir()
    let tmpFile = tmpDir / ("repro-vsdevcmd-" & $getCurrentProcessId() &
      ".env")
    let vsdevcmdLog = tmpFile & ".vsdevcmd.log"
    let wrapperBat = tmpFile & ".wrapper.bat"
    defer:
      try: removeFile(tmpFile)
      except OSError: discard
      try: removeFile(vsdevcmdLog)
      except OSError: discard
      try: removeFile(wrapperBat)
      except OSError: discard
    # ``@echo off`` keeps the wrapper itself silent; the inner
    # ``> log 2>&1`` captures VsDevCmd's own chatter so a failure
    # surfaces in the diagnostic log. ``set 2>nul > tmpFile`` writes
    # the env diff; combined exit code falls through to the wrapper's
    # exit, which cmd.exe propagates back to us.
    try:
      writeFile(wrapperBat,
        "@echo off\r\n" &
        "call \"" & vsDevCmd & "\" -arch=x64 -host_arch=x64 -no_logo " &
        "> \"" & vsdevcmdLog & "\" 2>&1\r\n" &
        "if errorlevel 1 exit /b %errorlevel%\r\n" &
        "set 2>nul > \"" & tmpFile & "\"\r\n")
    except IOError as e:
      warnOnce("MSVC dev-env activation: failed to write wrapper " &
        wrapperBat & ": " & e.msg)
      return @[]
    var process: Process
    try:
      process = startProcess(cmdExe,
                             args = @["/D", "/C", wrapperBat],
                             options = {poUsePath, poParentStreams})
    except OSError as e:
      warnOnce("MSVC dev-env activation: failed to launch cmd.exe: " &
        e.msg)
      return @[]
    let exitCode = process.waitForExit()
    process.close()
    if exitCode != 0:
      var detail = ""
      try:
        detail = readFile(vsdevcmdLog)
      except CatchableError: discard
      warnOnce("MSVC dev-env activation: VsDevCmd.bat exited " &
        $exitCode & "; output:\n" & detail)
      return @[]
    result = readSetOutputFile(tmpFile)

  proc computeMsvcDevEnvLocked(): MsvcDevEnv {.gcsafe.} =
    ## First-callers (under ``msvcDevEnvLock``) materialise the env diff.
    ## The cache flag is set unconditionally — even on failure — so the
    ## next caller doesn't re-probe a host that lacks VS Build Tools.
    let vswhere = locateVsWhere()
    if vswhere.len == 0:
      warnOnce("MSVC dev-env activation skipped: vswhere.exe not found " &
        "under ${ProgramFiles(x86)}\\Microsoft Visual Studio\\Installer. " &
        "Install Visual Studio Build Tools 2022 to enable cargo/cc-rs " &
        "tests in clean-shell mode.")
      return MsvcDevEnv(available: false)

    let vsInstall = queryVsInstallPath(vswhere)
    if vsInstall.len == 0:
      warnOnce("MSVC dev-env activation skipped: vswhere reported no " &
        "VS install with VC.Tools.x86.x64.")
      return MsvcDevEnv(available: false)

    let vsDevCmd = vsInstall / "Common7" / "Tools" / "VsDevCmd.bat"
    if not fileExists(vsDevCmd):
      warnOnce("MSVC dev-env activation skipped: " & vsDevCmd & " missing.")
      return MsvcDevEnv(available: false)

    let envLines = invokeVsDevCmd(vsDevCmd)
    if envLines.len == 0:
      return MsvcDevEnv(available: false)

    # Denylist matches env.ps1 line 902. ``PROMPT`` would re-style the
    # daemon's shell prompt if exported to a child shell; ``_`` /
    # ``PWD`` / ``OLDPWD`` are bash-isms that VsDevCmd's cmd.exe parent
    # does not really own; filtering them mirrors env.ps1's behaviour
    # so the two activation paths stay observationally identical.
    const Denylist = ["PROMPT", "_", "PWD", "OLDPWD"]
    var table = initTable[string, string]()
    for entry in envLines:
      let eq = entry.find('=')
      if eq <= 0:
        continue
      let key = entry[0 ..< eq]
      var skip = false
      for banned in Denylist:
        if cmpIgnoreCase(key, banned) == 0:
          skip = true
          break
      if skip:
        continue
      table[key] = entry[eq + 1 .. ^1]
    if table.len == 0:
      warnOnce("MSVC dev-env activation: VsDevCmd.bat produced no " &
        "usable variables.")
      return MsvcDevEnv(available: false)
    # Force cc-rs / cmake / make-style toolchains to the MSVC compiler
    # for any subprocess that consults these conventional env vars.
    # VsDevCmd itself does NOT set ``CC`` / ``CXX`` / ``AR`` (it only
    # places ``cl.exe`` / ``lib.exe`` on ``PATH``); without these
    # explicit overrides, an inherited ``CC=...\gcc.exe`` set earlier
    # by ``ensureBootstrapToolchainEnv`` (repro_tool_profiles.nim
    # line 2046) for nim's interface-extract step would still be
    # active when cargo / cc-rs probe the C compiler, and cc-rs would
    # mis-detect the toolchain as GNU even on an MSVC target — the
    # exact failure the MR8 LNK2001 ``___chkstk_ms`` trace pointed
    # at. ``cl.exe`` / ``lib.exe`` resolve through the PATH entries
    # VsDevCmd added (``VC\Tools\MSVC\*\bin\HostX64\x64``).
    table["CC"] = "cl.exe"
    table["CXX"] = "cl.exe"
    table["AR"] = "lib.exe"
    # MR11: pin the MSVC linker via the absolute path published by
    # VsDevCmd (``VCToolsInstallDir``) instead of trusting bare
    # ``link.exe`` PATH resolution. rustc's host-target link step
    # (proc-macro / build-script compiles such as ``portable-atomic``)
    # invokes ``link.exe`` via cargo, and on clean-shell Windows the
    # PATH inherited by the spawned action retains Git for Windows'
    # ``<git>\usr\bin\link.exe`` (the GNU coreutils ``link`` file-link
    # utility) ahead of the MSVC linker the VsDevCmd activation just
    # prepended. The GNU ``link`` then fails on cargo's argv with
    # ``extra operand '<obj>.rcgu.o'`` and the build aborts. Cargo
    # honours ``CARGO_TARGET_<TRIPLE>_LINKER`` as an absolute override,
    # which sidesteps any PATH shadowing for the rest of the daemon's
    # lifetime. The triple ``x86_64-pc-windows-msvc`` is the only host
    # triple this VsDevCmd activation targets (the wrapper invokes
    # ``-arch=x64 -host_arch=x64``), so a triple-specific override is
    # sufficient — it leaves cross-compiles to other targets alone.
    # Mirrors env.ps1's CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER
    # export so the daemon-spawned action env and a developer's
    # env.ps1-activated shell land on byte-identical linker bytes.
    let vcToolsDir = table.getOrDefault("VCToolsInstallDir", "")
    if vcToolsDir.len > 0:
      let msvcLink = vcToolsDir / "bin" / "Hostx64" / "x64" / "link.exe"
      if fileExists(msvcLink):
        table["CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER"] = msvcLink
      else:
        warnOnce("MSVC dev-env activation: VCToolsInstallDir=" &
          vcToolsDir & " did not contain bin\\Hostx64\\x64\\link.exe; " &
          "cargo may pick up a foreign link.exe from PATH.")
    else:
      warnOnce("MSVC dev-env activation: VsDevCmd did not publish " &
        "VCToolsInstallDir; CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER " &
        "not pinned. cargo may pick up a foreign link.exe from PATH.")
    MsvcDevEnv(available: true, env: table)

proc activateMsvcDevEnv*(): MsvcDevEnv =
  ## Resolve the MSVC dev-env diff once per host process and return the
  ## cached value on every subsequent call. On non-Windows hosts always
  ## returns ``MsvcDevEnv(available: false)``. Safe to call from multiple
  ## threads (the daemon's per-action launch loop may); the first caller
  ## pays the ~2-3s ``vswhere`` + ``VsDevCmd.bat`` cost.
  when defined(windows):
    {.gcsafe.}:
      withLock msvcDevEnvLock:
        if not msvcDevEnvComputed:
          msvcDevEnvCached = computeMsvcDevEnvLocked()
          msvcDevEnvComputed = true
        result = msvcDevEnvCached
  else:
    discard

proc msvcDevEnvAsArgvStyle*(devEnv: MsvcDevEnv): seq[string] =
  ## Convert ``devEnv.env`` into the ``KEY=VALUE`` argv-style sequence
  ## that ``BuildAction.env`` carries. Returns an empty seq when the
  ## diff is unavailable.
  if not devEnv.available:
    return @[]
  result = newSeqOfCap[string](devEnv.env.len)
  for key, value in devEnv.env.pairs:
    result.add(key & "=" & value)

proc mergeActionEnvWithMsvc*(actionEnv: openArray[string]):
    seq[string] =
  ## Prepend the cached MSVC dev-env diff to ``actionEnv`` so the
  ## action's own ``KEY=VALUE`` entries win for any overlapping keys.
  ## The argv-style env is consumed left-to-right by both
  ## ``envTableFromArgvStyle`` (bypass path) and the runquota helper's
  ## ``--env`` flags (which apply in argv order); duplicates with the
  ## same key are overwritten by the rightmost entry. No-op on
  ## non-Windows or when the MSVC env is unavailable.
  when defined(windows):
    let devEnv = activateMsvcDevEnv()
    if not devEnv.available:
      return @actionEnv
    result = msvcDevEnvAsArgvStyle(devEnv)
    for entry in actionEnv:
      result.add(entry)
  else:
    result = @actionEnv
