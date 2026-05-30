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
import ./os_system_parse
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
  of pokOsTimezone:
    posixDigestHexOfText(canonicalTimezoneDesired(op.tzIana))
  of pokOsHostname:
    posixDigestHexOfText(canonicalHostnameDesired(op.hostnameName))
  of pokLinuxSysctl:
    if op.sysctlDestroy:
      ZeroDigestHex
    else:
      # Inline form of `sysctlDropInContent(key, value)` — the helper
      # is declared further down so we cannot call it here without
      # breaking the top-down resolution order; the formula is short
      # enough to repeat.
      posixDigestHexOfText(op.sysctlKey & " = " & op.sysctlValue & "\n")
  of pokLinuxUdevRule:
    if op.udevDestroy:
      ZeroDigestHex
    else:
      posixDigestHexOfText(op.udevContent)
  of pokLinuxPolkitRule:
    if op.polkitDestroy:
      ZeroDigestHex
    else:
      posixDigestHexOfText(op.polkitContent)
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
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): once the dispatch-layer
  ## plan-time-baseline drift gate is removed (per
  ## Planner-Apply-Refresh-Model.md), the per-driver post-apply re-probe
  ## is the integrity check. `cfprefsd` re-serializes the plist
  ## asynchronously; re-reading via the same `defaults read` path
  ## `observeMacosSystemDefault` uses, structurally-canonicalized, and
  ## comparing digests closes the gap between cmdlet success and
  ## observable state. Raises `EProtocol` on mismatch.
  when defined(macosx):
    let path = systemDefaultPlistPath(op.sdDomain)
    if op.sdDestroy:
      discard execCmd("defaults delete " & quoteShell(path) & " " &
        quoteShell(op.sdKey))
      if op.sdRestartTarget.len > 0:
        discard execCmd("killall " & quoteShell(op.sdRestartTarget))
      # Post-apply re-probe: a destroy is "done" when the value is
      # absent.
      let post = observeMacosSystemDefault(op)
      if post.present:
        raiseProtocol("macos.systemDefault destroy of " & op.sdDomain &
          " " & op.sdKey & " post-apply observation disagrees with " &
          "desired state: value is still present after `defaults delete`.")
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
    # Post-apply re-probe — see the contract comment above.
    let post = observeMacosSystemDefault(op)
    let desiredHex = posixDigestHexOfText(
      canonicalizeDefaultsValue(op.sdValueLiteral))
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("macos.systemDefault write of " & op.sdDomain &
        " " & op.sdKey & " post-apply observation disagrees with " &
        "desired state: observed present=" & $post.present &
        " digest " & (if post.digestHex.len >= 12: post.digestHex[0 ..< 12]
                      else: post.digestHex) &
        ", desired digest " &
        (if desiredHex.len >= 12: desiredHex[0 ..< 12] else: desiredHex) &
        ". `defaults write` returned exit 0 but the live value does " &
        "not reflect the change — the driver fails closed rather than " &
        "reporting a spurious success.")
    result = post
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
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): once the dispatch-layer
  ## plan-time-baseline drift gate is removed (per
  ## Planner-Apply-Refresh-Model.md), the per-driver post-apply re-probe
  ## is the integrity check. The unit-file write is synchronous but
  ## another agent (or a `systemctl preset`) could overwrite the
  ## content between our write and our return; re-reading via the same
  ## file-read path `observeSystemdSystemUnit` uses and comparing the
  ## canonical-bytes digest closes that gap. Raises `EProtocol` on
  ## mismatch.
  when defined(linux):
    let path = systemUnitPath(op.suName)
    if op.suDestroy:
      discard execCmd("systemctl disable --now " & quoteShell(op.suName))
      if fileExists(path):
        try: removeFile(path)
        except OSError: discard
      discard execCmd("systemctl daemon-reload")
      # Post-apply re-probe: a destroy is "done" when the unit file
      # no longer exists.
      if fileExists(path):
        raiseProtocol("systemd.systemUnit destroy of '" & op.suName &
          "' post-apply observation disagrees with desired state: " &
          "unit file " & path & " still exists after `disable --now` " &
          "and `removeFile`.")
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
    # Post-apply re-probe — see the contract comment above.
    let post = observeSystemdSystemUnit(op)
    let desiredHex = posixDigestHexOfText(op.suContent)
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("systemd.systemUnit '" & op.suName &
        "' post-apply observation disagrees with desired state: " &
        "observed present=" & $post.present &
        " digest " & (if post.digestHex.len >= 12: post.digestHex[0 ..< 12]
                      else: post.digestHex) &
        ", desired digest " &
        (if desiredHex.len >= 12: desiredHex[0 ..< 12] else: desiredHex) &
        ". The unit-file write completed but a re-read shows a " &
        "different value — the driver fails closed rather than " &
        "reporting a spurious success.")
    result = post
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
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): once the dispatch-layer
  ## plan-time-baseline drift gate is removed (per
  ## Planner-Apply-Refresh-Model.md), the per-driver post-apply re-probe
  ## is the integrity check. After the plist write + `launchctl
  ## bootstrap`, re-read via the same file-read path
  ## `observeLaunchdSystemDaemon` uses; raise `EProtocol` on a
  ## canonical-bytes digest mismatch.
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
      # Post-apply re-probe: a destroy is "done" when the plist no
      # longer exists.
      if fileExists(path):
        raiseProtocol("launchd.systemDaemon destroy of '" & op.sdaLabel &
          "' post-apply observation disagrees with desired state: " &
          "plist " & path & " still exists after `launchctl bootout` " &
          "and `removeFile`.")
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
    # Post-apply re-probe — see the contract comment above.
    let post = observeLaunchdSystemDaemon(op)
    let desiredHex = posixDigestHexOfText(plist)
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("launchd.systemDaemon '" & op.sdaLabel &
        "' post-apply observation disagrees with desired state: " &
        "observed present=" & $post.present &
        " digest " & (if post.digestHex.len >= 12: post.digestHex[0 ..< 12]
                      else: post.digestHex) &
        ", desired digest " &
        (if desiredHex.len >= 12: desiredHex[0 ..< 12] else: desiredHex) &
        ". The plist write completed but a re-read shows a different " &
        "value — the driver fails closed rather than reporting a " &
        "spurious success.")
    result = post
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
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): once the dispatch-layer
  ## plan-time-baseline drift gate is removed (per
  ## Planner-Apply-Refresh-Model.md), the per-driver post-apply re-probe
  ## is the integrity check. The filesystem write is synchronous but
  ## permissions / a concurrent writer could corrupt the bytes between
  ## our write and our return; re-reading via the same file-read path
  ## `observeFsSystemFile` uses closes that gap. Raises `EProtocol` on
  ## mismatch.
  when defined(linux) or defined(macosx) or defined(windows):
    let scopeErr = systemFileScopeError(op.sfPath, programDataRoot())
    if scopeErr.len > 0:
      raiseProtocol(scopeErr)
    if op.sfDestroy:
      if fileExists(op.sfPath):
        try: removeFile(op.sfPath)
        except OSError: discard
      # Post-apply re-probe: a destroy is "done" when the file no
      # longer exists.
      if fileExists(op.sfPath):
        raiseProtocol("fs.systemFile destroy of " & op.sfPath &
          " post-apply observation disagrees with desired state: " &
          "the file still exists after `removeFile`.")
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
    # Post-apply re-probe — see the contract comment above.
    let post = observeFsSystemFile(op)
    let desiredHex = posixDigestHexOfText(op.sfContent)
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("fs.systemFile " & op.sfPath &
        " post-apply observation disagrees with desired state: " &
        "observed present=" & $post.present &
        " digest " & (if post.digestHex.len >= 12: post.digestHex[0 ..< 12]
                      else: post.digestHex) &
        ", desired digest " &
        (if desiredHex.len >= 12: desiredHex[0 ..< 12] else: desiredHex) &
        ". The filesystem write completed but a re-read shows a " &
        "different value — the driver fails closed rather than " &
        "reporting a spurious success.")
    result = post
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
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): once the dispatch-layer
  ## plan-time-baseline drift gate is removed (per
  ## Planner-Apply-Refresh-Model.md), the per-driver post-apply re-probe
  ## is the integrity check. The fragment write is synchronous but
  ## another agent could overwrite the file between our write and our
  ## return; re-reading via the same file-read path
  ## `observeEnvSystemVariable` uses and comparing the joined-
  ## contribution digest closes that gap. Raises `EProtocol` on
  ## mismatch.
  when defined(linux) or defined(macosx):
    let path = systemEnvFragmentPath(op.evName)
    if op.evDestroy:
      if fileExists(path):
        try: removeFile(path)
        except OSError: discard
      # Post-apply re-probe: a destroy is "done" when the fragment no
      # longer exists.
      if fileExists(path):
        raiseProtocol("env.systemVariable destroy of " & op.evName &
          " post-apply observation disagrees with desired state: " &
          "fragment " & path & " still exists after `removeFile`.")
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
    # Post-apply re-probe — see the contract comment above.
    let post = observeEnvSystemVariable(op)
    let desiredHex = posixDigestHexOfText(op.evContribution.join("\n"))
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("env.systemVariable " & op.evName &
        " post-apply observation disagrees with desired state: " &
        "observed present=" & $post.present &
        " digest " & (if post.digestHex.len >= 12: post.digestHex[0 ..< 12]
                      else: post.digestHex) &
        ", desired digest " &
        (if desiredHex.len >= 12: desiredHex[0 ..< 12] else: desiredHex) &
        ". The fragment write completed but a re-read shows a " &
        "different value — the driver fails closed rather than " &
        "reporting a spurious success.")
    result = post
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
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): once the dispatch-layer
  ## plan-time-baseline drift gate is removed (per
  ## Planner-Apply-Refresh-Model.md), the per-driver post-apply re-probe
  ## is the integrity check. After `useradd` / `usermod` / `userdel`
  ## the driver already re-reads via `observePasswdUserRaw`; this
  ## contract additionally COMPARES the observation against the
  ## desired canonical state and raises `EProtocol` if they disagree.
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
      # Post-apply re-probe: a destroy is "done" when the account is
      # no longer present.
      if observePasswdUserRaw(op.puName).present:
        raiseProtocol("passwd.user destroy of '" & op.puName &
          "' post-apply observation disagrees with desired state: " &
          "account still present after `userdel` / `sysadminctl " &
          "-deleteUser`.")
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
    # Post-apply re-probe — see the contract comment on this proc.
    let desiredHex = posixDigestHexOfText(canonicalPasswdUserDesired(desired))
    let observedHex =
      if not after.present: ZeroDigestHex
      else: posixDigestHexOfText(canonicalPasswdUserState(after))
    if not after.present or observedHex != desiredHex:
      raiseProtocol("passwd.user '" & op.puName &
        "' post-apply observation disagrees with desired state: " &
        "observed present=" & $after.present &
        " canonical digest " &
        (if observedHex.len >= 12: observedHex[0 ..< 12] else: observedHex) &
        ", desired digest " &
        (if desiredHex.len >= 12: desiredHex[0 ..< 12] else: desiredHex) &
        ". The useradd/usermod call returned exit 0 but the account " &
        "state does not match desired — the driver fails closed " &
        "rather than reporting a spurious success.")
    result.present = after.present
    result.digestHex = observedHex
  else:
    raiseNotImplementedPlatform("passwd.user apply")

