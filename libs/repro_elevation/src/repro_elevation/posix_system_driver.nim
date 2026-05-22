## The six M69 Phase-C POSIX / macOS system-scope privileged-operation
## drivers: `macos.systemDefault`, `systemd.systemUnit`,
## `launchd.systemDaemon`, `fs.systemFile`, `env.systemVariable`,
## `passwd.user`.
##
## Each driver is the system-scope counterpart of an M68 home-scope
## driver (or, for `passwd.user`, wholly new) and implements the SAME
## contract the M81 fixture drivers and the M69 Windows drivers do:
##
##   * `observe<X>`  re-observes the resource's current real-world
##     state and returns an `ObservedOperationState` (present +
##     canonical-bytes digest);
##   * `apply<X>`    mutates the resource and returns the post-write
##     observed state.
##
## The broker (`dispatch.nim`) calls `observe` then drift-checks then
## `apply`, exactly as for the other kinds. Every real shell-out
## (`defaults`, `systemctl`, `launchctl`, `useradd`/`usermod`/
## `userdel`) and every system-path filesystem write lives behind
## `when defined(linux)` / `when defined(macosx)`; the PURE parsing /
## drift / generation logic is in `posix_system_parse.nim` and is
## unit-tested cross-platform. Off the relevant platform every entry
## point raises `ENotImplementedPlatform` (fail-closed) — exactly the
## M68 Phase B / M81 POSIX-skeleton precedent.
##
## Reuse vs parallel code (the M68 Phase B mapping):
##
##   * `macos.systemDefault`  reuses the `posix_system_parse`
##     STRUCTURAL comparison (`canonicalizeDefaultsValue`) — a faithful
##     re-implementation of M68's `macos.userDefault` canonicalizer;
##     the `defaults` shell-out differs only in the plist domain.
##   * `systemd.systemUnit`   parallel to M68's `systemd.userUnit`:
##     the unit-file handling is the same SHAPE but the path
##     (`/etc/systemd/system/`) and the `systemctl` invocation (no
##     `--user`) genuinely differ — system scope is not user scope.
##   * `launchd.systemDaemon` reuses the `posix_system_parse` plist
##     GENERATOR shape (`buildLaunchDaemonPlist`, faithful to M68's
##     `buildLaunchAgentPlist`); the bootstrap domain (`system` vs
##     `gui/<uid>`) and the plist directory genuinely differ.
##   * `fs.systemFile`        parallel code — the system-directory
##     allowlist has no home-scope analogue.
##   * `env.systemVariable`   reuses the `posix_system_parse` PATH
##     merge (`computeMergedSystemPath`, the same algorithm as M68's
##     `env.userPath`); the storage backend (HKLM / `/etc/environment`)
##     genuinely differs.
##   * `passwd.user`          wholly new — no home-scope analogue.

import std/[strutils]

import blake3

import ./errors
import ./fixture_driver
import ./operations
import ./posix_system_parse

when defined(linux) or defined(macosx):
  import std/[os, osproc]
elif defined(windows):
  import std/[os]

# ---------------------------------------------------------------------------
# Digest helpers — the canonical-bytes model shared with every other
# system-scope driver.
# ---------------------------------------------------------------------------

proc posixDigestHexOfBytes(bytes: openArray[byte]): string =
  let d = blake3.digest(bytes)
  result = newStringOfCap(64)
  for b in d:
    result.add(toHex(int(b), 2).toLowerAscii())

proc posixDigestHexOfText*(text: string): string =
  var buf = newSeq[byte](text.len)
  for i, ch in text:
    buf[i] = byte(ord(ch))
  posixDigestHexOfBytes(buf)

# ===========================================================================
# Desired-state digest for every Phase-C operation. The non-elevated
# planner computes this; the broker compares its re-observed state
# against the value the plan EXPECTED.
# ===========================================================================

proc desiredStateOf(op: PrivilegedOperation): PasswdUserDesired =
  PasswdUserDesired(name: op.puName, homeDir: op.puHome,
    shell: op.puShell, groups: op.puGroups)

