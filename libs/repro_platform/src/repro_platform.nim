import std/[locks, os, osproc, streams, strtabs, strutils, tables]

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
      ## The variables ``VsDevCmd.bat`` SET OR CHANGED, with the values it
      ## gave them (``msvcDevEnvFromActivation``), plus the engine's
      ## ``CC`` / ``CXX`` / ``AR`` / linker overrides. Never the rest of the
      ## environment the activation ran in: that would be a snapshot of the
      ## host taken once per process, layered over every later launch. Empty
      ## when ``available`` is ``false`` (no VS Build Tools detected or
      ## activation failed) and for an inherited activation. Callers merge
      ## this under their own entries, which win.
    ownedLists*: Table[string, seq[string]]
      ## Search-list entries that belong to the MSVC / Windows SDK install,
      ## keyed by the upper-cased list variable (``PATH``, ``LIB``,
      ## ``INCLUDE``, ``LIBPATH``). Filled for an INHERITED activation and
      ## for a captured one (whose ``env`` then carries no search list); for
      ## a table built some other way it is derived from ``env`` on demand.
      ## ``mergeActionEnvWithMsvcEnv`` combines these with the value of the
      ## same variable the action declares or would inherit, instead of
      ## letting either replace the other.

const
  MsvcListKeys* = ["PATH", "LIB", "INCLUDE", "LIBPATH"]
    ## The semicolon-separated search lists VsDevCmd extends. ``cl.exe`` /
    ## ``link.exe`` are found through ``PATH``, and the compiler and linker
    ## then search ``INCLUDE`` / ``LIB`` / ``LIBPATH`` — an action that
    ## declares its own value for any of them needs the install's entries
    ## kept, exactly as for ``PATH``.
  MsvcRootKeys = ["VSINSTALLDIR", "VCINSTALLDIR", "VCToolsInstallDir",
    "VCIDEInstallDir", "DevEnvDir", "WindowsSdkDir", "WindowsSdkBinPath",
    "WindowsSdkVerBinPath", "UniversalCRTSdkDir", "ExtensionSdkDir",
    "NETFXSDKDir", "FrameworkDir", "FrameworkDir64", "FrameworkDIR64"]
    ## Variables whose values are install ROOTS of the MSVC toolchain and the
    ## Windows SDK. A search-list entry is MSVC-owned iff it lies under one.
  MsvcConsumerTools* = ["cl", "link", "lib", "ml", "ml64", "rc", "mt",
    "nmake", "msbuild", "msvc", "cmake", "ninja", "meson", "cc", "c++",
    "clang", "clang++", "clang-cl", "lld-link", "rust", "rustup", "cargo",
    "rustc", "rustdoc", "cargo-nextest", "cargo-clippy", "clippy-driver",
    "swift", "swiftc", "swift-build", "vccexe"]
    ## Tools that reach the MSVC toolchain through the ENVIRONMENT: they run
    ## ``cl.exe`` / ``link.exe`` found on ``PATH``, or let them search
    ## ``INCLUDE`` / ``LIB`` / ``LIBPATH``. ``cargo`` and ``rustc`` are here
    ## for the Rust ``cc`` crate (it trusts ``VCINSTALLDIR`` and then
    ## searches ``PATH`` alone) and for ``link.exe``; the build-system
    ## drivers because the compilers they configure need the search lists.
    ## A tool that locates Visual Studio by itself (``node-gyp`` through
    ## ``vswhere``) is not a consumer, and neither is a MinGW ``gcc``, which
    ## must not be handed ``CC=cl.exe``.

proc normalizedWinPath(p: string): string =
  ## Case-folded, backslash-separated, without a trailing separator — the
  ## identity Windows gives a directory in a search list.
  result = p.strip().replace('/', '\\').toLowerAscii()
  while result.len > 3 and result[^1] == '\\':
    result.setLen(result.len - 1)

proc envLookupIgnoreCase(env: Table[string, string]; key: string): string =
  for k, v in env.pairs:
    if cmpIgnoreCase(k, key) == 0:
      return v
  ""