# ===========================================================================
# os.timezone — `timedatectl` (Linux) / `systemsetup` (macOS).
#
# The POSIX side passes the IANA name verbatim to the platform tool;
# the IANA -> Windows mapping is a Windows-only concern. Observation
# uses the `timedatectl show --property=Timezone` form (Linux) which
# prints `Timezone=<iana>` deterministically; macOS uses
# `systemsetup -gettimezone` which prints `Time Zone: <iana>`.
# ===========================================================================

proc observePosixOsTimezone*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Re-observe the current system timezone via the platform tool.
  when defined(linux):
    let (output, code) = execCmdEx(
      "timedatectl show --property=Timezone --value")
    if code != 0:
      # Older systemd versions don't support `--value`; fall back to
      # the labeled form. Also fall back to `/etc/timezone` for systems
      # without timedatectl in PATH.
      let (output2, code2) = execCmdEx(
        "timedatectl show --property=Timezone")
      var iana = ""
      if code2 == 0:
        iana = parseTimedatectlOutput(output2)
      if iana.len == 0 and fileExists("/etc/timezone"):
        try:
          iana = parseEtcTimezone(readFile("/etc/timezone"))
        except IOError:
          discard
      result.present = iana.len > 0
      result.digestHex =
        if not result.present: ZeroDigestHex
        else: posixDigestHexOfText(canonicalTimezoneState(iana))
      return
    let iana = output.strip()
    result.present = iana.len > 0
    result.digestHex =
      if not result.present: ZeroDigestHex
      else: posixDigestHexOfText(canonicalTimezoneState(iana))
  elif defined(macosx):
    let (output, code) = execCmdEx("systemsetup -gettimezone")
    if code != 0:
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let iana = parseSystemsetupTimezoneOutput(output)
    result.present = iana.len > 0
    result.digestHex =
      if not result.present: ZeroDigestHex
      else: posixDigestHexOfText(canonicalTimezoneState(iana))
  else:
    raiseNotImplementedPlatform("os.timezone observe (POSIX path)")