proc posixSystemDesiredDigestHex*(op: PrivilegedOperation): string =
  ## Canonical desired-state digest for a Phase-C system-scope
  ## operation. A destroy op's desired state is the absent sentinel.
  case op.kind
  of pokMacosSystemDefault:
    if op.sdDestroy:
      ZeroDigestHex
    else:
      posixDigestHexOfText(canonicalizeDefaultsValue(op.sdValueLiteral))
  of pokSystemdSystemUnit:
    if op.suDestroy:
      ZeroDigestHex
    else:
      posixDigestHexOfText(op.suContent)
  of pokLaunchdSystemDaemon:
    if op.sdaDestroy:
      ZeroDigestHex
    else:
      posixDigestHexOfText(buildLaunchDaemonPlist(
        op.sdaLabel, op.sdaProgramArgs, op.sdaRunAtLoad))
  of pokFsSystemFile:
    if op.sfDestroy:
      ZeroDigestHex
    else:
      posixDigestHexOfText(op.sfContent)
  of pokEnvSystemVariable:
    # The desired digest is over the JOINED CONTRIBUTION — the same
    # recorded-payload model `env.userPath` uses, so the broker's
    # drift gate compares "is our contribution present" uniformly.
    if op.evDestroy:
      ZeroDigestHex
    else:
      posixDigestHexOfText(op.evContribution.join("\n"))
  of pokPasswdUser:
    if op.puDestroy:
      ZeroDigestHex
    else:
      posixDigestHexOfText(canonicalPasswdUserDesired(desiredStateOf(op)))
  else:
    raise newException(ValueError,
      "posixSystemDesiredDigestHex called on a non-Phase-C kind " &
      $op.kind)

# ===========================================================================
# macos.systemDefault — `defaults` against /Library/Preferences/.
# ===========================================================================

when defined(macosx):
  proc readSystemDefault(domain, key: string): tuple[present: bool;
                                                     value: string] =
    let path = systemDefaultPlistPath(domain)
    let (output, code) = execCmdEx("defaults read " & quoteShell(path) &
      " " & quoteShell(key))
    if code != 0:
      return (false, "")
    (true, output.strip())

proc observeMacosSystemDefault*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Re-observe a `/Library/Preferences/<plist>` value. The digest
  ## covers the STRUCTURALLY-canonicalized value so two
  ## structurally-equal observations digest identically (the M68
  ## `macos.userDefault` precedent — `defaults` re-serializes with
  ## whitespace / key-order variation).
  when defined(macosx):
    let r = readSystemDefault(op.sdDomain, op.sdKey)
    if not r.present:
      result.present = false
      result.digestHex = ZeroDigestHex
    else:
      result.present = true
      result.digestHex = posixDigestHexOfText(
        canonicalizeDefaultsValue(r.value))
  else:
    raiseNotImplementedPlatform("macos.systemDefault observe")

proc applyMacosSystemDefault*(op: PrivilegedOperation):
    ObservedOperationState =
  ## `defaults write /Library/Preferences/<plist> <key> -<type>
  ## <value>` (or `defaults delete` for the destroy direction). When
  ## the value actually changed and a `restartTarget` is set, run
  ## `killall <target>` — a cache-hit re-apply never reaches this
  ## proc (the dispatch layer short-circuits a no-op).
  when defined(macosx):
    let path = systemDefaultPlistPath(op.sdDomain)
    if op.sdDestroy:
      discard execCmd("defaults delete " & quoteShell(path) & " " &
        quoteShell(op.sdKey))
      if op.sdRestartTarget.len > 0:
        discard execCmd("killall " & quoteShell(op.sdRestartTarget))
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let typeFlag =
      if op.sdValueType.len > 0: op.sdValueType else: "-string"
    # `typeFlag` is `quoteShell`'d as defence-in-depth: the closed-set
    # validator (`isSafeDefaultsTypeFlag`) already rejects any value
    # not in the fixed `defaults` type-flag allowlist, but escaping the
    # argument here means even a bypassed validation cannot break out
    # of the argument and reach arbitrary root execution.
    let (output, code) = execCmdEx("defaults write " & quoteShell(path) &
      " " & quoteShell(op.sdKey) & " " & quoteShell(typeFlag) & " " &
      quoteShell(op.sdValueLiteral))
    if code != 0:
      raiseProtocol("macos.systemDefault write of " & op.sdDomain &
        " " & op.sdKey & " failed: " & output.strip())
    if op.sdRestartTarget.len > 0:
      discard execCmd("killall " & quoteShell(op.sdRestartTarget))
    result.present = true
    result.digestHex = posixDigestHexOfText(
      canonicalizeDefaultsValue(op.sdValueLiteral))
  else:
    raiseNotImplementedPlatform("macos.systemDefault apply")

# ===========================================================================
# systemd.systemUnit — unit file under /etc/systemd/system/, `systemctl`.
# ===========================================================================

