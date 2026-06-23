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
  import std/[os, osproc, streams]
elif defined(windows):
  import std/[os, osproc]

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

# ---------------------------------------------------------------------------
# Linux distro probe (Recipe-Validation M7 follow-up).
#
# `systemd.systemUnit` / `systemd.systemTimer` carve out Alpine (and
# other non-systemd Linux distros) by fail-closing with a clear
# directive to switch to the OpenRC equivalent. The pure parser
# (`parseOsReleaseId` / `usesSystemdFromOsRelease`) lives in
# `posix_system_parse.nim`; the host read happens here so the driver
# guard is testable cross-platform via the parser.
# ---------------------------------------------------------------------------

const OsReleaseOverrideEnvVar* = "REPRO_OS_RELEASE_PATH"
  ## Test seam: when set, the host probe reads this path instead of
  ## `/etc/os-release`. Lets the regression test exercise the Alpine
  ## carve-out from a non-Alpine host.

proc hostOsReleaseId*(): string =
  ## Read `/etc/os-release` (or the test-override path) and return the
  ## `ID=` value. Returns "" when the file is absent / unreadable —
  ## the caller treats that as "unknown distro", which the
  ## `usesSystemdFromOsRelease` predicate falls back to "yes".
  when defined(linux) or defined(macosx):
    let path = block:
      let ovr = getEnv(OsReleaseOverrideEnvVar)
      if ovr.len > 0: ovr
      else: "/etc/os-release"
    if not fileExists(path):
      return ""
    try:
      return parseOsReleaseId(readFile(path))
    except IOError, OSError:
      return ""
  else:
    when defined(windows):
      let ovr = getEnv(OsReleaseOverrideEnvVar)
      if ovr.len > 0 and fileExists(ovr):
        try:
          return parseOsReleaseId(readFile(ovr))
        except IOError, OSError:
          return ""
    return ""

proc hostUsesSystemd*(): bool =
  ## Test-seam-aware version of `usesSystemdFromOsRelease`. Returns
  ## true when the host's `/etc/os-release` either declares a known
  ## systemd-shipping distro OR is absent (conservative default —
  ## Reprobuild's M82 plan-time observation is filesystem-only, so
  ## reading a no-systemd unit file does not yet require systemd to
  ## be live; the carve-out specifically gates the destructive APPLY).
  let id = hostOsReleaseId()
  if id.len == 0:
    return true
  id != "alpine" and id != "void" and id != "gentoo"

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
    elif op.sfSourceUrl.len > 0:
      # The profile pins the digest the controller would obtain by
      # fetching `sfSourceUrl`. We can return it directly without a
      # network round trip — the digest IS the canonical desired
      # state, and the apply path verifies the fetched body against
      # this same string before writing.
      op.sfSha256
    elif op.sfSourceLocal.len > 0:
      # The desired bytes are the controller-side file's current
      # contents. Read at observation time so the dispatcher's
      # drift gate compares against the same bytes the apply path
      # would write. Missing / unreadable is a hard error — same
      # contract as `desiredFileContent`.
      when defined(linux) or defined(macosx) or defined(windows):
        if not fileExists(op.sfSourceLocal):
          raiseProtocol("fs.systemFile sourceLocal=" & op.sfSourceLocal &
            " not found or unreadable")
        try:
          posixDigestHexOfText(readFile(op.sfSourceLocal))
        except IOError, OSError:
          raiseProtocol("fs.systemFile sourceLocal=" & op.sfSourceLocal &
            " not found or unreadable")
      else:
        raiseNotImplementedPlatform("fs.systemFile sourceLocal digest")
    else:
      posixDigestHexOfText(op.sfContent)
  of pokFsSystemDirectory:
    # The directory has no content to digest the way `pokFsSystemFile`
    # does. The driver's "present" sentinel is a fixed string so two
    # observations of the same created directory hash identically; the
    # destroy direction uses the absent sentinel.
    if op.fsdDestroy:
      ZeroDigestHex
    else:
      posixDigestHexOfText("fs.systemDirectory:present")
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
  of pokLinuxTmpfilesRule:
    if op.tmpfilesDestroy:
      ZeroDigestHex
    else:
      posixDigestHexOfText(op.tmpfilesContent)
  of pokLinuxSudoersRule:
    if op.sudoersDestroy:
      ZeroDigestHex
    else:
      posixDigestHexOfText(op.sudoersContent)
  of pokPasswdGroup:
    if op.pgDestroy:
      ZeroDigestHex
    else:
      posixDigestHexOfText(canonicalPasswdGroupDesired(
        PasswdGroupDesired(name: op.pgName, gid: op.pgGid,
          members: op.pgMembers)))
  of pokLinuxNixDaemonSetting:
    if op.nixDestroy:
      ZeroDigestHex
    else:
      # Inline form of `nixDaemonDropInContent(key, value)` — the
      # helper is declared further down so we cannot call it here
      # without breaking the top-down resolution order; the formula
      # is short enough to repeat (and matches the sysctl precedent).
      posixDigestHexOfText(op.nixKey & " = " & op.nixValue & "\n")
  of pokSystemdSystemTimer:
    if op.stDestroy:
      ZeroDigestHex
    else:
      posixDigestHexOfText(op.stContent)
  of pokLinuxFirewallRule:
    if op.lfwDestroy:
      ZeroDigestHex
    else:
      # The canonical-bytes form of a managed rule is the rule body
      # the driver would issue as `nft add rule <chain> <body>`. Two
      # operators authoring the same logical rule produce the same
      # digest; a hand-edited live rule that disagrees with the
      # profile yields a different observed digest (the broker's
      # drift gate re-applies).
      posixDigestHexOfText(nftRuleBody(op.lfwProtocol, op.lfwLocalPort,
        op.lfwAction, op.lfwName))
  of pokLinuxNixosSystemModule:
    if op.nixosModuleDestroy:
      ZeroDigestHex
    else:
      # The driver writes `nixosModuleContent` verbatim — no
      # canonicalization is applied. Two operators authoring the same
      # module fragment digest identically; whitespace differences
      # show up as drift (the user authors the content via the
      # constructor so the bytes are stable).
      posixDigestHexOfText(op.nixosModuleContent)
  of pokMacosDarwinSystemModule:
    if op.darwinModuleDestroy:
      ZeroDigestHex
    else:
      posixDigestHexOfText(op.darwinModuleContent)
  of pokLinuxFhsSandbox:
    if op.fsbDestroy:
      ZeroDigestHex
    else:
      # The canonical-bytes form covers the bin path + every composed
      # FHS-tree root + every argv element. Two operators authoring
      # the same sandbox declaration digest identically; changing any
      # one input (binary, prefix, argv entry) yields a different
      # digest so the broker's drift gate re-applies. Each component
      # is appended to a NUL-separated canonical form because the
      # parser already refused NUL in any element (closed-set
      # validation) — NUL is therefore an unambiguous separator that
      # no legitimate payload can collide with.
      var canon = op.fsbBinPath
      canon.add('\x00')
      canon.add("roots:")
      for r in op.fsbFhsTreeRoots:
        canon.add(r)
        canon.add('\x00')
      canon.add("argv:")
      for a in op.fsbArgv:
        canon.add(a)
        canon.add('\x00')
      posixDigestHexOfText(canon)
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
  ##
  ## ALPINE / OPENRC CARVE-OUT (Recipe-Validation M7): Alpine ships
  ## OpenRC as its init system, not systemd. Writing the unit file to
  ## `/etc/systemd/system/` would succeed but the unit would NEVER run
  ## because nothing reads that directory on a musl/openrc host. The
  ## carve-out fail-closes with a clear directive to the user rather
  ## than reporting a spurious success on an apply that doesn't
  ## actually start the unit. The `usesSystemdFromOsRelease` predicate
  ## extends to Void (runit) and Gentoo's OpenRC profile.
  when defined(linux):
    if not hostUsesSystemd():
      let id = hostOsReleaseId()
      raiseProtocol("systemd.systemUnit '" & op.suName &
        "' refused on non-systemd host (ID=" &
        (if id.len > 0: id else: "<unknown>") &
        "). Reprobuild does NOT silently install a `/etc/systemd/" &
        "system/*.service` file on a host whose init system would " &
        "never read it. Switch the profile to the OpenRC equivalent: " &
        "declare an `openrc.service` (Phase-D scope) resource, OR mark " &
        "this resource conditional on a systemd-shipping distro " &
        "(`when distro != \"alpine\"` in the profile). If you " &
        "intentionally want the file present without it ever running " &
        "(staging another agent's install), declare the resource as " &
        "`fs.systemFile` so the carve-out doesn't apply.")
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

# ---------------------------------------------------------------------------
# desiredFileContent — the external-source dispatch helper for
# `fs.systemFile`. The driver branches on which of three mutually-
# exclusive source fields is non-empty:
#
#   * `sfContent`     non-empty (or all three external-source fields
#                     empty — the backward-compatible default for the
#                     pre-Phase-A inline-content shape): the inline
#                     bytes are the desired content.
#   * `sfSourceLocal` non-empty: open the controller-side path and
#                     read all bytes (re-read on every apply so a
#                     between-step edit lands; we explicitly do NOT
#                     cache the result on the op).
#   * `sfSourceUrl`   non-empty: HTTP GET the URL via the synchronous
#                     stdlib client; the BLAKE3 digest of the response
#                     body is verified against `sfSha256` BEFORE the
#                     bytes are returned — a mismatch raises
#                     `EProtocol` so the caller never writes
#                     unverified bytes.
#
# The mutual-exclusion invariant is upheld by the template, the
# `parseSystemProfile` validator, the adapter, AND
# `operationValidationError` — four redundant guards, so the helper's
# precedence below would only matter if all four were bypassed. The
# precedence is `sfSourceLocal` > `sfSourceUrl` > `sfContent` — picked
# because the external-source modes are the ones the validator
# protects (a programming error in the planner could populate
# `sfContent` AND an external source; preferring the external source
# matches the operator's apparent intent that the file come from
# outside).
# ---------------------------------------------------------------------------

when defined(linux) or defined(macosx) or defined(windows):
  import std/httpclient