proc applyPosixOsTimezone*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Set the system timezone via `timedatectl set-timezone <iana>` on
  ## Linux or `systemsetup -settimezone <iana>` on macOS. Post-apply
  ## re-probe via the matching observation tool.
  when defined(linux):
    let cmd = "timedatectl set-timezone " & quoteShell(op.tzIana)
    let (output, code) = execCmdEx(cmd)
    if code != 0:
      raiseProtocol("os.timezone timedatectl set-timezone to '" &
        op.tzIana & "' failed: " & output.strip())
    let post = observePosixOsTimezone(op)
    let desiredHex = posixDigestHexOfText(canonicalTimezoneDesired(op.tzIana))
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("os.timezone '" & op.tzIana &
        "' post-apply observation disagrees with desired state. " &
        "`timedatectl set-timezone` returned exit 0 but a re-probe " &
        "shows a different timezone — the driver fails closed.")
    result = post
  elif defined(macosx):
    let cmd = "systemsetup -settimezone " & quoteShell(op.tzIana)
    let (output, code) = execCmdEx(cmd)
    if code != 0:
      raiseProtocol("os.timezone systemsetup -settimezone to '" &
        op.tzIana & "' failed: " & output.strip())
    let post = observePosixOsTimezone(op)
    let desiredHex = posixDigestHexOfText(canonicalTimezoneDesired(op.tzIana))
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("os.timezone '" & op.tzIana &
        "' post-apply observation disagrees with desired state.")
    result = post
  else:
    raiseNotImplementedPlatform("os.timezone apply (POSIX path)")