proc msvcOwnedEntries*(value: string; roots: openArray[string]): seq[string] =
  ## The entries of the ``;``-separated list ``value`` that lie under one of
  ## ``roots`` (or are one), in order, deduplicated. Windows semantics on
  ## every host: case-insensitive, ``/`` and ``\\`` equivalent, a trailing
  ## separator ignored. ``C:\\BuildToolsX`` is not under ``C:\\BuildTools``.
  var normRoots: seq[string] = @[]
  for r in roots:
    let n = normalizedWinPath(r)
    if n.len > 0: normRoots.add(n)
  var seen: seq[string] = @[]
  for part in value.split(';'):
    let n = normalizedWinPath(part)
    if n.len == 0 or n in seen: continue
    for r in normRoots:
      if n == r or n.startsWith(r & "\\"):
        seen.add(n)
        result.add(part.strip())
        break

proc isMsvcConsumerTool*(tool: string): bool =
  ## Whether ``tool`` — a tool reference, a bare executable name or an
  ## absolute path to one — names an ``MsvcConsumerTools`` entry. The last
  ## path component is compared case-insensitively with a ``.exe`` /
  ## ``.cmd`` / ``.bat`` suffix dropped, splitting on ``/`` and ``\\`` on
  ## every host so the answer does not depend on where it is computed.
  var name = tool.strip()
  let slash = max(name.rfind('/'), name.rfind('\\'))
  if slash >= 0:
    name = name[slash + 1 .. ^1]
  name = name.toLowerAscii()
  for ext in [".exe", ".cmd", ".bat"]:
    if name.endsWith(ext):
      name.setLen(name.len - ext.len)
      break
  name.len > 0 and name in MsvcConsumerTools

proc msvcRootsOf(env: Table[string, string]): seq[string] =
  for key in MsvcRootKeys:
    let v = envLookupIgnoreCase(env, key)
    if v.len > 0: result.add(v)

proc inheritedMsvcDevEnv*(path: string; roots: openArray[string];
                          lib = ""; includes = ""; libpath = ""): MsvcDevEnv =
  ## The dev env of a process that already runs INSIDE an activation (a
  ## nested ``repro``). Nothing needs to be exported — the child inherits the
  ## variables — but an action that declares its own ``PATH`` replaces the
  ## inherited one, so the MSVC-owned entries of the inherited lists are
  ## recorded to be merged back in.
  result = MsvcDevEnv(available: true)
  let lists = [("PATH", path), ("LIB", lib), ("INCLUDE", includes),
    ("LIBPATH", libpath)]
  for (key, value) in lists:
    let owned = msvcOwnedEntries(value, roots)
    if owned.len > 0:
      result.ownedLists[key] = owned

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

proc parseCmdSetOutput*(raw: string): seq[string] =
  ## Split a ``cmd.exe`` ``set`` dump into ``KEY=VALUE`` entries. Each line
  ## is returned verbatim (trailing whitespace stripped); blank lines and
  ## lines without a name are filtered. cmd.exe writes the file as CP1252 /
  ## OEM by default but env names + values are ASCII for the variables we
  ## consume here (PATH / INCLUDE / LIB / LIBPATH / VS* / WindowsSdk* /
  ## VCTools* / UCRT* / etc.).
  ##
  ## ``set`` prints a value verbatim, so a value that spans lines is
  ## indistinguishable from several variables. That is why the activation
  ## shell never sees one: see ``vsDevCmdChildEnv``.
  for line in raw.splitLines:
    let stripped = line.strip(leading = false, trailing = true)
    if stripped.len == 0:
      continue
    if stripped.find('=') <= 0:
      continue
    result.add(stripped)

const VsDevCmdQuietEnv* = [("VSCMD_SKIP_SENDTELEMETRY", "1")]
  ## Variables the activation shell is started with so that ``VsDevCmd.bat``
  ## sets the toolchain variables and starts nothing else.
  ##
  ## Unless ``VSCMD_SKIP_SENDTELEMETRY`` is set, ``VsDevCmd.bat`` (VS 2022,
  ## ``Common7\Tools\VsDevCmd.bat``, the "Send Telemetry if user's VS is
  ## opted-in" block) runs ``START "" /B powershell.exe -NoProfile -Command
  ## "... Send-VsDevShellTelemetry ..."``: a DETACHED Windows PowerShell that
  ## can outlive the activation. Windows PowerShell resolves its known folders
  ## from the inherited ``%USERPROFILE%`` and creates
  ## ``%USERPROFILE%\AppData\Roaming`` when it is missing, even with
  ## ``APPDATA`` pointing elsewhere. The engine activates MSVC for every action
  ## that inherits the host's PATH (the build engine's
  ## ``actionUsesMsvcToolchain``), the profile compile edge among them, so
  ## each ``repro home facts`` / ``apply --plan`` / refused ``apply`` created
  ## two directories in the home it was only reading (reprobuild-pm issue
  ## 2026-10-23-windows-home-commands-create-appdata-roaming-under-userprofile).
  ##
  ## The telemetry contributes nothing to the environment that is captured,
  ## so skipping it loses nothing. Each name is added only when the parent
  ## does not set it (``vsDevCmdInjectedNames``), and
  ## ``msvcEnvTableFromSetLines`` drops the added ones again, so the captured
  ## table, which is layered over action environments, does not change.