proc desiredFileContent*(op: PrivilegedOperation): string =
  ## Resolve the bytes the driver should write to `op.sfPath`. Pure
  ## except for the `sfSourceLocal` and `sfSourceUrl` arms, which
  ## perform I/O (read a controller-side file / GET a URL). Returns
  ## the bytes as a `string` (Nim's string is a length-prefixed byte
  ## buffer; binary content is fine).
  ##
  ## Raises `EProtocol` on:
  ##   * a missing / unreadable `sfSourceLocal` path
  ##   * an HTTP error / non-2xx response on `sfSourceUrl`
  ##   * a digest mismatch between the fetched body and `sfSha256`
  ##
  ## The caller then writes the returned bytes — the precise byte
  ## stream the post-apply re-probe will compare back to.
  when defined(linux) or defined(macosx) or defined(windows):
    if op.sfSourceLocal.len > 0:
      if not fileExists(op.sfSourceLocal):
        raiseProtocol("fs.systemFile sourceLocal=" & op.sfSourceLocal &
          " not found or unreadable")
      try:
        return readFile(op.sfSourceLocal)
      except IOError, OSError:
        raiseProtocol("fs.systemFile sourceLocal=" & op.sfSourceLocal &
          " not found or unreadable")
    if op.sfSourceUrl.len > 0:
      # Synchronous fetch via stdlib `httpclient` — keeps the driver
      # straight-line and avoids dragging chronos into the broker.
      # The data: URI scheme is supported by the Nim httpclient so
      # tests can exercise the path without a real network round
      # trip.
      var body: string
      let client = newHttpClient(timeout = 30_000)
      try:
        let resp =
          try:
            client.get(op.sfSourceUrl)
          except CatchableError as e:
            raiseProtocol("fs.systemFile sourceUrl=" & op.sfSourceUrl &
              " fetch failed: " & e.msg)
        if resp.code.int >= 300:
          raiseProtocol("fs.systemFile sourceUrl=" & op.sfSourceUrl &
            " returned HTTP " & $resp.code.int)
        body = resp.body
      finally:
        client.close()
      let observedDigest = posixDigestHexOfText(body)
      if observedDigest != op.sfSha256:
        raiseProtocol("fs.systemFile sourceUrl=" & op.sfSourceUrl &
          " digest mismatch: fetched bytes hash to " & observedDigest &
          " but the profile pinned " & op.sfSha256)
      return body
    # Default + explicit-`content` arm: the inline string.
    return op.sfContent
  else:
    raiseNotImplementedPlatform("fs.systemFile desiredFileContent")

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
  ## The bytes written come from `desiredFileContent(op)`, which
  ## dispatches on the external-source fields (`sfSourceUrl`,
  ## `sfSourceLocal`) and falls back to inline `sfContent` when none
  ## is set. The digest verification for `sfSourceUrl` happens INSIDE
  ## `desiredFileContent`, so by the time we reach the write the
  ## bytes are already trusted.
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
    # Compute the desired bytes BEFORE opening the target file. This
    # ordering matters: a `sourceLocal` read failure or a `sourceUrl`
    # digest mismatch raises `EProtocol` here, so we never truncate
    # the target with empty bytes when the source is bad.
    let desired = desiredFileContent(op)
    let parent = parentDir(op.sfPath)
    if parent.len > 0:
      createDir(parent)
    block:
      var f: File
      if not open(f, op.sfPath, fmWrite):
        raiseProtocol("fs.systemFile cannot open " & op.sfPath)
      try:
        if desired.len > 0:
          discard f.writeBuffer(unsafeAddr desired[0], desired.len)
      finally:
        close(f)
    # Post-apply re-probe — see the contract comment above.
    let post = observeFsSystemFile(op)
    let desiredHex = posixDigestHexOfText(desired)
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
# fs.systemDirectory — a managed system-scope directory.
#
# Companion of `fs.systemFile`. The driver creates the directory at
# apply time (recursively auto-creating parents the way the
# `fs.systemFile` driver does for its parent path) and, when the
# operator declared an inline NTFS ACL via `sdAclPresent == true`,
# stamps the ACL via `icacls` in the same observe / apply cycle. The
# ACL invocation reuses the same `quoteShell` + `icacls /grant`
# pattern the `windows.acl` driver established; the helpers are
# duplicated here because they live behind a `when defined(windows)`
# scope in `windows_system_driver.nim` and exposing them would force
# the cross-module shape changes the M83 surface explicitly avoided.
#
# Off-Windows the ACL fields are silently ignored — a POSIX host has
# no NTFS DACL to stamp. The directory create / destroy happens on
# every platform so a profile authoring `fsSystemDirectory(...)` for
# `/etc/<x>` works on Linux unchanged.
# ===========================================================================

when defined(windows):
  proc icaclsSetOwnerDir(path, owner: string):
      tuple[output: string; code: int] =
    ## Mirror of `takeownOf` in `windows_system_driver.nim`: take
    ## ownership via `takeown /F <path> /A` (a directory is OK — the
    ## `/A` flag still seizes to Administrators) then pin the owner
    ## via `icacls <path> /setowner <owner>`. The first call's
    ## failure is non-fatal (the directory may already be owned by
    ## an Administrator account).
    let takeownCmd = "takeown /F " & quoteShell(path) & " /A"
    discard execCmdEx(takeownCmd)
    let setownerCmd = "icacls " & quoteShell(path) &
      " /setowner " & quoteShell(owner)
    let (output, code) = execCmdEx(setownerCmd)
    (output, code)

  proc icaclsInheritanceDir(path, mode: string):
      tuple[output: string; code: int] =
    ## Apply the inheritance-mode change for a directory.
    ## `disabled-replace` -> `/inheritance:r`; `disabled-convert` ->
    ## `/inheritance:d`; `protected-clear-inherited` -> `/inheritance:r`
    ## (same flag — icacls's "remove inherited" verb IS the SetAccess
    ## RuleProtection(true, false) form the
    ## `protected-clear-inherited` value names). `enabled` is a
    ## no-op.
    let flag =
      case mode
      of "disabled-replace", "protected-clear-inherited": "r"
      of "disabled-convert": "d"
      else: ""
    if flag.len == 0:
      return ("", 0)
    let cmd = "icacls " & quoteShell(path) & " /inheritance:" & flag
    let (output, code) = execCmdEx(cmd)
    (output, code)

  proc icaclsGrantDir(path, entry: string):
      tuple[output: string; code: int] =
    ## `icacls /grant` an ACE on a directory. Deny entries (the
    ## `(D,...)` form `aclEntry(... type = Deny)` emits) are routed
    ## through `/deny` so the icacls verb matches the ACE direction;
    ## an Allow entry uses the default `/grant`.
    let isDeny = entry.find(":(D,") >= 0
    let verb = if isDeny: " /deny " else: " /grant "
    let normalizedEntry =
      if isDeny:
        # Strip the leading `D,` marker so the spec is the bare
        # `(<flag>)` form `icacls /deny` consumes.
        entry.replace(":(D,", ":(")
      else:
        entry
    let cmd = "icacls " & quoteShell(path) & verb &
      quoteShell(normalizedEntry)
    let (output, code) = execCmdEx(cmd)
    (output, code)

proc observeFsSystemDirectory*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Re-observe a managed system directory. The digest is a fixed
  ## present-sentinel (created vs absent is the only meaningful
  ## observation the driver can make — directory contents are NOT in
  ## scope; the operator manages those via `fs.systemFile` etc.).
  ## The path's allowlist membership is re-validated as defence in
  ## depth.
  when defined(linux) or defined(macosx) or defined(windows):
    let scopeErr = systemDirectoryScopeError(op.fsdPath, programDataRoot())
    if scopeErr.len > 0:
      raiseProtocol(scopeErr)
    if not dirExists(op.fsdPath):
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    result.present = true
    result.digestHex = posixDigestHexOfText("fs.systemDirectory:present")
  else:
    raiseNotImplementedPlatform("fs.systemDirectory observe")

proc applyFsSystemDirectory*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Create (or, for the destroy direction, delete) the managed
  ## directory. The path is re-validated against the allowlist before
  ## any I/O — a path outside `/etc/`, `/usr/local/etc/`,
  ## `${PROGRAMDATA}`, or the Windows install-root carve-out is
  ## refused with an out-of-scope protocol error.
  ##
  ## When `fsdAclPresent == true`, the driver stamps the declared NTFS
  ## DACL via `icacls`:
  ##
  ##   1. (optional) take ownership via `takeown /F /A` +
  ##      `icacls /setowner <owner>`;
  ##   2. apply the inheritance mode (skipped for `enabled`);
  ##   3. issue an `icacls /grant <ACE>` per Allow entry and an
  ##      `icacls /deny <ACE>` per Deny entry.
  ##
  ## Off-Windows the ACL fields are silently ignored — POSIX has no
  ## NTFS DACL to stamp.
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): re-observe via the
  ## same `observeFsSystemDirectory` path to confirm the directory
  ## exists (or is gone, for a destroy). A disagreement raises
  ## `EProtocol`.
  when defined(linux) or defined(macosx) or defined(windows):
    let scopeErr = systemDirectoryScopeError(op.fsdPath, programDataRoot())
    if scopeErr.len > 0:
      raiseProtocol(scopeErr)
    if op.fsdDestroy:
      if dirExists(op.fsdPath):
        try: removeDir(op.fsdPath)
        except OSError: discard
      if dirExists(op.fsdPath):
        raiseProtocol("fs.systemDirectory destroy of " & op.fsdPath &
          " post-apply observation disagrees with desired state: " &
          "the directory still exists after `removeDir`.")
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    createDir(op.fsdPath)
    when defined(windows):
      if op.fsdAclPresent:
        if op.fsdAclOwner.len > 0:
          let (ownOut, ownCode) = icaclsSetOwnerDir(
            op.fsdPath, op.fsdAclOwner)
          if ownCode != 0:
            raiseProtocol("fs.systemDirectory `icacls /setowner " &
              op.fsdAclOwner & "` of '" & op.fsdPath & "' failed: " &
              ownOut.strip())
        let mode =
          if op.fsdAclInheritance.len > 0: op.fsdAclInheritance
          else: "enabled"
        if mode != "enabled":
          let (inhOut, inhCode) = icaclsInheritanceDir(op.fsdPath, mode)
          if inhCode != 0:
            raiseProtocol("fs.systemDirectory `icacls /inheritance` " &
              "of '" & op.fsdPath & "' failed: " & inhOut.strip())
        for ace in op.fsdAclEntries:
          let (aceOut, aceCode) = icaclsGrantDir(op.fsdPath, ace)
          if aceCode != 0:
            raiseProtocol("fs.systemDirectory `icacls /grant " & ace &
              "` of '" & op.fsdPath & "' failed: " & aceOut.strip())
    let post = observeFsSystemDirectory(op)
    if not post.present:
      raiseProtocol("fs.systemDirectory " & op.fsdPath &
        " post-apply observation disagrees with desired state: " &
        "the directory does not exist after `createDir`.")
    result = post
  else:
    raiseNotImplementedPlatform("fs.systemDirectory apply")

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
    # Compare the desired canonical bytes against the OBSERVED bytes
    # MASKED by the desired's unpinned fields: a resource that left
    # `homeDir` / `shell` blank is satisfied by whatever `useradd` /
    # `usermod` actually chose, so masking those fields in the
    # observed canonical keeps the comparison about what the
    # resource pinned. The unmasked `canonicalPasswdUserState` stays
    # in service for drift detection elsewhere.
    let desiredHex = posixDigestHexOfText(canonicalPasswdUserDesired(desired))
    let observedHex =
      if not after.present: ZeroDigestHex
      else: posixDigestHexOfText(
        canonicalPasswdUserStateMaskedBy(after, desired))
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