# ===========================================================================
# os.hostname — `hostnamectl` (Linux) / `scutil` triple-set (macOS).
# ===========================================================================

proc observePosixOsHostname*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Re-observe the current hostname via the `hostname` CLI.
  when defined(linux) or defined(macosx):
    let (output, code) = execCmdEx("hostname")
    if code != 0:
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let name = parseHostnameOutput(output)
    result.present = name.len > 0
    result.digestHex =
      if not result.present: ZeroDigestHex
      else: posixDigestHexOfText(canonicalHostnameState(name))
  else:
    raiseNotImplementedPlatform("os.hostname observe (POSIX path)")

proc applyPosixOsHostname*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Set the hostname. Linux: `hostnamectl set-hostname <name>` (takes
  ## effect immediately, no reboot). macOS: the conventional triple of
  ## `scutil --set ComputerName/HostName/LocalHostName` — without the
  ## three sets, the rename is incomplete.
  when defined(linux):
    let cmd = "hostnamectl set-hostname " & quoteShell(op.hostnameName)
    let (output, code) = execCmdEx(cmd)
    if code != 0:
      raiseProtocol("os.hostname hostnamectl set-hostname to '" &
        op.hostnameName & "' failed: " & output.strip())
    let post = observePosixOsHostname(op)
    let desiredHex = posixDigestHexOfText(
      canonicalHostnameDesired(op.hostnameName))
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("os.hostname '" & op.hostnameName &
        "' post-apply observation disagrees with desired state.")
    result = post
  elif defined(macosx):
    let quoted = quoteShell(op.hostnameName)
    let (out1, c1) = execCmdEx("scutil --set ComputerName " & quoted)
    if c1 != 0:
      raiseProtocol("os.hostname scutil --set ComputerName to '" &
        op.hostnameName & "' failed: " & out1.strip())
    let (out2, c2) = execCmdEx("scutil --set HostName " & quoted)
    if c2 != 0:
      raiseProtocol("os.hostname scutil --set HostName to '" &
        op.hostnameName & "' failed: " & out2.strip())
    let (out3, c3) = execCmdEx("scutil --set LocalHostName " & quoted)
    if c3 != 0:
      raiseProtocol("os.hostname scutil --set LocalHostName to '" &
        op.hostnameName & "' failed: " & out3.strip())
    let post = observePosixOsHostname(op)
    let desiredHex = posixDigestHexOfText(
      canonicalHostnameDesired(op.hostnameName))
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("os.hostname '" & op.hostnameName &
        "' post-apply observation disagrees with desired state.")
    result = post
  else:
    raiseNotImplementedPlatform("os.hostname apply (POSIX path)")

# ===========================================================================
# linux.sysctl — write /etc/sysctl.d/<filename> + `sysctl -p` (M83 step 5).
#
# The driver mirrors the systemd.systemUnit shape: write the drop-in
# file, run the activation tool, re-probe for integrity. The closed-set
# validator (`isSafeDropInBasename`, `isSafeSysctlKey`,
# `isSafeSysctlValue`) blocks the layer-1 injection surface BEFORE the
# operation reaches dispatch; `quoteShell` on the path and the key is
# defence-in-depth layer 2.
# ===========================================================================

const LinuxSysctlDir* = "/etc/sysctl.d"
  ## The directory a `linux.sysctl` drop-in file lands in.

proc sysctlDropInFilename*(op: PrivilegedOperation): string =
  ## The on-disk filename for a `linux.sysctl` drop-in. When the
  ## operator did not pin `sysctlFilename`, derive a deterministic
  ## default of the form `99-reprobuild-<address-or-key>.conf` — the
  ## `99-` prefix puts Reprobuild-managed values last in `sysctl.d`
  ## load order so they win against earlier vendor defaults. The
  ## `<address-or-key>` slug uses the resource address when set and
  ## the sysctl key otherwise; every character outside the drop-in
  ## basename charset is replaced with `_` so the result is always
  ## `isSafeDropInBasename`-safe.
  if op.sysctlFilename.len > 0:
    return op.sysctlFilename
  let raw =
    if op.address.len > 0: op.address
    else: op.sysctlKey
  var slug = ""
  for ch in raw:
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_'}:
      slug.add(ch)
    else:
      slug.add('_')
  if slug.len == 0:
    slug = "default"
  "99-reprobuild-" & slug & ".conf"

proc sysctlDropInContent*(key, value: string): string =
  ## The canonical bytes of a `linux.sysctl` drop-in file: one
  ## `<key> = <value>` line with a trailing newline. The digest covers
  ## these bytes verbatim so two operators authoring the same logical
  ## sysctl change produce the same digest regardless of whitespace
  ## choices upstream.
  key & " = " & value & "\n"

proc sysctlDropInPath*(op: PrivilegedOperation): string =
  ## Full on-disk path of the drop-in file for `op`.
  LinuxSysctlDir & "/" & sysctlDropInFilename(op)

proc parseSysctlDropInLine*(line, key: string): tuple[matched: bool;
                                                       value: string] =
  ## Parse a single drop-in line into the value for `key`. A line that
  ## matches the LHS but has an empty RHS returns `(matched: true,
  ## value: "")`; a non-match returns `(matched: false, value: "")`.
  ## Comment / blank lines never match.
  let stripped = line.strip()
  if stripped.len == 0 or stripped.startsWith("#") or
      stripped.startsWith(";"):
    return (false, "")
  let eq = stripped.find('=')
  if eq < 0:
    return (false, "")
  let lhs = stripped[0 ..< eq].strip()
  let rhs = stripped[eq + 1 .. ^1].strip()
  if lhs == key:
    return (true, rhs)
  return (false, "")

proc readSysctlDropInValue*(content, key: string): tuple[present: bool;
                                                          value: string] =
  ## Walk a sysctl drop-in file's content and return the value for
  ## `key`, or `(false, "")` if the key is absent / commented out. The
  ## LAST matching line wins, matching `sysctl`'s own load semantics
  ## (later definitions override earlier ones).
  result = (false, "")
  for ln in content.splitLines():
    let m = parseSysctlDropInLine(ln, key)
    if m.matched:
      result = (true, m.value)

# ---------------------------------------------------------------------------
# Shared drop-in file-write helper used by every Linux drop-in driver
# in this family. Binary-mode write so the bytes on disk equal the
# operator's content verbatim — drift detection compares BLAKE3
# digests, so any CRLF translation would be constant false-positive
# drift. `chmod` via the shell is the platform-portable form available
# in std/osproc; the symbolic octal modes (0644, 0440) we use here are
# universally supported by GNU coreutils. `quoteShell` on the path is
# defence in depth — the validator restricted the basename charset
# before dispatch.
# ---------------------------------------------------------------------------

when defined(linux):
  proc writeLinuxDropInFile(path, content: string; modeOctal: int) =
    var f: File
    if not open(f, path, fmWrite):
      raiseProtocol("linux drop-in driver cannot open " & path)
    try:
      if content.len > 0:
        discard f.writeBuffer(unsafeAddr content[0], content.len)
    finally:
      close(f)
    let modeStr = toOct(modeOctal, 4)
    discard execCmd("chmod " & modeStr & " " & quoteShell(path))

proc observeLinuxSysctl*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Re-observe a sysctl drop-in. The digest covers the canonical
  ## drop-in bytes (`<key> = <value>\n`); a file whose key=value parses
  ## to the desired pair digests identically regardless of trailing
  ## whitespace or comment lines around it. A live-kernel cross-check
  ## via `sysctl -n <key>` is run for completeness but is not folded
  ## into the digest — the file IS the source of truth at apply time
  ## (sysctl -p reloads it).
  when defined(linux):
    let path = sysctlDropInPath(op)
    if not fileExists(path):
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let content = readFile(path)
    let observed = readSysctlDropInValue(content, op.sysctlKey)
    result.present = true
    if observed.present and observed.value == op.sysctlValue:
      # File contains the desired key=value pair — digest the canonical
      # form so a re-author with different whitespace is a cache hit.
      result.digestHex = posixDigestHexOfText(
        sysctlDropInContent(op.sysctlKey, op.sysctlValue))
    else:
      # File present but does not contain our pair — digest the live
      # bytes so the broker's drift gate sees a different digest.
      result.digestHex = posixDigestHexOfText(content)
    # Live-kernel cross-check; exit code is not an error (an unloaded
    # key or a sysctl with no read access is a valid intermediate
    # state). The output is not consumed — this is purely for
    # observability under verbose tracing.
    discard execCmdEx("sysctl -n " & quoteShell(op.sysctlKey))
  else:
    raiseNotImplementedPlatform("linux.sysctl observe")

proc destroyLinuxSysctl*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Remove the drop-in file. `sysctl -p` is NOT re-run — the live
  ## kernel value persists until the next boot or until something
  ## else overwrites it; that is the documented sysctl.d semantics
  ## (drop-in files are a boot-time mechanism, not a removal hook).
  ## Post-apply re-probe asserts the file is gone.
  when defined(linux):
    let path = sysctlDropInPath(op)
    if fileExists(path):
      try: removeFile(path)
      except OSError: discard
    if fileExists(path):
      raiseProtocol("linux.sysctl destroy of " & path &
        " post-apply observation disagrees with desired state: " &
        "the drop-in file still exists after `removeFile`.")
    result.present = false
    result.digestHex = ZeroDigestHex
  else:
    raiseNotImplementedPlatform("linux.sysctl destroy")

proc applyLinuxSysctl*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Write the drop-in file, then `sysctl -p <path>` to load it into
  ## the live kernel. Idempotent: a re-apply with unchanged content
  ## still re-runs `sysctl -p`, which is itself idempotent.
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): the per-driver post-
  ## apply re-probe is the integrity check. After the write +
  ## `sysctl -p`, re-read via the same file-read path
  ## `observeLinuxSysctl` uses; raise `EProtocol` on a canonical-bytes
  ## digest mismatch.
  when defined(linux):
    if op.sysctlDestroy:
      return destroyLinuxSysctl(op)
    let path = sysctlDropInPath(op)
    createDir(LinuxSysctlDir)
    let content = sysctlDropInContent(op.sysctlKey, op.sysctlValue)
    writeLinuxDropInFile(path, content, 0o644)
    # `sysctl -p <path>` loads only this file's keys; `quoteShell` on
    # the path is defence in depth (the basename charset already blocks
    # shell metacharacters).
    let (loadOut, loadCode) = execCmdEx("sysctl -p " & quoteShell(path))
    if loadCode != 0:
      raiseProtocol("linux.sysctl `sysctl -p " & path & "` failed: " &
        loadOut.strip())
    # Post-apply re-probe — see the contract comment above.
    let post = observeLinuxSysctl(op)
    let desiredHex = posixDigestHexOfText(content)
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("linux.sysctl drop-in " & path &
        " post-apply observation disagrees with desired state: " &
        "observed present=" & $post.present &
        " digest " & (if post.digestHex.len >= 12: post.digestHex[0 ..< 12]
                      else: post.digestHex) &
        ", desired digest " &
        (if desiredHex.len >= 12: desiredHex[0 ..< 12] else: desiredHex) &
        ". The drop-in write completed but a re-read shows a different " &
        "value — the driver fails closed rather than reporting a " &
        "spurious success.")
    result = post
  else:
    raiseNotImplementedPlatform("linux.sysctl apply")