proc vsDevCmdInjectedNames*(parent: openArray[(string, string)]): seq[string] =
  ## The ``VsDevCmdQuietEnv`` names that ``vsDevCmdChildEnv`` adds for
  ## ``parent``: those ``parent`` does not set, with names compared
  ## case-insensitively as Windows compares them. Pass them to
  ## ``msvcEnvTableFromSetLines`` so the additions stay out of the captured
  ## activation table.
  for (quietName, _) in VsDevCmdQuietEnv:
    var present = false
    for (name, _) in parent:
      if cmpIgnoreCase(name, quietName) == 0:
        present = true
        break
    if not present:
      result.add(quietName)

proc vsDevCmdChildEnv*(parent: openArray[(string, string)]):
    seq[(string, string)] =
  ## The environment the VsDevCmd activation shell is started with: the
  ## parent's, minus every variable whose value spans lines, plus every
  ## ``VsDevCmdQuietEnv`` variable the parent does not set.
  ##
  ## The activation's result is read back from a ``set`` dump, and ``set``
  ## frames nothing: a value ``A=1<newline>B=2`` comes back as a variable
  ## ``A`` holding ``1`` and an invented variable ``B`` holding ``2``. The
  ## captured table is layered over every action environment the engine
  ## launches, so such a value used to plant its continuation lines in every
  ## action as real variables. A multi-line ``KEY=VALUE`` list (one entry per
  ## line) is exactly the shape that silently overrode real settings that
  ## way. Leaving those variables out of the shell's environment loses
  ## nothing: VsDevCmd does not read them, the captured table then has no
  ## entry for them, and the action inherits each one intact from the
  ## launching process.
  ##
  ## Windows' hidden per-drive entries (``=C:=C:\dir``), which ``envPairs``
  ## reports with an empty name, are left out too: they cannot be named in an
  ## environment table, and the activation shell does not need them.
  for (name, value) in parent:
    if name.len == 0:
      continue
    if '\n' in value or '\r' in value:
      continue
    result.add((name, value))
  let injected = vsDevCmdInjectedNames(parent)
  for (name, value) in VsDevCmdQuietEnv:
    if name in injected:
      result.add((name, value))

const MsvcSetDenylist = ["PROMPT", "_", "PWD", "OLDPWD"]
  ## Denylist matches env.ps1 line 902. ``PROMPT`` would re-style the
  ## daemon's shell prompt if exported to a child shell; ``_`` /
  ## ``PWD`` / ``OLDPWD`` are bash-isms that VsDevCmd's cmd.exe parent
  ## does not really own; filtering them mirrors env.ps1's behaviour
  ## so the two activation paths stay observationally identical.

proc msvcEnvTableFromSetLines*(envLines: openArray[string];
                               injected: openArray[string] = []):
    Table[string, string] =
  ## The captured activation table: every ``KEY=VALUE`` entry of the ``set``
  ## dump, except the denylisted names and the ``injected`` ones, which are
  ## the ``VsDevCmdQuietEnv`` variables the engine itself gave the activation
  ## shell (``vsDevCmdInjectedNames``) and not part of the toolchain
  ## environment. Later duplicates win.
  result = initTable[string, string]()
  for entry in envLines:
    let eq = entry.find('=')
    if eq <= 0:
      continue
    let key = entry[0 ..< eq]
    var skip = false
    for banned in MsvcSetDenylist:
      if cmpIgnoreCase(key, banned) == 0:
        skip = true
        break
    for name in injected:
      if cmpIgnoreCase(key, name) == 0:
        skip = true
        break
    if skip:
      continue
    result[key] = entry[eq + 1 .. ^1]