proc observeSystemdSystemUnit*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Read the unit file under `/etc/systemd/system/` and query
  ## `systemctl show`. The digest covers the unit-file contents (the
  ## M68 `systemd.userUnit` model — drift on the file content is what
  ## the lifecycle compares).
  when defined(linux):
    let path = systemUnitPath(op.suName)
    if not fileExists(path):
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let content = readFile(path)
    result.present = true
    result.digestHex = posixDigestHexOfText(content)
    # `systemctl show` is queried for completeness; the exit code is
    # not an error (a disabled / inactive unit is a valid state).
    discard execCmdEx("systemctl show " & quoteShell(op.suName) &
      " --property=LoadState,ActiveState,UnitFileState")
  else:
    raiseNotImplementedPlatform("systemd.systemUnit observe")

proc applySystemdSystemUnit*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Write the unit file, `systemctl daemon-reload`, then optionally
  ## `systemctl enable --now` (NO `--user` — this is a system unit).
  ## The destroy direction `disable --now`s and removes the file.
  when defined(linux):
    let path = systemUnitPath(op.suName)
    if op.suDestroy:
      discard execCmd("systemctl disable --now " & quoteShell(op.suName))
      if fileExists(path):
        try: removeFile(path)
        except OSError: discard
      discard execCmd("systemctl daemon-reload")
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    createDir(SystemdSystemUnitDir)
    # Binary-mode write so the bytes on disk equal the operator's
    # `suContent` verbatim — drift detection compares BLAKE3 digests,
    # so any CRLF translation would be constant false-positive drift.
    block:
      var f: File
      if not open(f, path, fmWrite):
        raiseProtocol("systemd.systemUnit cannot open " & path)
      try:
        if op.suContent.len > 0:
          discard f.writeBuffer(unsafeAddr op.suContent[0], op.suContent.len)
      finally:
        close(f)
    let (reloadOut, reloadCode) = execCmdEx("systemctl daemon-reload")
    if reloadCode != 0:
      raiseProtocol("systemd.systemUnit daemon-reload failed: " &
        reloadOut.strip())
    if op.suEnabled:
      let (enOut, enCode) = execCmdEx(
        "systemctl enable --now " & quoteShell(op.suName))
      if enCode != 0:
        raiseProtocol("systemd.systemUnit enable --now of '" &
          op.suName & "' failed: " & enOut.strip())
    result.present = true
    result.digestHex = posixDigestHexOfText(op.suContent)
  else:
    raiseNotImplementedPlatform("systemd.systemUnit apply")

# ===========================================================================
# launchd.systemDaemon — plist under /Library/LaunchDaemons/, `launchctl`.
# ===========================================================================

proc observeLaunchdSystemDaemon*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Read the plist under `/Library/LaunchDaemons/`. The digest
  ## covers the plist file contents (the M68 `launchd.userAgent`
  ## model).
  when defined(macosx):
    let path = daemonPlistPath(op.sdaLabel)
    if not fileExists(path):
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let content = readFile(path)
    result.present = true
    result.digestHex = posixDigestHexOfText(content)
    # `system/<label>` is `quoteShell`'d as one argument (defence-in-
    # depth — `isSafeLaunchdLabel` already rejects any label outside
    # the launchd identifier charset before dispatch).
    discard execCmdEx("launchctl print " & quoteShell("system/" & op.sdaLabel))
  else:
    raiseNotImplementedPlatform("launchd.systemDaemon observe")

proc applyLaunchdSystemDaemon*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Write the plist, then `launchctl bootstrap system <plist>` — the
  ## `system` domain target (NOT `gui/<uid>` — this is a system
  ## daemon). The destroy direction `bootout system/<label>`s and
  ## removes the plist.
  when defined(macosx):
    let path = daemonPlistPath(op.sdaLabel)
    if op.sdaDestroy:
      # `system/<label>` is `quoteShell`'d as one argument (defence-in-
      # depth — see `isSafeLaunchdLabel`).
      discard execCmd("launchctl bootout " &
        quoteShell("system/" & op.sdaLabel))
      if fileExists(path):
        try: removeFile(path)
        except OSError: discard
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let plist = buildLaunchDaemonPlist(
      op.sdaLabel, op.sdaProgramArgs, op.sdaRunAtLoad)
    createDir(LaunchDaemonsDir)
    block:
      var f: File
      if not open(f, path, fmWrite):
        raiseProtocol("launchd.systemDaemon cannot open " & path)
      try:
        if plist.len > 0:
          discard f.writeBuffer(unsafeAddr plist[0], plist.len)
      finally:
        close(f)
    # Boot out any stale registration first so `bootstrap` does not
    # fail on a prior load; ignore its exit code. `system/<label>` is
    # `quoteShell`'d as one argument (defence-in-depth — see
    # `isSafeLaunchdLabel`).
    discard execCmd("launchctl bootout " &
      quoteShell("system/" & op.sdaLabel))
    let (bootOut, bootCode) = execCmdEx(
      "launchctl bootstrap system " & quoteShell(path))
    if bootCode != 0:
      raiseProtocol("launchd.systemDaemon bootstrap of '" &
        op.sdaLabel & "' failed: " & bootOut.strip())
    result.present = true
    result.digestHex = posixDigestHexOfText(plist)
  else:
    raiseNotImplementedPlatform("launchd.systemDaemon apply")