# ===========================================================================
# linux.udevRule — write /etc/udev/rules.d/<name> + reload rules.
#
# The device-trigger (`udevadm trigger`) is INTENTIONALLY NOT invoked —
# triggering would re-run rules against every connected device and is
# much more invasive than a converge step should be. The operator who
# needs an immediate effect on already-connected hardware runs `udevadm
# trigger` explicitly.
# ===========================================================================

const LinuxUdevRulesDir* = "/etc/udev/rules.d"
  ## The directory a `linux.udevRule` drop-in file lands in.

proc udevRulePath*(name: string): string =
  ## Full on-disk path of the rule file for `name`.
  LinuxUdevRulesDir & "/" & name

proc observeLinuxUdevRule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Re-observe a udev rule drop-in. The digest covers the file
  ## contents verbatim (the M68 systemd.userUnit content-digest model).
  when defined(linux):
    let path = udevRulePath(op.udevName)
    if not fileExists(path):
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let content = readFile(path)
    result.present = true
    result.digestHex = posixDigestHexOfText(content)
  else:
    raiseNotImplementedPlatform("linux.udevRule observe")

proc destroyLinuxUdevRule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Remove the rule file and reload udev so the absence takes effect.
  ## Post-apply re-probe asserts the file is gone.
  when defined(linux):
    let path = udevRulePath(op.udevName)
    if fileExists(path):
      try: removeFile(path)
      except OSError: discard
    discard execCmdEx("udevadm control --reload-rules")
    if fileExists(path):
      raiseProtocol("linux.udevRule destroy of " & path &
        " post-apply observation disagrees with desired state: " &
        "the rule file still exists after `removeFile`.")
    result.present = false
    result.digestHex = ZeroDigestHex
  else:
    raiseNotImplementedPlatform("linux.udevRule destroy")