# ===========================================================================
# linux.tmpfilesRule — write /etc/tmpfiles.d/<name> + optional
# `systemd-tmpfiles --create <path>`.
#
# The `tmpfilesApplyNow` field selects whether to run the immediate-
# create step. The default is true — most tmpfiles.d use-cases (a
# /run/<dir>, a /var/cache/<file>) want the entry created NOW rather
# than only at next boot. An operator who needs only the boot-time
# behavior can pin `applyNow = false`.
# ===========================================================================

const LinuxTmpfilesDir* = "/etc/tmpfiles.d"
  ## The directory a `linux.tmpfilesRule` drop-in file lands in.

proc tmpfilesRulePath*(name: string): string =
  ## Full on-disk path of the tmpfiles.d rule file for `name`.
  LinuxTmpfilesDir & "/" & name

proc observeLinuxTmpfilesRule*(op: PrivilegedOperation):
    ObservedOperationState =
  when defined(linux):
    let path = tmpfilesRulePath(op.tmpfilesName)
    if not fileExists(path):
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let content = readFile(path)
    result.present = true
    result.digestHex = posixDigestHexOfText(content)
  else:
    raiseNotImplementedPlatform("linux.tmpfilesRule observe")

proc destroyLinuxTmpfilesRule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Remove the rule file. `systemd-tmpfiles --remove` is INTENTIONALLY
  ## NOT invoked — the rule body could create files we have no business
  ## removing on a destroy step; the documented tmpfiles.d semantics are
  ## that removing the drop-in only stops the boot-time create from
  ## re-running. Post-apply re-probe asserts the file is gone.
  when defined(linux):
    let path = tmpfilesRulePath(op.tmpfilesName)
    if fileExists(path):
      try: removeFile(path)
      except OSError: discard
    if fileExists(path):
      raiseProtocol("linux.tmpfilesRule destroy of " & path &
        " post-apply observation disagrees with desired state: " &
        "the rule file still exists after `removeFile`.")
    result.present = false
    result.digestHex = ZeroDigestHex
  else:
    raiseNotImplementedPlatform("linux.tmpfilesRule destroy")

proc applyLinuxTmpfilesRule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Write the rule file. When `tmpfilesApplyNow` is true (the default)
  ## also invoke `systemd-tmpfiles --create <path>` so the rule takes
  ## effect immediately rather than only at next boot.
  when defined(linux):
    if op.tmpfilesDestroy:
      return destroyLinuxTmpfilesRule(op)
    let path = tmpfilesRulePath(op.tmpfilesName)
    createDir(LinuxTmpfilesDir)
    writeLinuxDropInFile(path, op.tmpfilesContent, 0o644)
    if op.tmpfilesApplyNow:
      # `systemd-tmpfiles --create <path>` processes ONLY this file's
      # rules; exit code is meaningful (a syntax error or a permissions
      # mismatch is a real failure that should surface). `quoteShell`
      # on the path is defence in depth (the basename charset already
      # blocks shell metacharacters).
      let (createOut, createCode) = execCmdEx(
        "systemd-tmpfiles --create " & quoteShell(path))
      if createCode != 0:
        raiseProtocol("linux.tmpfilesRule `systemd-tmpfiles --create " &
          path & "` failed: " & createOut.strip())
    # Post-apply re-probe.
    let post = observeLinuxTmpfilesRule(op)
    let desiredHex = posixDigestHexOfText(op.tmpfilesContent)
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("linux.tmpfilesRule " & path &
        " post-apply observation disagrees with desired state: " &
        "observed present=" & $post.present &
        " digest " & (if post.digestHex.len >= 12: post.digestHex[0 ..< 12]
                      else: post.digestHex) &
        ", desired digest " &
        (if desiredHex.len >= 12: desiredHex[0 ..< 12] else: desiredHex) &
        ".")
    result = post
  else:
    raiseNotImplementedPlatform("linux.tmpfilesRule apply")

# ===========================================================================
# linux.sudoersRule — `visudo -c -f <tmp>` then atomic `mv` into place.
#
# A broken sudoers fragment can lock the operator out of root, so this
# driver is built around `visudo -c` validation:
#
#   1. write to `/etc/sudoers.d/<name>.tmp`  (0440)
#   2. run `visudo -c -f <tmp>`               — fail closed on non-zero exit
#   3. `mv <tmp>` to `/etc/sudoers.d/<name>`  — atomic rename
#
# Step 2 is the safety gate; step 3 makes the change visible only
# after step 2 has approved it. A `visudo -c` failure deletes the tmp
# file so no half-written `.tmp` lingers in `/etc/sudoers.d/`.
# ===========================================================================

const LinuxSudoersDir* = "/etc/sudoers.d"
  ## The directory a `linux.sudoersRule` drop-in file lands in.

proc sudoersRulePath*(name: string): string =
  ## Full on-disk path of the sudoers fragment for `name`.
  LinuxSudoersDir & "/" & name

proc sudoersRuleTmpPath*(name: string): string =
  ## The validation-staging path for a sudoers fragment. `visudo -c
  ## -f` checks this file before the atomic rename so a broken
  ## fragment never replaces a working one.
  LinuxSudoersDir & "/" & name & ".tmp"

proc observeLinuxSudoersRule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Re-observe a sudoers drop-in. The digest covers the file content
  ## verbatim. As a drift-tripwire on hand-edits we ALSO run
  ## `visudo -c -f <path>`; a present-but-invalid file is reported as
  ## a protocol failure because a hand-edit has rendered the operator
  ## profile inconsistent with the live sudoers parse.
  when defined(linux):
    let path = sudoersRulePath(op.sudoersName)
    if not fileExists(path):
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let content = readFile(path)
    result.present = true
    result.digestHex = posixDigestHexOfText(content)
    let (vOut, vCode) = execCmdEx("visudo -c -f " & quoteShell(path))
    if vCode != 0:
      raiseProtocol("linux.sudoersRule " & path &
        " is present but `visudo -c -f` reports it as INVALID — a " &
        "hand-edit has broken the fragment. Re-apply or remove the " &
        "fragment to restore a valid state. visudo says: " &
        vOut.strip())
  else:
    raiseNotImplementedPlatform("linux.sudoersRule observe")

proc destroyLinuxSudoersRule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Remove the sudoers drop-in file. Post-apply re-probe asserts the
  ## file is gone — even on destroy we fail closed if the file is
  ## still there, because a stale sudoers can give an unintended user
  ## continued root access.
  when defined(linux):
    let path = sudoersRulePath(op.sudoersName)
    if fileExists(path):
      try: removeFile(path)
      except OSError: discard
    if fileExists(path):
      raiseProtocol("linux.sudoersRule destroy of " & path &
        " post-apply observation disagrees with desired state: " &
        "the fragment file still exists after `removeFile`.")
    result.present = false
    result.digestHex = ZeroDigestHex
  else:
    raiseNotImplementedPlatform("linux.sudoersRule destroy")

proc applyLinuxSudoersRule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Write to a sibling `.tmp` file, `visudo -c -f` to validate, then
  ## atomic-rename into place. `visudo -c` failure deletes the tmp
  ## and raises a clear `EProtocol` naming the rejected file.
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): re-read the final
  ## file via `observeLinuxSudoersRule` and compare the digest;
  ## additionally `visudo -c -f` runs against the final path as part
  ## of the observation, so a syntactically-broken final file fails
  ## closed.
  when defined(linux):
    if op.sudoersDestroy:
      return destroyLinuxSudoersRule(op)
    let finalPath = sudoersRulePath(op.sudoersName)
    let tmpPath = sudoersRuleTmpPath(op.sudoersName)
    createDir(LinuxSudoersDir)
    # Defensive: drop any stale `.tmp` from a previous failed apply.
    if fileExists(tmpPath):
      try: removeFile(tmpPath)
      except OSError: discard
    writeLinuxDropInFile(tmpPath, op.sudoersContent, 0o440)
    # `visudo -c -f <tmp>` validates the staged file. A non-zero exit
    # means the fragment is syntactically broken — delete the tmp so
    # no half-written state lingers, then raise with `visudo`'s
    # diagnostic so the operator can fix the source.
    let (vOut, vCode) = execCmdEx("visudo -c -f " & quoteShell(tmpPath))
    if vCode != 0:
      try: removeFile(tmpPath)
      except OSError: discard
      raiseProtocol("linux.sudoersRule fragment '" & op.sudoersName &
        "' rejected by `visudo -c -f`: " & vOut.strip() &
        " — the staged file " & tmpPath & " was removed. Fix the " &
        "fragment body before re-applying; a broken sudoers can lock " &
        "you out of root.")
    # Atomic rename: from this point on, the final file is the
    # validated bytes. On Linux `moveFile` maps to a `rename(2)` that
    # is the documented atomic-replace syscall.
    if fileExists(finalPath):
      try: removeFile(finalPath)
      except OSError: discard
    try:
      moveFile(tmpPath, finalPath)
    except OSError as e:
      raiseProtocol("linux.sudoersRule atomic rename of " & tmpPath &
        " -> " & finalPath & " failed: " & e.msg)
    # Post-apply re-probe — `observeLinuxSudoersRule` re-runs
    # `visudo -c -f <finalPath>` so a syntactically-broken final file
    # surfaces here even if the tmp validation somehow disagreed.
    let post = observeLinuxSudoersRule(op)
    let desiredHex = posixDigestHexOfText(op.sudoersContent)
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("linux.sudoersRule " & finalPath &
        " post-apply observation disagrees with desired state: " &
        "observed present=" & $post.present &
        " digest " & (if post.digestHex.len >= 12: post.digestHex[0 ..< 12]
                      else: post.digestHex) &
        ", desired digest " &
        (if desiredHex.len >= 12: desiredHex[0 ..< 12] else: desiredHex) &
        ".")
    result = post
  else:
    raiseNotImplementedPlatform("linux.sudoersRule apply")