# ===========================================================================
# fs.systemFile — a managed file under a recognized system directory.
# ===========================================================================

when defined(windows):
  proc programDataRoot(): string =
    ## The `${PROGRAMDATA}` root the Windows `fs.systemFile` allowlist
    ## adds at apply time.
    getEnv("PROGRAMDATA")
elif defined(linux) or defined(macosx):
  proc programDataRoot(): string = ""

proc observeFsSystemFile*(op: PrivilegedOperation): ObservedOperationState =
  ## Re-observe a managed system file. The digest covers the file
  ## contents. The path's allowlist membership is re-validated as
  ## defence in depth.
  when defined(linux) or defined(macosx) or defined(windows):
    let scopeErr = systemFileScopeError(op.sfPath, programDataRoot())
    if scopeErr.len > 0:
      raiseProtocol(scopeErr)
    if not fileExists(op.sfPath):
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let content = readFile(op.sfPath)
    result.present = true
    result.digestHex = posixDigestHexOfText(content)
  else:
    raiseNotImplementedPlatform("fs.systemFile observe")

proc applyFsSystemFile*(op: PrivilegedOperation): ObservedOperationState =
  ## Write (or, for the destroy direction, delete) the managed file.
  ## The path is re-validated against the allowlist before any I/O —
  ## a path outside `/etc/`, `/usr/local/etc/`, `${PROGRAMDATA}` is
  ## refused with an out-of-scope protocol error.
  when defined(linux) or defined(macosx) or defined(windows):
    let scopeErr = systemFileScopeError(op.sfPath, programDataRoot())
    if scopeErr.len > 0:
      raiseProtocol(scopeErr)
    if op.sfDestroy:
      if fileExists(op.sfPath):
        try: removeFile(op.sfPath)
        except OSError: discard
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let parent = parentDir(op.sfPath)
    if parent.len > 0:
      createDir(parent)
    block:
      var f: File
      if not open(f, op.sfPath, fmWrite):
        raiseProtocol("fs.systemFile cannot open " & op.sfPath)
      try:
        if op.sfContent.len > 0:
          discard f.writeBuffer(unsafeAddr op.sfContent[0], op.sfContent.len)
      finally:
        close(f)
    result.present = true
    result.digestHex = posixDigestHexOfText(op.sfContent)
  else:
    raiseNotImplementedPlatform("fs.systemFile apply")

# ===========================================================================
# env.systemVariable — system PATH / system environment variable.
#
# The driver writes a `fs.systemFile`-style fragment under
# `/etc/profile.d/repro-system-env.sh` (POSIX) — the file the spec's
# own `fs.systemFile` example targets. On Windows the system
# environment lives in the registry; the POSIX driver path is the
# Phase-C surface (the Windows `env.systemVariable` is the
# `windows.registryValue scope=system` HKLM driver from Phase A plus
# the `WM_SETTINGCHANGE` broadcast — out of Phase C's POSIX scope).
# ===========================================================================

const SystemEnvProfileDir = "/etc/profile.d"

proc systemEnvFragmentPath*(name: string): string =
  ## The `/etc/profile.d/` shell fragment a `env.systemVariable`
  ## contribution writes. One fragment per variable name.
  SystemEnvProfileDir & "/repro-system-env-" & name.toLowerAscii() & ".sh"