proc applyLinuxUdevRule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Write the rule file and `udevadm control --reload-rules`. The
  ## post-apply re-probe re-reads the file and compares the
  ## canonical-bytes digest; raise `EProtocol` on mismatch.
  when defined(linux):
    if op.udevDestroy:
      return destroyLinuxUdevRule(op)
    let path = udevRulePath(op.udevName)
    createDir(LinuxUdevRulesDir)
    writeLinuxDropInFile(path, op.udevContent, 0o644)
    let (reloadOut, reloadCode) = execCmdEx(
      "udevadm control --reload-rules")
    if reloadCode != 0:
      raiseProtocol("linux.udevRule `udevadm control --reload-rules` " &
        "failed after writing " & path & ": " & reloadOut.strip())
    # Post-apply re-probe — see the M82 Phase A contract on the other
    # drivers.
    let post = observeLinuxUdevRule(op)
    let desiredHex = posixDigestHexOfText(op.udevContent)
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("linux.udevRule " & path &
        " post-apply observation disagrees with desired state: " &
        "observed present=" & $post.present &
        " digest " & (if post.digestHex.len >= 12: post.digestHex[0 ..< 12]
                      else: post.digestHex) &
        ", desired digest " &
        (if desiredHex.len >= 12: desiredHex[0 ..< 12] else: desiredHex) &
        ".")
    result = post
  else:
    raiseNotImplementedPlatform("linux.udevRule apply")