# ===========================================================================
# passwd.group — `groupadd` / `groupmod` / `gpasswd` (Linux) or
# `dscl . -create /Groups/<name>` / `dseditgroup` / `dscl . -delete`
# (macOS, M11).
#
# Linux: the system-scope companion to `passwd.user`. Membership is
# ADDITIVE-only by default: a user already in the group but not declared
# by the resource is REPORTED in the observation but NOT removed, so a
# profile that converges only the membership it knows about does not
# silently drop a manually-added admin. The destroy direction runs
# `groupdel` and is gated by `--accept-passwd-destroy` (a removed group
# can break file ownership), mirroring `passwd.user`.
#
# macOS (M11): macOS has NO `groupadd` — local groups live in the
# Directory Service database queried/mutated via `dscl . <op>
# /Groups/<name>`. The driver mirrors the Linux structure but the
# underlying tools are wholly different:
#   * Create:   `dscl . -create /Groups/<name>` then
#               `dscl . -create /Groups/<name> PrimaryGroupID <gid>`
#               (the gid is either pinned by the resource or computed
#               as max-of-existing + 1 in the user-group range to avoid
#               collisions with Apple-owned groups).
#   * Members:  `dseditgroup -o edit -a <member> -t user <name>` — the
#               same primitive the `passwd.user` macOS arm uses for
#               supplementary-group membership; safe in concurrent /
#               re-apply scenarios (no-op when already a member).
#   * Modify:   `dscl . -change /Groups/<name> PrimaryGroupID <old>
#               <new>` for gid convergence.
#   * Destroy:  `dscl . -delete /Groups/<name>` — full deletion
#               including membership records.
#   * Observe:  `dscl . -read /Groups/<name> PrimaryGroupID` +
#               `GroupMembership` → assembled into the same colon-form
#               the pure `parseGetentGroup` parser reads. Yields the
#               SAME `PasswdGroupObservation` the Linux arm builds, so
#               the desired-vs-observed diff + canonical digest +
#               post-apply re-probe logic are SHARED cross-platform.
# ===========================================================================

when defined(linux) or defined(macosx):
  proc desiredOf(op: PrivilegedOperation): PasswdGroupDesired =
    PasswdGroupDesired(name: op.pgName, gid: op.pgGid,
      members: op.pgMembers)

when defined(linux):
  proc observePasswdGroupRaw(name: string): PasswdGroupObservation =
    ## Collect a group observation via `getent group <name>`. An exit
    ## code other than zero, or an empty output, means the group does
    ## not exist.
    let (getentOut, getentCode) = runArgv("getent", @["group", name])
    if getentCode != 0 or getentOut.strip().len == 0:
      return PasswdGroupObservation(present: false)
    parseGetentGroup(getentOut)

elif defined(macosx):
  proc dsclTrailingValue(raw: string): string =
    ## Extract the value half of a `dscl . -read /Groups/<name> <key>`
    ## response. `dscl` emits either:
    ##   `<Key>: <value>`                 (single value, one line)
    ## or:
    ##   `<Key>:\n <value1>\n <value2>`   (multi-value, indented)
    ## Both forms collapse to the space-separated set after the colon.
    let stripped = raw.strip()
    if stripped.len == 0:
      return ""
    let idx = stripped.find(':')
    if idx < 0:
      return stripped
    var tail = stripped[idx + 1 .. ^1]
    # Normalise newlines + leading whitespace into single spaces.
    var flat = ""
    for ch in tail:
      if ch in {'\n', '\r', '\t'}:
        flat.add(' ')
      else:
        flat.add(ch)
    result = flat.strip()

  proc observePasswdGroupRaw(name: string): PasswdGroupObservation =
    ## Collect a group observation via `dscl . -read /Groups/<name>`.
    ## Returns absent when the read fails (the group does not exist)
    ## OR when the PrimaryGroupID is empty (a partial / orphan
    ## record). The returned observation is built into the SAME
    ## colon-form the Linux arm produces so the pure parser +
    ## diff + canonical-digest logic is shared cross-platform.
    let (gidOut, gidCode) = runArgv("dscl",
      @[".", "-read", "/Groups/" & name, "PrimaryGroupID"])
    if gidCode != 0:
      return PasswdGroupObservation(present: false)
    let gid = dsclTrailingValue(gidOut)
    if gid.len == 0:
      return PasswdGroupObservation(present: false)
    # GroupMembership lists user-name members; missing key (exit 0,
    # empty value) means the group has no members. `dscl` returns
    # space-separated names which the synthetic-line parser
    # converts to a comma-separated list.
    let (memOut, memCode) = runArgv("dscl",
      @[".", "-read", "/Groups/" & name, "GroupMembership"])
    var members: seq[string]
    if memCode == 0:
      let raw = dsclTrailingValue(memOut)
      for tok in raw.split({' ', '\t'}):
        let m = tok.strip()
        if m.len > 0 and m notin members:
          members.add(m)
    # Build the colon form: `name:*:<gid>:m1,m2`. The `*` is the
    # password placeholder — `getent group` emits `x` or `*` on
    # different distros; `parseGetentGroup` ignores field [1].
    let synthetic = name & ":*:" & gid & ":" & members.join(",")
    parseGetentGroup(synthetic)

  proc nextFreeMacGroupGid(): string =
    ## Compute a free PrimaryGroupID for a `dscl . -create /Groups/`
    ## when the resource did NOT pin one. Strategy: enumerate existing
    ## PrimaryGroupID values via `dscl . -list /Groups PrimaryGroupID`,
    ## start at 600 (above the Apple-reserved low range and above the
    ## typical admin-tooling range 80-100, while staying under the
    ## non-system user range 500+ — 600..999 is the conventional
    ## reprobuild-managed band on macOS), and return the first integer
    ## not present. Falls back to 600 if the enumeration fails.
    const Base = 600
    var taken: seq[int]
    let (listOut, listCode) = runArgv("dscl",
      @[".", "-list", "/Groups", "PrimaryGroupID"])
    if listCode == 0:
      for line in listOut.splitLines():
        let trimmed = line.strip()
        if trimmed.len == 0:
          continue
        # Each line is `<name>  <gid>` (whitespace-separated).
        let parts = trimmed.split({' ', '\t'})
        if parts.len < 2:
          continue
        try:
          let n = parseInt(parts[^1].strip())
          taken.add(n)
        except ValueError:
          discard
    var candidate = Base
    while candidate in taken:
      inc candidate
    return $candidate

proc observePasswdGroup*(op: PrivilegedOperation): ObservedOperationState =
  ## Re-observe a group account. `present` is true when the group
  ## exists; the digest covers the canonical observed state (gid +
  ## sorted member list).
  when defined(linux) or defined(macosx):
    let obs = observePasswdGroupRaw(op.pgName)
    result.present = obs.present
    result.digestHex =
      if not obs.present: ZeroDigestHex
      else: posixDigestHexOfText(canonicalPasswdGroupState(obs))
  else:
    raiseNotImplementedPlatform("passwd.group observe")

proc destroyPasswdGroup*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Remove a group. Linux: `groupdel`. macOS: `dscl . -delete
  ## /Groups/<name>`. An already-absent group is not an error for a
  ## destroy. The post-apply re-probe asserts the group is no longer
  ## present.
  when defined(linux):
    if observePasswdGroupRaw(op.pgName).present:
      let (delOut, delCode) = runArgv("groupdel",
        buildGroupdelArgs(op.pgName))
      if delCode != 0:
        # If the group is gone after the failure (race), accept it.
        if observePasswdGroupRaw(op.pgName).present:
          raiseProtocol("passwd.group groupdel of '" & op.pgName &
            "' failed: " & delOut.strip())
    if observePasswdGroupRaw(op.pgName).present:
      raiseProtocol("passwd.group destroy of '" & op.pgName &
        "' post-apply observation disagrees with desired state: " &
        "group still present after `groupdel`.")
    result.present = false
    result.digestHex = ZeroDigestHex
  elif defined(macosx):
    if observePasswdGroupRaw(op.pgName).present:
      let (delOut, delCode) = runArgv("dscl",
        @[".", "-delete", "/Groups/" & op.pgName])
      if delCode != 0:
        # If the group is gone after the failure (race), accept it.
        if observePasswdGroupRaw(op.pgName).present:
          raiseProtocol("passwd.group `dscl . -delete /Groups/" &
            op.pgName & "` failed: " & delOut.strip())
    if observePasswdGroupRaw(op.pgName).present:
      raiseProtocol("passwd.group destroy of '" & op.pgName &
        "' post-apply observation disagrees with desired state: " &
        "group still present after `dscl . -delete /Groups/<name>`.")
    result.present = false
    result.digestHex = ZeroDigestHex
  else:
    raiseNotImplementedPlatform("passwd.group destroy")