proc msvcListKey(key: string): string =
  ## The ``MsvcListKeys`` spelling of ``key`` (matched case-insensitively,
  ## as Windows matches variable names), or "" when it is not a search list.
  for k in MsvcListKeys:
    if cmpIgnoreCase(k, key) == 0:
      return k
  ""

proc lookupPairIgnoreCase(pairs: openArray[(string, string)]; key: string):
    tuple[present: bool, value: string] =
  for (name, value) in pairs:
    if cmpIgnoreCase(name, key) == 0:
      return (true, value)
  (false, "")

proc msvcRootKey(key: string): bool =
  for k in MsvcRootKeys:
    if cmpIgnoreCase(k, key) == 0:
      return true
  false

proc msvcDevEnvFromActivation*(captured: Table[string, string];
                               baseline: openArray[(string, string)];
                               overrides: openArray[(string, string)] = []):
    MsvcDevEnv =
  ## The dev env a VsDevCmd activation contributes: what the activation shell
  ## ended with (``captured``, the ``set`` dump) compared with what it started
  ## with (``baseline``, this process's environment when the shell was
  ## launched), plus the engine's own ``overrides`` (``CC=cl.exe`` and the
  ## pinned linker), which are layered unconditionally: they are the engine's
  ## choice, not the activation's, and must hold even where the host happens
  ## to carry the same value (an isolated launch inherits none of it).
  ##
  ## * A variable whose captured value equals its baseline value is NOT part
  ##   of the activation and is left out. The activation is computed once per
  ##   process and layered over every action launched afterwards
  ##   (``mergeActionEnvWithMsvcEnv``); a full ``set`` dump would therefore
  ##   hand every later launch the host's environment AS IT WAS at the first
  ##   activation. That is what reprobuild-pm issue
  ##   2026-11-15-windows-profile-compile-edge-is-not-invalidated-when-appdata-changes
  ##   measured: ``APPDATA`` pointed somewhere new, and both the profile
  ##   compile's child (``nim``, which reads ``%APPDATA%\nim\nim.cfg``) and
  ##   the action-cache key (``actionEnvResolver`` mirrors the launch) still
  ##   saw the old value, so the compile was answered from the cache with the
  ##   user's configuration change ignored. Leaving such a variable out lets
  ##   the launch pass the value the host holds NOW, and the key read it.
  ## * A search list (``MsvcListKeys``) is never carried whole. VsDevCmd
  ##   prepends the toolchain to the value it inherited, so the captured value
  ##   is the toolchain PLUS a snapshot of the host's list. Only its
  ##   MSVC-owned entries (``msvcOwnedEntries`` under the activation's own
  ##   roots) are kept, in ``ownedLists``; the merge puts them in front of
  ##   the list the launch inherits, or after the one the action declares.
  ## * An install-root variable (``MsvcRootKeys``: ``VSINSTALLDIR``,
  ##   ``VCToolsInstallDir``, ``WindowsSdkDir``, ...) is kept even when the
  ##   host already held the same value. It names the install the owned
  ##   search-list entries were taken from, so it belongs to the activation
  ##   whatever the host held, and an isolated launch, which inherits none of
  ##   the host, still needs it (the Rust ``cc`` crate trusts
  ##   ``VCINSTALLDIR``).
  ## * Every other variable the activation set or changed is kept verbatim.
  ##   One the activation set to the value the host already held is
  ##   indistinguishable from a host variable it never touched, and is left
  ##   to the inherited environment.
  ##
  ## A variable the activation REMOVED cannot be expressed in a
  ## ``KEY=VALUE`` layer and was never applied; VsDevCmd removes none that
  ## the toolchain depends on.
  ##
  ## Pure, so the rule is tested on every host
  ## (``test_msvc_activation_tracks_the_host_environment``).
  result = MsvcDevEnv(available: true)
  let roots = msvcRootsOf(captured)
  for key, value in captured.pairs:
    let listKey = msvcListKey(key)
    if listKey.len > 0:
      let owned = msvcOwnedEntries(value, roots)
      if owned.len > 0:
        result.ownedLists[listKey] = owned
      continue
    let before = lookupPairIgnoreCase(baseline, key)
    if before.present and before.value == value and not msvcRootKey(key):
      continue
    result.env[key] = value
  for (key, value) in overrides:
    result.env[key] = value