# ===========================================================================
# linux.polkitRule — write /etc/polkit-1/rules.d/<name>.
#
# Polkit auto-reloads its rules.d via inotify; there is no explicit
# reload command. The driver is therefore the simplest in the family —
# write the file, post-apply re-probe, done.
# ===========================================================================

const LinuxPolkitRulesDir* = "/etc/polkit-1/rules.d"
  ## The directory a `linux.polkitRule` drop-in file lands in.

proc polkitRulePath*(name: string): string =
  ## Full on-disk path of the polkit rule file for `name`.
  LinuxPolkitRulesDir & "/" & name

proc observeLinuxPolkitRule*(op: PrivilegedOperation):
    ObservedOperationState =
  when defined(linux):
    let path = polkitRulePath(op.polkitName)
    if not fileExists(path):
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let content = readFile(path)
    result.present = true
    result.digestHex = posixDigestHexOfText(content)
  else:
    raiseNotImplementedPlatform("linux.polkitRule observe")

proc destroyLinuxPolkitRule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Remove the rule file. Polkit will auto-detect the change via
  ## inotify. Post-apply re-probe asserts the file is gone.
  when defined(linux):
    let path = polkitRulePath(op.polkitName)
    if fileExists(path):
      try: removeFile(path)
      except OSError: discard
    if fileExists(path):
      raiseProtocol("linux.polkitRule destroy of " & path &
        " post-apply observation disagrees with desired state: " &
        "the rule file still exists after `removeFile`.")
    result.present = false
    result.digestHex = ZeroDigestHex
  else:
    raiseNotImplementedPlatform("linux.polkitRule destroy")