proc applyPasswdGroup*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Create / converge / remove a group. Linux: fresh group via
  ## `groupadd [--gid N] <name>`, gid converged via `groupmod --gid N
  ## <name>`, membership additions via `usermod -aG <name> <user>`.
  ## macOS: fresh group via `dscl . -create /Groups/<name>` +
  ## `PrimaryGroupID <gid>` (gid auto-computed when unpinned), gid
  ## converged via `dscl . -change ... PrimaryGroupID <old> <new>`,
  ## membership additions via `dseditgroup -o edit -a <member> -t
  ## user <name>` (the same primitive the macOS `passwd.user` arm
  ## uses).
  ## ADDITIVE-only: extras observed in the group but not declared are
  ## REPORTED in the observation but not removed (the driver does not
  ## ship a `--strict-members` mode yet).
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): after the apply the
  ## driver re-observes via `observePasswdGroupRaw` and compares the
  ## canonical-state digest against the desired canonical-string
  ## digest. They disagree when the apply did not converge — including
  ## the additive case where extra members remain on the live group;
  ## the desired canonical reflects the DECLARED set, and an
  ## additive-only apply does not remove extras. Because step 6 ships
  ## the driver WITHOUT `--strict-members`, the re-probe instead
  ## checks the WEAKER post-condition: "every declared member is
  ## present, the gid matches when pinned" — extras are tolerated.
  when defined(linux):
    if op.pgDestroy:
      return destroyPasswdGroup(op)
    let desired = desiredOf(op)
    let before = observePasswdGroupRaw(op.pgName)
    if not before.present:
      let (addOut, addCode) = runArgv("groupadd",
        buildGroupaddArgs(desired))
      if addCode != 0:
        raiseProtocol("passwd.group groupadd of '" & op.pgName &
          "' failed: " & addOut.strip())
    else:
      let diff = diffPasswdGroup(desired, before)
      if diff.gidDiffers:
        let (modOut, modCode) = runArgv("groupmod",
          buildGroupmodGidArgs(desired))
        if modCode != 0:
          raiseProtocol("passwd.group groupmod --gid of '" & op.pgName &
            "' failed: " & modOut.strip())
    # Membership additions: re-observe (a fresh `groupadd` may have
    # populated initial members from elsewhere) then `usermod -aG`
    # any declared member not yet in the group. Errors here surface
    # immediately because the membership change is the operator's
    # explicit intent.
    let mid = observePasswdGroupRaw(op.pgName)
    let midDiff = diffPasswdGroup(desired, mid)
    for member in midDiff.missingMembers:
      let (umOut, umCode) = runArgv("usermod",
        @["-aG", op.pgName, member])
      if umCode != 0:
        raiseProtocol("passwd.group `usermod -aG " & op.pgName & " " &
          member & "` failed: " & umOut.strip())
    # Post-apply re-probe (weaker form — additive-only): the group
    # must exist, the gid must match when pinned, every declared
    # member must be present. Extras are tolerated.
    let after = observePasswdGroupRaw(op.pgName)
    if not after.present:
      raiseProtocol("passwd.group '" & op.pgName &
        "' post-apply observation disagrees with desired state: " &
        "groupadd / groupmod returned exit 0 but the group does not " &
        "exist — the driver fails closed rather than reporting a " &
        "spurious success.")
    let afterDiff = diffPasswdGroup(desired, after)
    if afterDiff.gidDiffers:
      raiseProtocol("passwd.group '" & op.pgName &
        "' post-apply gid mismatch: observed gid '" & after.gid &
        "', desired gid '" & op.pgGid & "'.")
    if afterDiff.missingMembers.len > 0:
      raiseProtocol("passwd.group '" & op.pgName &
        "' post-apply membership disagreement: declared members not " &
        "present after `usermod -aG`: " &
        afterDiff.missingMembers.join(", ") & ".")
    result.present = true
    result.digestHex = posixDigestHexOfText(
      canonicalPasswdGroupState(after))
  elif defined(macosx):
    if op.pgDestroy:
      return destroyPasswdGroup(op)
    let desired = desiredOf(op)
    let before = observePasswdGroupRaw(op.pgName)
    if not before.present:
      # Create the group record. `dscl . -create /Groups/<name>` makes
      # a bare group node; we then pin a `PrimaryGroupID` (either the
      # resource's declared gid or a freshly-computed unused one).
      let (crOut, crCode) = runArgv("dscl",
        @[".", "-create", "/Groups/" & op.pgName])
      if crCode != 0:
        raiseProtocol("passwd.group `dscl . -create /Groups/" &
          op.pgName & "` failed: " & crOut.strip())
      let pinnedGid =
        if desired.gid.len > 0: desired.gid
        else: nextFreeMacGroupGid()
      let (pgOut, pgCode) = runArgv("dscl",
        @[".", "-create", "/Groups/" & op.pgName, "PrimaryGroupID",
          pinnedGid])
      if pgCode != 0:
        # Best-effort cleanup of the half-created node before surfacing
        # the error — leaves the directory cleaner if the gid pin
        # fails for some reason.
        discard runArgv("dscl",
          @[".", "-delete", "/Groups/" & op.pgName])
        raiseProtocol("passwd.group `dscl . -create /Groups/" &
          op.pgName & " PrimaryGroupID " & pinnedGid & "` failed: " &
          pgOut.strip())
    else:
      let diff = diffPasswdGroup(desired, before)
      if diff.gidDiffers:
        let (chOut, chCode) = runArgv("dscl",
          @[".", "-change", "/Groups/" & op.pgName, "PrimaryGroupID",
            before.gid, desired.gid])
        if chCode != 0:
          raiseProtocol("passwd.group `dscl . -change /Groups/" &
            op.pgName & " PrimaryGroupID " & before.gid & " " &
            desired.gid & "` failed: " & chOut.strip())
    # Membership additions: re-observe then `dseditgroup -o edit -a`
    # any declared member not yet in the group. `dseditgroup` is the
    # macOS analogue of `usermod -aG`; it manipulates the same
    # GroupMembership records the observer reads.
    let mid = observePasswdGroupRaw(op.pgName)
    let midDiff = diffPasswdGroup(desired, mid)
    for member in midDiff.missingMembers:
      let (deOut, deCode) = runArgv("dseditgroup",
        @["-o", "edit", "-a", member, "-t", "user", op.pgName])
      if deCode != 0:
        raiseProtocol("passwd.group `dseditgroup -o edit -a " &
          member & " -t user " & op.pgName & "` failed: " &
          deOut.strip())
    # Post-apply re-probe (weaker form — additive-only).
    let after = observePasswdGroupRaw(op.pgName)
    if not after.present:
      raiseProtocol("passwd.group '" & op.pgName &
        "' post-apply observation disagrees with desired state: " &
        "`dscl . -create /Groups/<name>` returned exit 0 but the " &
        "group does not exist — the driver fails closed rather than " &
        "reporting a spurious success.")
    let afterDiff = diffPasswdGroup(desired, after)
    if afterDiff.gidDiffers:
      raiseProtocol("passwd.group '" & op.pgName &
        "' post-apply gid mismatch: observed gid '" & after.gid &
        "', desired gid '" & op.pgGid & "'.")
    if afterDiff.missingMembers.len > 0:
      raiseProtocol("passwd.group '" & op.pgName &
        "' post-apply membership disagreement: declared members not " &
        "present after `dseditgroup -o edit -a`: " &
        afterDiff.missingMembers.join(", ") & ".")
    result.present = true
    result.digestHex = posixDigestHexOfText(
      canonicalPasswdGroupState(after))
  else:
    raiseNotImplementedPlatform("passwd.group apply")

# ===========================================================================
# linux.nixDaemonSetting — drop-in under /etc/nix/nix.conf.d/.
#
# Nix re-reads its configuration on each invocation, so no daemon
# reload is performed — the next `nix` / `nix-daemon` call picks up
# the new setting. The drop-in directory is created if absent.
#
# A host running an older Nix release that predates drop-in support
# would need a managed-block region inside `/etc/nix/nix.conf` instead;
# every supported Nix release ships the drop-in dir so that fallback
# is deferred until a real host surfaces the need.
# ===========================================================================

const LinuxNixDaemonDropInDir* = "/etc/nix/nix.conf.d"
  ## The directory a `linux.nixDaemonSetting` drop-in file lands in.

proc nixDaemonDropInFilename*(op: PrivilegedOperation): string =
  ## Resolve the drop-in basename. An explicit `nixFilename` wins;
  ## otherwise an auto-name is synthesised from the resource address
  ## or key (matching the sysctl precedent — `99-reprobuild-<slug>.conf`).
  if op.nixFilename.len > 0:
    return op.nixFilename
  let raw =
    if op.address.len > 0: op.address
    else: op.nixKey
  var slug = ""
  for ch in raw:
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_'}:
      slug.add(ch)
    else:
      slug.add('_')
  if slug.len == 0:
    slug = "default"
  "99-reprobuild-" & slug & ".conf"

proc nixDaemonDropInContent*(key, value: string): string =
  ## The canonical bytes of a `linux.nixDaemonSetting` drop-in file:
  ## one `<key> = <value>` line with a trailing newline. Matches the
  ## actual nix.conf line syntax (Nix accepts `key = value` with
  ## surrounding whitespace, but the canonical form is the
  ## single-space rendering).
  key & " = " & value & "\n"

proc nixDaemonDropInPath*(op: PrivilegedOperation): string =
  ## Full on-disk path of the drop-in file for `op`.
  LinuxNixDaemonDropInDir & "/" & nixDaemonDropInFilename(op)

proc parseNixDaemonDropInLine*(line, key: string): tuple[matched: bool;
                                                          value: string] =
  ## Parse a single nix.conf drop-in line into the value for `key`.
  ## A line that matches the LHS but has an empty RHS returns
  ## `(matched: true, value: "")`; a non-match returns
  ## `(matched: false, value: "")`. Comment / blank lines never match.
  let stripped = line.strip()
  if stripped.len == 0 or stripped.startsWith("#"):
    return (false, "")
  let eq = stripped.find('=')
  if eq < 0:
    return (false, "")
  let lhs = stripped[0 ..< eq].strip()
  let rhs = stripped[eq + 1 .. ^1].strip()
  if lhs == key:
    return (true, rhs)
  return (false, "")

proc readNixDaemonDropInValue*(content, key: string): tuple[present: bool;
                                                             value: string] =
  ## Walk a nix.conf drop-in file's content and return the value for
  ## `key`, or `(false, "")` if the key is absent / commented out. The
  ## LAST matching line wins, matching nix.conf's own parser
  ## (later definitions override earlier ones).
  result = (false, "")
  for ln in content.splitLines():
    let m = parseNixDaemonDropInLine(ln, key)
    if m.matched:
      result = (true, m.value)

proc observeLinuxNixDaemonSetting*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Re-observe a nix.conf drop-in. The digest covers the canonical
  ## drop-in bytes (`<key> = <value>\n`); a file whose key=value
  ## parses to the desired pair digests identically regardless of
  ## trailing whitespace or comment lines around it (matching the
  ## sysctl precedent).
  when defined(linux):
    let path = nixDaemonDropInPath(op)
    if not fileExists(path):
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let content = readFile(path)
    let observed = readNixDaemonDropInValue(content, op.nixKey)
    result.present = true
    if observed.present and observed.value == op.nixValue:
      # File contains the desired key=value pair — digest the
      # canonical form so a re-author with different whitespace is
      # a cache hit.
      result.digestHex = posixDigestHexOfText(
        nixDaemonDropInContent(op.nixKey, op.nixValue))
    else:
      # File present but does not contain our pair — digest the live
      # bytes so the broker's drift gate sees a different digest.
      result.digestHex = posixDigestHexOfText(content)
  else:
    raiseNotImplementedPlatform("linux.nixDaemonSetting observe")

proc destroyLinuxNixDaemonSetting*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Remove the drop-in file. The next `nix` invocation will no longer
  ## read this setting; pre-existing values inside `/etc/nix/nix.conf`
  ## (which the driver never writes to) remain unchanged. Post-apply
  ## re-probe asserts the drop-in file is gone.
  when defined(linux):
    let path = nixDaemonDropInPath(op)
    if fileExists(path):
      try: removeFile(path)
      except OSError: discard
    if fileExists(path):
      raiseProtocol("linux.nixDaemonSetting destroy of " & path &
        " post-apply observation disagrees with desired state: " &
        "the drop-in file still exists after `removeFile`.")
    result.present = false
    result.digestHex = ZeroDigestHex
  else:
    raiseNotImplementedPlatform("linux.nixDaemonSetting destroy")