proc systemEnvFragmentContent*(name: string; contribution: openArray[string];
                               isPathList: bool): string =
  ## The shell fragment text for a system env contribution. For a
  ## PATH-list it PREPENDS the contributed directories while
  ## preserving the host's existing value (contribution-not-overwrite,
  ## the M68 `env.userPath` semantics); for a scalar it exports the
  ## single value.
  if contribution.len == 0:
    return ""
  if isPathList:
    "export " & name & "=" & contribution.join(":") &
      "${" & name & ":+:$" & name & "}\n"
  else:
    "export " & name & "=" & contribution[0] & "\n"

proc observeEnvSystemVariable*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Observe the `/etc/profile.d/` fragment for this variable. The
  ## digest covers the JOINED CONTRIBUTION currently reflected in the
  ## fragment (the M68 `env.userPath` recorded-payload model).
  when defined(linux) or defined(macosx):
    let path = systemEnvFragmentPath(op.evName)
    if not fileExists(path):
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let live = readFile(path)
    let expected = systemEnvFragmentContent(
      op.evName, op.evContribution, op.evIsPathList)
    result.present = true
    if live == expected:
      result.digestHex = posixDigestHexOfText(op.evContribution.join("\n"))
    else:
      # The fragment exists but does not match our contribution — a
      # drift the broker's gate decides on.
      result.digestHex = posixDigestHexOfText(live)
  else:
    raiseNotImplementedPlatform("env.systemVariable observe")

proc applyEnvSystemVariable*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Write (or, for the destroy direction, remove) the
  ## `/etc/profile.d/` fragment. A PATH-list contribution preserves
  ## the host's pre-existing value; the destroy direction removes
  ## only the fragment this generation owns.
  when defined(linux) or defined(macosx):
    let path = systemEnvFragmentPath(op.evName)
    if op.evDestroy:
      if fileExists(path):
        try: removeFile(path)
        except OSError: discard
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    createDir(SystemEnvProfileDir)
    let content = systemEnvFragmentContent(
      op.evName, op.evContribution, op.evIsPathList)
    block:
      var f: File
      if not open(f, path, fmWrite):
        raiseProtocol("env.systemVariable cannot open " & path)
      try:
        if content.len > 0:
          discard f.writeBuffer(unsafeAddr content[0], content.len)
      finally:
        close(f)
    result.present = true
    result.digestHex = posixDigestHexOfText(op.evContribution.join("\n"))
  else:
    raiseNotImplementedPlatform("env.systemVariable apply")

# ===========================================================================
# passwd.user — useradd / usermod / userdel (Linux) or the macOS equiv.
# ===========================================================================

when defined(linux) or defined(macosx):
  proc runArgv(exe: string; args: openArray[string]):
      tuple[output: string; code: int] =
    ## Run a typed argv. The argument LIST is built by the pure
    ## `build*Args` helpers from typed operation fields — no operator
    ## string is interpolated into a shell command.
    var cmd = quoteShell(exe)
    for a in args:
      cmd.add(" ")
      cmd.add(quoteShell(a))
    let (output, code) = execCmdEx(cmd)
    (output, code)

  proc observePasswdUserRaw(name: string): PasswdUserObservation =
    ## Collect the three probe outputs and assemble the observation.
    ## On Linux the canonical probes are `getent passwd`, `id -nG`,
    ## `id -gn`; on macOS the equivalent commands render into the same
    ## colon-separated / space-separated forms the pure parser reads.
    when defined(linux):
      let (getentOut, getentCode) = runArgv("getent", @["passwd", name])
      if getentCode != 0 or getentOut.strip().len == 0:
        return PasswdUserObservation(present: false)
      let (idGroupsOut, _) = runArgv("id", @["-nG", name])
      let (idPrimaryOut, _) = runArgv("id", @["-gn", name])
      parsePasswdObservation(getentOut, idGroupsOut, idPrimaryOut)
    else:
      # macOS: `dscl . -read /Users/<name>` does not emit the colon
      # form; render it. `id` works the same as on Linux.
      let (idOut, idCode) = runArgv("id", @["-nG", name])
      if idCode != 0:
        return PasswdUserObservation(present: false)
      # `dscl . -read /Users/<name> NFSHomeDirectory UserShell
      # UniqueID` gives the attributes; assemble a synthetic colon
      # line so the shared pure parser handles both platforms.
      let (homeOut, _) = runArgv("dscl",
        @[".", "-read", "/Users/" & name, "NFSHomeDirectory"])
      let (shellOut, _) = runArgv("dscl",
        @[".", "-read", "/Users/" & name, "UserShell"])
      let (uidOut, _) = runArgv("dscl",
        @[".", "-read", "/Users/" & name, "UniqueID"])
      proc dsclValue(s: string): string =
        let idx = s.find(':')
        if idx >= 0: s[idx + 1 .. ^1].strip() else: s.strip()
      let synthetic = name & ":*:" & dsclValue(uidOut) & ":*:" & name &
        ":" & dsclValue(homeOut) & ":" & dsclValue(shellOut)
      let (primaryOut, _) = runArgv("id", @["-gn", name])
      parsePasswdObservation(synthetic, idOut, primaryOut)