proc applyLinuxPolkitRule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Write the polkit JS rule body to /etc/polkit-1/rules.d/<name>;
  ## polkit's inotify watcher picks up the change asynchronously.
  ## Post-apply re-probe re-reads the file and compares the
  ## canonical-bytes digest; raise `EProtocol` on mismatch.
  when defined(linux):
    if op.polkitDestroy:
      return destroyLinuxPolkitRule(op)
    let path = polkitRulePath(op.polkitName)
    createDir(LinuxPolkitRulesDir)
    writeLinuxDropInFile(path, op.polkitContent, 0o644)
    # Post-apply re-probe; polkit's inotify watcher is asynchronous
    # but the file-content drift gate only checks bytes on disk, not
    # live polkit state — re-reading the file is sufficient.
    let post = observeLinuxPolkitRule(op)
    let desiredHex = posixDigestHexOfText(op.polkitContent)
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("linux.polkitRule " & path &
        " post-apply observation disagrees with desired state: " &
        "observed present=" & $post.present &
        " digest " & (if post.digestHex.len >= 12: post.digestHex[0 ..< 12]
                      else: post.digestHex) &
        ", desired digest " &
        (if desiredHex.len >= 12: desiredHex[0 ..< 12] else: desiredHex) &
        ".")
    result = post
  else:
    raiseNotImplementedPlatform("linux.polkitRule apply")