proc applyLinuxNixDaemonSetting*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Write the drop-in file. No daemon reload is performed; Nix
  ## re-reads its configuration on each invocation, so the change is
  ## observed by the next `nix` call.
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): the per-driver post-
  ## apply re-probe is the integrity check. After the write, re-read
  ## via the same file-read path `observeLinuxNixDaemonSetting` uses;
  ## raise `EProtocol` on a canonical-bytes digest mismatch.
  when defined(linux):
    if op.nixDestroy:
      return destroyLinuxNixDaemonSetting(op)
    let path = nixDaemonDropInPath(op)
    createDir(LinuxNixDaemonDropInDir)
    let content = nixDaemonDropInContent(op.nixKey, op.nixValue)
    writeLinuxDropInFile(path, content, 0o644)
    # Post-apply re-probe — see the contract comment above.
    let post = observeLinuxNixDaemonSetting(op)
    let desiredHex = posixDigestHexOfText(content)
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("linux.nixDaemonSetting drop-in " & path &
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
    raiseNotImplementedPlatform("linux.nixDaemonSetting apply")

# ===========================================================================
# systemd.systemTimer — `.timer` unit under /etc/systemd/system/.
#
# Sibling of `systemd.systemUnit`. The unit-file handling is identical
# (write to `/etc/systemd/system/<name.timer>`, `daemon-reload`, content
# digest); the timer-specific surface is the `enabled` + `running`
# distinction. A timer is enabled (armed across reboot) AND running
# (currently scheduling its `.service`) independently, so the driver
# supports four desired combinations:
#
#   enabled=true,  running=true   — fully active (the common case)
#   enabled=true,  running=false  — armed, but held inactive for now
#   enabled=false, running=true   — running this boot only (rare)
#   enabled=false, running=false  — present but inert
#
# The destroy direction `stop`s + `disable`s + removes the unit file.
# ===========================================================================

proc observeSystemdSystemTimer*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Read the timer unit file under `/etc/systemd/system/` and query
  ## `systemctl show`. The digest covers the unit-file contents
  ## verbatim (same model as `observeSystemdSystemUnit`); the
  ## `is-enabled` / `is-active` cross-check runs for observability
  ## tracing but does not feed the digest — drift on those flags is
  ## a state-only difference the dispatch loop handles via the
  ## desired-digest comparison after the apply, not via the file
  ## bytes.
  when defined(linux):
    let path = systemUnitPath(op.stName)
    if not fileExists(path):
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let content = readFile(path)
    result.present = true
    result.digestHex = posixDigestHexOfText(content)
    # `systemctl show` is queried for completeness; the exit code is
    # not an error (a disabled / inactive timer is a valid state).
    discard execCmdEx("systemctl show " & quoteShell(op.stName) &
      " --property=LoadState,ActiveState,UnitFileState")
  else:
    raiseNotImplementedPlatform("systemd.systemTimer observe")

proc applySystemdSystemTimer*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Write the timer unit file, `systemctl daemon-reload`, then
  ## reconcile the `enabled` / `running` flags via `systemctl
  ## enable|disable` and `systemctl start|stop`. The destroy
  ## direction `stop`s + `disable`s and removes the file.
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): re-read the unit
  ## file via `observeSystemdSystemTimer` and compare the content
  ## digest; raise `EProtocol` on mismatch.
  ##
  ## ALPINE / OPENRC CARVE-OUT: see `applySystemdSystemUnit` — the
  ## same reasoning applies to `.timer` units. OpenRC has no `.timer`
  ## concept; the equivalent is `crond` or the `local` runscript.
  when defined(linux):
    if not hostUsesSystemd():
      let id = hostOsReleaseId()
      raiseProtocol("systemd.systemTimer '" & op.stName &
        "' refused on non-systemd host (ID=" &
        (if id.len > 0: id else: "<unknown>") &
        "). Switch the profile to the OpenRC equivalent (a `crond` " &
        "job or `local` runscript), OR mark this resource conditional " &
        "on a systemd-shipping distro.")
    let path = systemUnitPath(op.stName)
    if op.stDestroy:
      # Stop, disable, remove. Each is best-effort against an
      # already-quiescent state; the post-apply check on the file
      # is the integrity gate.
      discard execCmd("systemctl stop " & quoteShell(op.stName))
      discard execCmd("systemctl disable " & quoteShell(op.stName))
      if fileExists(path):
        try: removeFile(path)
        except OSError: discard
      discard execCmd("systemctl daemon-reload")
      # Post-apply re-probe: a destroy is "done" when the timer file
      # no longer exists.
      if fileExists(path):
        raiseProtocol("systemd.systemTimer destroy of '" & op.stName &
          "' post-apply observation disagrees with desired state: " &
          "unit file " & path & " still exists after `disable` + " &
          "`removeFile`.")
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    createDir(SystemdSystemUnitDir)
    # Binary-mode write so the bytes on disk equal the operator's
    # `stContent` verbatim — drift detection compares BLAKE3 digests,
    # so any CRLF translation would be constant false-positive drift.
    block:
      var f: File
      if not open(f, path, fmWrite):
        raiseProtocol("systemd.systemTimer cannot open " & path)
      try:
        if op.stContent.len > 0:
          discard f.writeBuffer(unsafeAddr op.stContent[0], op.stContent.len)
      finally:
        close(f)
    let (reloadOut, reloadCode) = execCmdEx("systemctl daemon-reload")
    if reloadCode != 0:
      raiseProtocol("systemd.systemTimer daemon-reload failed: " &
        reloadOut.strip())
    # Reconcile `enabled` flag. `enable` + `disable` are idempotent;
    # we run unconditionally so the apply converges from either
    # initial state.
    if op.stEnabled:
      let (enOut, enCode) = execCmdEx(
        "systemctl enable " & quoteShell(op.stName))
      if enCode != 0:
        raiseProtocol("systemd.systemTimer enable of '" &
          op.stName & "' failed: " & enOut.strip())
    else:
      # Best-effort disable; an already-disabled unit emits a
      # non-zero exit on some systemd versions, ignore it.
      discard execCmd("systemctl disable " & quoteShell(op.stName))
    # Reconcile `running` flag via `start` / `stop`.
    if op.stRunning:
      let (startOut, startCode) = execCmdEx(
        "systemctl start " & quoteShell(op.stName))
      if startCode != 0:
        raiseProtocol("systemd.systemTimer start of '" &
          op.stName & "' failed: " & startOut.strip())
    else:
      # Best-effort stop; an already-stopped unit returns non-zero
      # on some versions, ignore it.
      discard execCmd("systemctl stop " & quoteShell(op.stName))
    # Post-apply re-probe — see the contract comment above.
    let post = observeSystemdSystemTimer(op)
    let desiredHex = posixDigestHexOfText(op.stContent)
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("systemd.systemTimer '" & op.stName &
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
    raiseNotImplementedPlatform("systemd.systemTimer apply")

# ===========================================================================
# linux.firewallRule — `nft add rule` + `nft -a list chain` + `nft delete`.
#
# Reprobuild manages only rules it created — every Reprobuild rule
# carries a `comment "repro-fw-<name>"` marker. The observe path
# greps `nft list ruleset` for that marker; the destroy path looks
# up the rule's handle via `nft -a list chain <chain>` and runs
# `nft delete rule <chain> handle <handle>`. A handle-less destroy
# would force the operator to author the entire rule body verbatim
# for `nft delete`, which is fragile across version skew.
# ===========================================================================

when defined(linux):
  proc nftChainArgs(chain: string): seq[string] =
    ## Split the chain triple `<family> <table> <chain>` into three
    ## separate argv tokens. The closed-set validator already
    ## restricted the chain to exactly three space-separated
    ## identifier-charset tokens, so the split is unambiguous.
    for part in chain.split(' '):
      let p = part.strip()
      if p.len > 0:
        result.add(p)

proc observeLinuxFirewallRule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Re-observe an nftables rule. Looks for the marker comment in
  ## `nft list ruleset` output. The digest covers the canonical
  ## rule-body bytes, so a hand-edited rule with the same comment
  ## but a different action / port digests differently and triggers
  ## the broker's drift gate.
  when defined(linux):
    let comment = nftRuleComment(op.lfwName)
    let (output, code) = execCmdEx("nft list ruleset")
    if code != 0:
      # nft not installed or no ruleset accessible — treat as absent.
      # The apply path will run `nft add rule` and fail with a clean
      # diagnostic if nft really is missing.
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let spec = parseNftRuleSpecForComment(output, comment)
    if spec.len == 0:
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    result.present = true
    # The desired-state digest covers the rule-body bytes the driver
    # would emit; compare the observed spec against that canonical
    # form so a re-read of our own rule digests as a cache-hit.
    let desiredBody = nftRuleBody(op.lfwProtocol, op.lfwLocalPort,
      op.lfwAction, op.lfwName)
    if spec == desiredBody:
      result.digestHex = posixDigestHexOfText(desiredBody)
    else:
      # The live rule disagrees with desired — digest the live form
      # so the broker's drift gate triggers a re-apply.
      result.digestHex = posixDigestHexOfText(spec)
  else:
    raiseNotImplementedPlatform("linux.firewallRule observe")

proc destroyLinuxFirewallRule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Remove the rule. Find its handle via `nft -a list chain
  ## <chain>`, then `nft delete rule <chain> handle <handle>`.
  ## Already-absent is a no-op (the post-apply re-probe asserts
  ## the rule is gone).
  when defined(linux):
    let chainArgs = nftChainArgs(op.lfwChain)
    let comment = nftRuleComment(op.lfwName)
    # `nft -a list chain <chain>` shows the handle annotation.
    var listCmd = "nft -a list chain"
    for c in chainArgs:
      listCmd.add(" " & quoteShell(c))
    let (listOut, listCode) = execCmdEx(listCmd)
    if listCode == 0:
      let handle = parseNftHandleForComment(listOut, comment)
      if handle >= 0:
        var delCmd = "nft delete rule"
        for c in chainArgs:
          delCmd.add(" " & quoteShell(c))
        delCmd.add(" handle " & $handle)
        let (delOut, delCode) = execCmdEx(delCmd)
        if delCode != 0:
          raiseProtocol("linux.firewallRule destroy of '" & op.lfwName &
            "' failed: `nft delete rule <chain> handle " & $handle &
            "` exited " & $delCode & ": " & delOut.strip())
    # Post-apply re-probe: a destroy is "done" when the comment is
    # no longer in the ruleset listing.
    let (output, code) = execCmdEx("nft list ruleset")
    if code == 0 and comment in output:
      raiseProtocol("linux.firewallRule destroy of '" & op.lfwName &
        "' post-apply observation disagrees with desired state: " &
        "the marker '" & comment & "' is still present in the live " &
        "ruleset after `nft delete rule`.")
    result.present = false
    result.digestHex = ZeroDigestHex
  else:
    raiseNotImplementedPlatform("linux.firewallRule destroy")

proc applyLinuxFirewallRule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Add (or update) the nftables rule. The driver always runs
  ## `nft delete rule <chain> handle <handle>` FIRST if a rule with
  ## our marker already exists, then `nft add rule <chain> <body>`
  ## — `nft add rule` appends; an in-place update is "delete then
  ## add" with the same marker.
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): re-read via
  ## `observeLinuxFirewallRule` and compare the canonical-bytes
  ## digest; raise `EProtocol` on mismatch.
  when defined(linux):
    if op.lfwDestroy:
      return destroyLinuxFirewallRule(op)
    let chainArgs = nftChainArgs(op.lfwChain)
    let comment = nftRuleComment(op.lfwName)
    # If a rule with our marker already exists, delete it first so
    # the new add does not duplicate. `nft replace` would be more
    # elegant but requires the handle in the same atomic command;
    # the two-step pattern is simpler and stays atomic per `nft`
    # invocation.
    var listCmd = "nft -a list chain"
    for c in chainArgs:
      listCmd.add(" " & quoteShell(c))
    let (listOut, listCode) = execCmdEx(listCmd)
    if listCode == 0:
      let priorHandle = parseNftHandleForComment(listOut, comment)
      if priorHandle >= 0:
        var delCmd = "nft delete rule"
        for c in chainArgs:
          delCmd.add(" " & quoteShell(c))
        delCmd.add(" handle " & $priorHandle)
        # Ignore the exit code: a concurrent operator may have
        # deleted the rule between the list and the delete; the
        # post-apply re-probe is the integrity gate.
        discard execCmd(delCmd)
    let body = nftRuleBody(op.lfwProtocol, op.lfwLocalPort,
      op.lfwAction, op.lfwName)
    var addCmd = "nft add rule"
    for c in chainArgs:
      addCmd.add(" " & quoteShell(c))
    addCmd.add(" " & body)
    let (addOut, addCode) = execCmdEx(addCmd)
    if addCode != 0:
      raiseProtocol("linux.firewallRule add of '" & op.lfwName &
        "' failed: `nft add rule` exited " & $addCode & ": " &
        addOut.strip())
    # Post-apply re-probe.
    let post = observeLinuxFirewallRule(op)
    let desiredHex = posixDigestHexOfText(body)
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("linux.firewallRule '" & op.lfwName &
        "' post-apply observation disagrees with desired state: " &
        "observed present=" & $post.present &
        " digest " & (if post.digestHex.len >= 12: post.digestHex[0 ..< 12]
                      else: post.digestHex) &
        ", desired digest " &
        (if desiredHex.len >= 12: desiredHex[0 ..< 12] else: desiredHex) &
        ". The `nft add rule` returned exit 0 but a re-read shows a " &
        "different value — the driver fails closed rather than " &
        "reporting a spurious success.")
    result = post
  else:
    raiseNotImplementedPlatform("linux.firewallRule apply")