when defined(windows):
  proc readSetOutputFile(path: string): seq[string] =
    ## Read the ``set`` dump that ``VsDevCmd.bat`` writes via ``> tempFile``.
    if not fileExists(path):
      return @[]
    var raw: string
    try:
      raw = readFile(path)
    except IOError:
      return @[]
    parseCmdSetOutput(raw)

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

  proc invokeVsDevCmd(vsDevCmd: string; injected: var seq[string];
                      parent: var seq[(string, string)]): seq[string] =
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
    ##
    ## ``injected`` receives the ``VsDevCmdQuietEnv`` names the shell was
    ## given on top of this process's environment; the caller drops them from
    ## the captured table. ``parent`` receives this process's environment as
    ## the shell inherited it: the baseline the caller compares the capture
    ## with (``msvcDevEnvFromActivation``).
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
      parent.setLen(0)
      for key, value in envPairs():
        parent.add((key, value))
      let shellEnv = newStringTable(modeCaseInsensitive)
      injected = vsDevCmdInjectedNames(parent)
      for (key, value) in vsDevCmdChildEnv(parent):
        shellEnv[key] = value
      process = startProcess(cmdExe,
                             args = @["/D", "/C", wrapperBat],
                             env = shellEnv,
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
    ##
    ## An inherited activation is honoured before anything is probed. When
    ## this process already runs inside a VsDevCmd-activated environment —
    ## which it does whenever an activation NESTS, as it does for a `just`
    ## recipe whose shell re-enters `repro exec` — the diff to apply is
    ## empty, because the environment the child inherits already carries it.
    ##
    ## That is not only an optimisation. Re-running the activation from
    ## inside one costs a `cmd.exe /D /C` with the full inherited
    ## environment, and cmd.exe truncates that block at 8191 characters: on
    ## a host with a long PATH the nested probe lost `ProgramFiles(x86)`,
    ## reported `'vswhere.exe' is not recognized` and `The input line is too
    ## long`, and left the caller without the toolchain it was already
    ## standing in.
    if getEnv("VCToolsInstallDir").len > 0 and getEnv("VSINSTALLDIR").len > 0:
      var roots: seq[string] = @[]
      for key in MsvcRootKeys:
        let v = getEnv(key)
        if v.len > 0: roots.add(v)
      return inheritedMsvcDevEnv(getEnv("PATH"), roots, getEnv("LIB"),
        getEnv("INCLUDE"), getEnv("LIBPATH"))

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

    var injected: seq[string] = @[]
    var parent: seq[(string, string)] = @[]
    let envLines = invokeVsDevCmd(vsDevCmd, injected, parent)
    if envLines.len == 0:
      return MsvcDevEnv(available: false)

    let table = msvcEnvTableFromSetLines(envLines, injected)
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
    var overrides = @[("CC", "cl.exe"), ("CXX", "cl.exe"), ("AR", "lib.exe")]
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
        overrides.add(("CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER", msvcLink))
      else:
        warnOnce("MSVC dev-env activation: VCToolsInstallDir=" &
          vcToolsDir & " did not contain bin\\Hostx64\\x64\\link.exe; " &
          "cargo may pick up a foreign link.exe from PATH.")
    else:
      warnOnce("MSVC dev-env activation: VsDevCmd did not publish " &
        "VCToolsInstallDir; CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER " &
        "not pinned. cargo may pick up a foreign link.exe from PATH.")
    msvcDevEnvFromActivation(table, parent, overrides)

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

proc ownedListFor(devEnv: MsvcDevEnv; key: string): seq[string] =
  if devEnv.ownedLists.hasKey(key):
    return devEnv.ownedLists[key]
  let value = envLookupIgnoreCase(devEnv.env, key)
  if value.len == 0: return @[]
  msvcOwnedEntries(value, msvcRootsOf(devEnv.env))

proc combineSearchList(actionValue: string; owned: seq[string]): string =
  ## The action's entries first, in its order — its tools keep precedence —
  ## followed by every MSVC-owned entry it does not already carry.
  var seen: seq[string] = @[]
  var parts: seq[string] = @[]
  for part in actionValue.split(';'):
    if part.len == 0: continue
    parts.add(part)
    seen.add(normalizedWinPath(part))
  for entry in owned:
    let n = normalizedWinPath(entry)
    if n notin seen:
      seen.add(n)
      parts.add(entry)
  parts.join(";")

proc prependOwnedEntries(owned: seq[string]; value: string): string =
  ## The MSVC-owned entries ``value`` does not already carry, in order, then
  ## ``value`` verbatim: what ``VsDevCmd.bat`` does to an inherited search
  ## list (the toolchain goes in front). A value that already carries every
  ## owned entry -- an inherited activation's -- is returned unchanged.
  var present: seq[string] = @[]
  for part in value.split(';'):
    if part.len > 0: present.add(normalizedWinPath(part))
  var parts: seq[string] = @[]
  for entry in owned:
    let n = normalizedWinPath(entry)
    if n notin present:
      present.add(n)
      parts.add(entry)
  if parts.len == 0:
    return value
  if value.len > 0:
    parts.add(value)
  parts.join(";")

proc mergeActionEnvWithMsvcEnv*(devEnv: MsvcDevEnv;
                                actionEnv: openArray[string];
                                inheritedLists: openArray[(string, string)] = []):
    seq[string] =
  ## Layer the MSVC dev env under ``actionEnv`` (argv-style ``KEY=VALUE``,
  ## consumed rightmost-wins by ``envTableFromArgvStyle`` and the runquota
  ## helper's ``--env`` flags).
  ##
  ## An ordinary variable the action declares wins outright. A SEARCH LIST it
  ## declares (``MsvcListKeys``, matched case-insensitively) is COMBINED
  ## instead: the action's entries, then the MSVC-owned entries it lacks.
  ## Letting the action's ``PATH`` simply replace the activated one dropped
  ## ``cl.exe``'s directory while ``VCINSTALLDIR`` survived, and the Rust
  ## ``cc`` crate — which reads ``VCINSTALLDIR`` as "already configured" and
  ## then searches PATH only — failed with ``failed to find tool "cl.exe"``.
  ## Only MSVC-owned entries are added, so an ambient directory VsDevCmd
  ## merely passed through does not leak into an action that chose its PATH.
  ##
  ## WHICH actions are merged is the caller's decision, not this proc's: the
  ## engine applies it only to an action that inherits the host's PATH or
  ## declares an MSVC consumer (``isMsvcConsumerTool``; see the engine's
  ## ``actionUsesMsvcToolchain``). Every other declared PATH — a hermetic
  ## one, or an empty one — is the PATH the action runs with.
  ##
  ## A search list the action does NOT declare is given the activation's
  ## MSVC-owned entries (``ownedLists``) in front of the value it would
  ## otherwise have: ``inheritedLists`` holds the current values the launched
  ## process inherits (an absent name means unset, so an isolated launch
  ## passes none and gets the owned entries alone). This is what VsDevCmd does
  ## to the shell it runs in, applied to the value the host holds AT LAUNCH
  ## rather than to the one it held when the activation was captured. Nothing
  ## is emitted when the inherited value already carries every owned entry,
  ## which is the case for an inherited activation.
  ##
  ## Pure, and Windows-semantic on every host, so it is unit-tested anywhere.
  if not devEnv.available:
    return @actionEnv
  result = msvcDevEnvAsArgvStyle(devEnv)
  var declaredLists: seq[string] = @[]
  for entry in actionEnv:
    let eq = entry.find('=')
    if eq > 0:
      let key = entry[0 ..< eq]
      let listKey = msvcListKey(key)
      if listKey.len > 0:
        declaredLists.add(listKey)
        let owned = ownedListFor(devEnv, listKey)
        if owned.len > 0:
          result.add(key & "=" & combineSearchList(entry[eq + 1 .. ^1], owned))
          continue
    result.add(entry)
  for listKey in MsvcListKeys:
    if listKey in declaredLists or not devEnv.ownedLists.hasKey(listKey):
      continue
    let inherited = lookupPairIgnoreCase(inheritedLists, listKey).value
    let combined = prependOwnedEntries(devEnv.ownedLists[listKey], inherited)
    if combined != inherited:
      result.add(listKey & "=" & combined)

proc mergeActionEnvWithMsvc*(actionEnv: openArray[string];
                             inheritedLists: openArray[(string, string)] = []):
    seq[string] =
  ## ``mergeActionEnvWithMsvcEnv`` over the host's cached activation. No-op
  ## on non-Windows hosts.
  when defined(windows):
    result = mergeActionEnvWithMsvcEnv(activateMsvcDevEnv(), actionEnv,
      inheritedLists)
  else:
    result = @actionEnv