proc observePasswdUser*(op: PrivilegedOperation): ObservedOperationState =
  ## Re-observe a user account. `present` is true when the account
  ## exists; the digest covers the canonical observed state (uid,
  ## home, shell, supplementary groups).
  when defined(linux) or defined(macosx):
    let obs = observePasswdUserRaw(op.puName)
    result.present = obs.present
    result.digestHex =
      if not obs.present: ZeroDigestHex
      else: posixDigestHexOfText(canonicalPasswdUserState(obs))
  else:
    raiseNotImplementedPlatform("passwd.user observe")

proc applyPasswdUser*(op: PrivilegedOperation): ObservedOperationState =
  ## Create / modify / remove a user account. A fresh account is
  ## created via `useradd`; an existing account is converged via
  ## `usermod` (only the attributes that differ are passed); the
  ## destroy direction runs `userdel --remove`.
  ##
  ## The `--accept-passwd-destroy` gate is enforced by the caller
  ## (`repro infra apply` / `repro system rollback`) BEFORE the
  ## destroy op is ever handed to the broker; this driver only
  ## performs the I/O the closed-set dispatch reaches.
  when defined(linux) or defined(macosx):
    if op.puDestroy:
      when defined(linux):
        let (delOut, delCode) = runArgv("userdel",
          buildUserdelArgs(op.puName))
        if delCode != 0:
          # An already-absent account is not an error for a destroy.
          if observePasswdUserRaw(op.puName).present:
            raiseProtocol("passwd.user userdel of '" & op.puName &
              "' failed: " & delOut.strip())
      else:
        discard runArgv("sysadminctl",
          @["-deleteUser", op.puName])
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let desired = desiredStateOf(op)
    let before = observePasswdUserRaw(op.puName)
    if not before.present:
      when defined(linux):
        let (addOut, addCode) = runArgv("useradd", buildUseraddArgs(desired))
        if addCode != 0:
          raiseProtocol("passwd.user useradd of '" & op.puName &
            "' failed: " & addOut.strip())
      else:
        # macOS: `sysadminctl -addUser` creates the account; group
        # membership is then converged with `dseditgroup`.
        var addArgs = @["-addUser", op.puName]
        if op.puShell.len > 0:
          addArgs.add(@["-shell", op.puShell])
        if op.puHome.len > 0:
          addArgs.add(@["-home", op.puHome])
        let (addOut, addCode) = runArgv("sysadminctl", addArgs)
        if addCode != 0:
          raiseProtocol("passwd.user account creation of '" & op.puName &
            "' failed: " & addOut.strip())
        for g in op.puGroups:
          discard runArgv("dseditgroup",
            @["-o", "edit", "-a", op.puName, "-t", "user", g])
    else:
      let diff = diffPasswdUser(desired, before)
      when defined(linux):
        let modArgs = buildUsermodArgs(desired, diff)
        if modArgs.len > 0:
          let (modOut, modCode) = runArgv("usermod", modArgs)
          if modCode != 0:
            raiseProtocol("passwd.user usermod of '" & op.puName &
              "' failed: " & modOut.strip())
      else:
        if diff.shellDiffers:
          discard runArgv("dscl",
            @[".", "-change", "/Users/" & op.puName, "UserShell",
              before.shell, op.puShell])
        if diff.homeDirDiffers:
          discard runArgv("dscl",
            @[".", "-change", "/Users/" & op.puName, "NFSHomeDirectory",
              before.homeDir, op.puHome])
        for g in diff.missingGroups:
          discard runArgv("dseditgroup",
            @["-o", "edit", "-a", op.puName, "-t", "user", g])
        for g in diff.extraGroups:
          discard runArgv("dseditgroup",
            @["-o", "edit", "-d", op.puName, "-t", "user", g])
    let after = observePasswdUserRaw(op.puName)
    result.present = after.present
    result.digestHex =
      if not after.present: ZeroDigestHex
      else: posixDigestHexOfText(canonicalPasswdUserState(after))
  else:
    raiseNotImplementedPlatform("passwd.user apply")