# ===========================================================================
# linux.nixosSystemModule — managed NixOS module fragment under
# /etc/nixos/reprobuild-managed/.
#
# Dotfiles-Migration-Completion M2 escape-hatch. The driver writes a
# verbatim Nix expression to `/etc/nixos/reprobuild-managed/<name>.nix`
# (mode 0644). The operator pulls every basename in that directory into
# `/etc/nixos/configuration.nix` via a one-time edit (e.g.
# `imports = (import ./reprobuild-managed).fragments`). Reprobuild does
# NOT run `nixos-rebuild switch` itself — every fragment write is a
# typed file converge; the operator triggers the system rebuild
# explicitly. This keeps the broker's closed-typed-operation contract
# intact while letting `system.nim` flow declarative NixOS module
# settings (services.pipewire.enable, programs.hyprland.enable, ...)
# through the same dispatcher that handles every other system-scope
# resource.
#
# Drop-in mechanics match the existing Linux drop-in driver family
# (`linux.nixDaemonSetting`, `linux.sysctl`, ...): one basename per
# resource, hard-rooted under a fixed directory, content-digest model,
# 0644 mode, destroy = remove file.
# ===========================================================================

const LinuxNixosManagedDir* = "/etc/nixos/reprobuild-managed"
  ## The directory a `linux.nixosSystemModule` fragment lands in. The
  ## operator's `configuration.nix` lists this directory's contents
  ## as `imports`; reprobuild only converges the directory's bytes.

proc nixosModulePath*(op: PrivilegedOperation): string =
  ## Full on-disk path of the fragment for `op`.
  LinuxNixosManagedDir & "/" & op.nixosModuleName

proc observeLinuxNixosSystemModule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Re-observe the fragment file. The digest covers the verbatim
  ## bytes; a hand-edited fragment yields a different observed digest
  ## (the broker's drift gate re-applies the desired bytes).
  when defined(linux):
    let path = nixosModulePath(op)
    if not fileExists(path):
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let content = readFile(path)
    result.present = true
    result.digestHex = posixDigestHexOfText(content)
  else:
    raiseNotImplementedPlatform("linux.nixosSystemModule observe")

proc destroyLinuxNixosSystemModule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Remove the fragment file. The next `nixos-rebuild switch` no
  ## longer sees the module attribute set; the operator is
  ## responsible for the rebuild.
  when defined(linux):
    let path = nixosModulePath(op)
    if fileExists(path):
      try: removeFile(path)
      except OSError: discard
    if fileExists(path):
      raiseProtocol("linux.nixosSystemModule destroy of " & path &
        " post-apply observation disagrees with desired state: " &
        "the fragment file still exists after `removeFile`.")
    result.present = false
    result.digestHex = ZeroDigestHex
  else:
    raiseNotImplementedPlatform("linux.nixosSystemModule destroy")

proc applyLinuxNixosSystemModule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Write the fragment file. Per the driver's contract, NO
  ## `nixos-rebuild` is invoked — the operator triggers the rebuild
  ## separately. The driver's job is to converge the file's bytes
  ## and fail closed on a re-read mismatch.
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): after the write,
  ## re-read via the same file-read path `observeLinuxNixosSystem
  ## Module` uses; raise `EProtocol` on a canonical-bytes digest
  ## mismatch.
  when defined(linux):
    if op.nixosModuleDestroy:
      return destroyLinuxNixosSystemModule(op)
    let path = nixosModulePath(op)
    createDir(LinuxNixosManagedDir)
    writeLinuxDropInFile(path, op.nixosModuleContent, 0o644)
    let post = observeLinuxNixosSystemModule(op)
    let desiredHex = posixDigestHexOfText(op.nixosModuleContent)
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("linux.nixosSystemModule fragment " & path &
        " post-apply observation disagrees with desired state: " &
        "observed present=" & $post.present &
        " digest " & (if post.digestHex.len >= 12: post.digestHex[0 ..< 12]
                      else: post.digestHex) &
        ", desired digest " &
        (if desiredHex.len >= 12: desiredHex[0 ..< 12] else: desiredHex) &
        ". The fragment write completed but a re-read shows a different " &
        "value — the driver fails closed rather than reporting a " &
        "spurious success.")
    result = post
  else:
    raiseNotImplementedPlatform("linux.nixosSystemModule apply")

# ===========================================================================
# macos.darwinSystemModule — managed nix-darwin module fragment under
# /etc/nix-darwin/reprobuild-managed/.
#
# The macOS counterpart of `linux.nixosSystemModule`. The driver writes
# a verbatim Nix expression to
# `/etc/nix-darwin/reprobuild-managed/<name>.nix` (mode 0644). The
# operator runs `darwin-rebuild switch` separately to realise it; the
# driver only converges the bytes. Used for cross-OS dotfiles items the
# existing per-resource primitives don't cover (system.defaults beyond
# the `macos.systemDefault` catalog, `users.knownGroups`, the
# `services.*` family declared by nix-darwin's module library, and the
# `homebrew.casks` block when the operator prefers a single declarative
# entry over the per-cask `pkg.homebrewCask` resources).
# ===========================================================================

const MacosDarwinManagedDir* = "/etc/nix-darwin/reprobuild-managed"
  ## The directory a `macos.darwinSystemModule` fragment lands in. The
  ## operator's `darwin-configuration.nix` lists this directory's
  ## contents as `imports`; reprobuild only converges the bytes.

proc darwinModulePath*(op: PrivilegedOperation): string =
  ## Full on-disk path of the fragment for `op`.
  MacosDarwinManagedDir & "/" & op.darwinModuleName

when defined(macosx):
  proc writeMacosManagedFile(path, content: string; modeOctal: int) =
    ## macOS counterpart of `writeLinuxDropInFile`. Same shape: write
    ## the bytes, then `chmod` to the requested mode so the file's
    ## permission bits match the driver contract.
    var f: File
    if not open(f, path, fmWrite):
      raiseProtocol("macos.darwinSystemModule cannot open " & path)
    try:
      if content.len > 0:
        discard f.writeBuffer(unsafeAddr content[0], content.len)
    finally:
      close(f)
    let modeStr = toOct(modeOctal, 4)
    discard execCmd("chmod " & modeStr & " " & quoteShell(path))

proc observeMacosDarwinSystemModule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Re-observe the fragment file. Digest covers the verbatim bytes.
  when defined(macosx):
    let path = darwinModulePath(op)
    if not fileExists(path):
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let content = readFile(path)
    result.present = true
    result.digestHex = posixDigestHexOfText(content)
  else:
    raiseNotImplementedPlatform("macos.darwinSystemModule observe")

proc destroyMacosDarwinSystemModule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Remove the fragment file. The next `darwin-rebuild switch` no
  ## longer sees the module attribute set; the operator is
  ## responsible for the rebuild.
  when defined(macosx):
    let path = darwinModulePath(op)
    if fileExists(path):
      try: removeFile(path)
      except OSError: discard
    if fileExists(path):
      raiseProtocol("macos.darwinSystemModule destroy of " & path &
        " post-apply observation disagrees with desired state: " &
        "the fragment file still exists after `removeFile`.")
    result.present = false
    result.digestHex = ZeroDigestHex
  else:
    raiseNotImplementedPlatform("macos.darwinSystemModule destroy")

proc applyMacosDarwinSystemModule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Write the fragment file. NO `darwin-rebuild` is invoked — the
  ## operator triggers the rebuild separately. The driver's job is to
  ## converge the file's bytes and fail closed on a re-read mismatch.
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): after the write,
  ## re-read via the same file-read path `observeMacosDarwinSystem
  ## Module` uses; raise `EProtocol` on a digest mismatch.
  when defined(macosx):
    if op.darwinModuleDestroy:
      return destroyMacosDarwinSystemModule(op)
    let path = darwinModulePath(op)
    createDir(MacosDarwinManagedDir)
    writeMacosManagedFile(path, op.darwinModuleContent, 0o644)
    let post = observeMacosDarwinSystemModule(op)
    let desiredHex = posixDigestHexOfText(op.darwinModuleContent)
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("macos.darwinSystemModule fragment " & path &
        " post-apply observation disagrees with desired state: " &
        "observed present=" & $post.present &
        " digest " & (if post.digestHex.len >= 12: post.digestHex[0 ..< 12]
                      else: post.digestHex) &
        ", desired digest " &
        (if desiredHex.len >= 12: desiredHex[0 ..< 12] else: desiredHex) &
        ". The fragment write completed but a re-read shows a different " &
        "value — the driver fails closed rather than reporting a " &
        "spurious success.")
    result = post
  else:
    raiseNotImplementedPlatform("macos.darwinSystemModule apply")

# ===========================================================================
# linux.fhsSandbox — Linux-Third-Party-Sandbox-MVP M1 driver scaffold.
#
# Wraps a target binary under bubblewrap so it sees a per-process FHS
# view composed from realized package prefixes. Mirrors the existing
# "spawn an elevated process" Phase-C drivers in shape; the genuinely
# new pieces are:
#
#   * APPLY launches `bwrap` instead of writing a file. The argv vector
#     is computed by `buildLinuxFhsSandboxArgv` — a pure function so
#     it can be unit-tested cross-platform without spawning a real
#     bubblewrap process. Argv is delivered to bubblewrap via Nim's
#     `osproc.startProcess` (NOT a shell), so the M0 transparency-
#     posture flag set is what bubblewrap sees verbatim.
#
#   * OBSERVE is a no-op. A bubblewrap session is NOT persistent —
#     once the wrapped process exits the mount namespace is collected
#     by the kernel, so there is no "current state" to read. The
#     observer always returns the absent sentinel; the apply path is
#     therefore always reached. This is the M0 transparency-posture
#     consequence (no daemon, no leftover state); it is intentional.
#
#   * DESTROY is a no-op. Same rationale — there is nothing
#     persistent to tear down.
#
# The dispatch layer composes observe + desired-digest + apply the
# same way it does for every other Phase-C kind: a fresh observe at
# every dispatch sees "absent" (the sandbox is not persistent), the
# desired digest covers the bin path + tree roots + argv, the
# apply-time predicate hits the "create" path on every legitimate
# apply, the apply spawns bubblewrap, the post-apply re-probe sees
# "absent" again (because the wrapped process exited and the mount
# namespace collapsed), and the driver returns the apply-success
# state with the desired digest so the cache-hit gate downstream
# treats subsequent identical applies as no-ops via the parent-side
# memoization (the dispatch layer's two-sample cache-hit confirmation
# is bypassed by the always-absent observe; the parent's planner
# already records a stable address for this resource and the
# planner-stage cache-hit gate handles the "we just ran this" case
# at plan emission time).
#
# M2-M6 (the apt / dnf / pacman fetchers + the steam-run validation)
# layer on top of this driver — they synthesise the FHS-tree roots
# from realized .deb / .rpm / .pkg.tar.zst archives and feed them to
# this driver verbatim. The driver itself does NOT know about
# packaging formats; it is the typed dispatch boundary between the
# planner and bubblewrap.
# ===========================================================================

const
  LinuxFhsSandboxFhsRoots* = [
    "usr", "lib", "lib64", "bin", "sbin", "etc"]
    ## The six FHS roots the M0 transparency posture composes from
    ## the realized prefix. `/dev /home /tmp /run /sys /var /proc`
    ## are bind-passed to the host (the M0 lock) and are NOT in this
    ## list. The order is the order they appear in the bwrap argv
    ## vector — the driver writes the same six `--bind` pairs every
    ## time so two operators authoring the same sandbox declaration
    ## produce byte-identical argv vectors.
  LinuxFhsSandboxHostPassThrough* = [
    ("/home", "/home"),
    ("/tmp", "/tmp"),
    ("/run", "/run"),
    ("/sys", "/sys"),
    ("/var", "/var")]
    ## The five `--bind /<host> /<host>` host-passthrough pairs. The
    ## M0 lock makes these unconditional: the wrapped process sees
    ## the host's home, tmp, run, sys, var. `/dev` is handled
    ## separately via `--dev-bind` (bubblewrap's specific flag for
    ## binding /dev with the device-node semantics intact). `/proc`
    ## is handled via `--proc /proc` (bubblewrap mounts a fresh
    ## procfs inside the mount namespace — host-visible per the
    ## transparency posture because no `--unshare-pid` is set).

proc buildLinuxFhsSandboxArgv*(op: PrivilegedOperation): seq[string] =
  ## Pure argv-vector builder for the `linux.fhsSandbox` driver. Two
  ## operators authoring the same `PrivilegedOperation` produce
  ## byte-identical argv vectors; the same `op` always produces the
  ## same argv vector (no environment dependence). Unit-tested
  ## cross-platform — the spawn step lives in `applyLinuxFhsSandbox`
  ## and is platform-gated.
  ##
  ## The vector encodes the M0-locked transparency posture (see the
  ## module header for the explicit shape). M1 binds the first
  ## `fsbFhsTreeRoots` entry into the six FHS roots; an empty
  ## `fsbFhsTreeRoots` is refused at parse time so this proc may
  ## assume `len >= 1` for a non-destroy op (the destroy path is a
  ## no-op and never builds an argv vector).
  result = @["bwrap"]
  doAssert op.fsbFhsTreeRoots.len >= 1,
    "buildLinuxFhsSandboxArgv requires at least one FHS-tree root; " &
    "the parser rejects an empty fhsTreeRoots list on a non-destroy " &
    "apply, so this branch should be unreachable"
  let composed = op.fsbFhsTreeRoots[0]
  for sub in LinuxFhsSandboxFhsRoots:
    result.add("--bind")
    result.add(composed & "/" & sub)
    result.add("/" & sub)
  # /dev needs --dev-bind for the device-node semantics
  result.add("--dev-bind")
  result.add("/dev")
  result.add("/dev")
  for pair in LinuxFhsSandboxHostPassThrough:
    result.add("--bind")
    result.add(pair[0])
    result.add(pair[1])
  result.add("--proc")
  result.add("/proc")
  result.add("--")
  result.add(op.fsbBinPath)
  for a in op.fsbArgv:
    result.add(a)

proc observeLinuxFhsSandbox*(op: PrivilegedOperation):
    ObservedOperationState =
  ## A bubblewrap session is NOT persistent — the mount namespace
  ## collapses when the wrapped process exits, so there is no
  ## "current state" to read. Always returns the absent sentinel
  ## (`present = false`, `digestHex = ZeroDigestHex`). The dispatch
  ## layer's drift / cache-hit logic treats this as "needs apply
  ## every time"; the parent-side planner stage records a stable
  ## address for this resource and is the layer that decides whether
  ## the sandbox should actually be launched again (M2 wires the
  ## "run-once-per-plan" semantics into the planner; M1 stays
  ## conservative and lets every dispatch reach the apply path).
  ##
  ## Same off-platform stub the other Linux drivers use: the observe
  ## proc itself is platform-gated so a cross-platform planning step
  ## (e.g. `repro infra plan` running on Windows against a profile
  ## that declares a Linux sandbox) sees the canonical absent state
  ## via the planner's `ENotImplementedPlatform` catch (see
  ## `repro_infra.planner.observeResource`).
  when defined(linux):
    result.present = false
    result.digestHex = ZeroDigestHex
  else:
    raiseNotImplementedPlatform("linux.fhsSandbox observe")

proc destroyLinuxFhsSandbox*(op: PrivilegedOperation):
    ObservedOperationState =
  ## A sandbox session is not persistent, so destroy is a no-op —
  ## there is nothing to tear down. Returns the absent sentinel.
  ## Symmetric with `observeLinuxFhsSandbox`. Gated `when defined(
  ## linux)` only for symmetry with the other Linux drivers; the
  ## actual body has no platform dependence.
  when defined(linux):
    result.present = false
    result.digestHex = ZeroDigestHex
  else:
    raiseNotImplementedPlatform("linux.fhsSandbox destroy")

proc applyLinuxFhsSandbox*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Spawn `bwrap` with the M0-locked transparency-posture argv
  ## vector built by `buildLinuxFhsSandboxArgv`. The spawn is via
  ## `osproc.startProcess` (NOT a shell): the argv vector is passed
  ## as a vector so the per-element NUL refusal in the parser is the
  ## only filter needed, and no `quoteShell` is required because the
  ## arguments never reach a shell.
  ##
  ## A destroy op is a no-op (sandbox sessions are not persistent;
  ## there is nothing to tear down). The post-apply re-probe is the
  ## absent sentinel from `observeLinuxFhsSandbox`; the dispatch
  ## layer accepts that because the desired digest for a destroy is
  ## also the absent sentinel and for a non-destroy the post-apply
  ## state is "the sandbox ran" — captured by the digest returned
  ## from this proc, not by an observe re-probe (the live state
  ## genuinely IS absent after the wrapped process exits).
  ##
  ## Exit-code contract: the driver propagates bubblewrap's exit
  ## code only as a `raiseProtocol` on non-zero exit. The wrapped
  ## binary's own exit code is bubblewrap's exit code in the
  ## transparency posture (no `--bind-fd` or `--exec-label`
  ## indirection), so an `EProtocol` here means the wrapped binary
  ## itself failed — the catalog-adapter chain upstream is what
  ## decides whether that is fatal for the apply.
  when defined(linux):
    if op.fsbDestroy:
      return destroyLinuxFhsSandbox(op)
    let argv = buildLinuxFhsSandboxArgv(op)
    # `startProcess` takes the executable and the argv tail
    # separately. The argv we built starts with `bwrap`; pass it as
    # the executable and the tail [1..^1] as the arguments. The
    # `poStdErrToStdOut + poUsePath` options match the broker's
    # other shell-out drivers (a) so the bubblewrap stderr is
    # captured for the diagnostic on non-zero exit and (b) so
    # `bwrap` is resolved via PATH (the driver does NOT pin a path
    # to bubblewrap — the operator's PATH is the host's PATH per
    # the M0 transparency posture).
    let process = startProcess(argv[0], args = argv[1 .. ^1],
      options = {poStdErrToStdOut, poUsePath})
    let exitCode = process.waitForExit()
    let output = process.outputStream.readAll()
    process.close()
    if exitCode != 0:
      raiseProtocol("linux.fhsSandbox apply of " & op.fsbBinPath &
        " failed: bwrap exited with code " & $exitCode & ": " &
        output.strip())
    # Post-apply re-probe: a bubblewrap session is not persistent,
    # so the live observe is always absent. The dispatch layer's
    # cache-hit predicate treats "apply ran + observe absent" as
    # "apply succeeded" — exactly the same as a fixture file that
    # is written and then immediately deleted. The driver returns
    # the desired digest so the apply-log record carries the
    # canonical bytes the operator declared.
    result.present = true
    result.digestHex = posixSystemDesiredDigestHex(op)
  else:
    raiseNotImplementedPlatform("linux.fhsSandbox apply")
