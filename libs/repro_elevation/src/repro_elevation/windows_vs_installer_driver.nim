## The M69 Phase-B `windows.vsInstaller` privileged-operation driver.
##
## Per System-Profile-And-Infra-Apply.md "windows.vsInstaller": a
## custom driver for the Visual Studio installer, which is not a
## normal package manager. State is queried through `vswhere.exe`
## (Reprobuild ships an embedded copy); the bootstrapped installer
## (`vs_<edition>.exe` / the resident `vs_installer.exe`) is invoked
## with `--add` / `--remove` for workloads and components.
##
## The driver implements the SAME contract the other four M69 drivers
## do (`observe<X>` + `apply<X>` returning an `ObservedOperationState`)
## so `dispatch.nim` wires it into the closed `case` statements
## exactly the way the Phase-A drivers are wired. Every real
## `osproc` shell-out lives behind `when defined(windows)`; the PURE
## parsing / membership-diff / drift-classification logic is in
## `windows_vs_installer_parse.nim` and is unit-tested cross-platform.
##
## Component VERSION drift is benign — the diff compares package IDs
## only (see `windows_vs_installer_parse.diffMembership`). A workload
## present on disk but not in the resource is detected as drift; with
## `strict = false` it is left alone (a warning), with `strict = true`
## it is removed. The installer may require a reboot; the driver
## surfaces `restartNeeded` and NEVER auto-reboots.

import std/[strutils]

import blake3

import ./errors
import ./fixture_driver
import ./operations
import ./windows_vs_installer_parse

when defined(windows):
  import std/[os, osproc]

# ---------------------------------------------------------------------------
# Digest helpers (the canonical-bytes model shared with the other
# system drivers).
# ---------------------------------------------------------------------------

proc vsDigestHexOfText(text: string): string =
  var buf = newSeq[byte](text.len)
  for i, ch in text:
    buf[i] = byte(ord(ch))
  let d = blake3.digest(buf)
  result = newStringOfCap(64)
  for b in d:
    result.add(toHex(int(b), 2).toLowerAscii())

proc desiredStateOf(op: PrivilegedOperation): VsInstallerDesiredState =
  ## Project the typed operation onto the pure-logic desired-state
  ## record.
  VsInstallerDesiredState(
    edition: op.vsEdition,
    channel: op.vsChannel,
    installPath: op.vsInstallPath,
    workloads: op.vsWorkloads,
    components: op.vsComponents,
    strict: op.vsStrict)

# ===========================================================================
# Desired-state digest. The non-elevated planner computes this; the
# broker compares its re-observed state against the value the plan
# expected. For `windows.vsInstaller` the desired state is always an
# in-sync product (`canonicalVsInstallerDesired`); the observed state's
# digest is what differs when a modify / install is needed.
# ===========================================================================

proc vsInstallerDesiredDigestHex*(op: PrivilegedOperation): string =
  ## Canonical desired-state digest for a `windows.vsInstaller`
  ## operation. A destroy (uninstall) op's desired state is "absent".
  if op.vsDestroy:
    vsDigestHexOfText("vsInstaller:absent")
  else:
    vsDigestHexOfText(canonicalVsInstallerDesired())

# ===========================================================================
# vswhere.exe location + invocation (Windows only).
# ===========================================================================

when defined(windows):
  const VsWhereWellKnownPath =
    r"C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    ## The path the VS installer itself installs `vswhere.exe` at. The
    ## spec says Reprobuild ships an EMBEDDED copy; until that embedded
    ## copy is wired through the build, the driver prefers a
    ## `vswhere.exe` sitting next to the `repro` binary, then falls
    ## back to the well-known installer location, then to `PATH`.

  proc resolveVsWhere(): string =
    ## Locate `vswhere.exe`. Preference order: next to the running
    ## binary (the future embedded copy), the VS-installer well-known
    ## location, then bare `vswhere.exe` (resolved via PATH).
    let beside = getAppDir() / "vswhere.exe"
    if fileExists(beside):
      return beside
    if fileExists(VsWhereWellKnownPath):
      return VsWhereWellKnownPath
    return "vswhere.exe"

  proc resolveVsInstaller(): string =
    ## Locate the resident VS installer (`vs_installer.exe`). The
    ## bootstrapper `vs_<edition>.exe` installs this; once VS is on the
    ## machine the resident installer is the right binary for
    ## modify/uninstall.
    const wellKnown =
      r"C:\Program Files (x86)\Microsoft Visual Studio\Installer\vs_installer.exe"
    if fileExists(wellKnown):
      return wellKnown
    return "vs_installer.exe"

  proc bootstrapperExeName(edition: string): string =
    ## The bootstrapper executable name for a given VS edition.
    ## Microsoft's aka.ms redirects use the lower-cased edition.
    "vs_" & edition.toLowerAscii() & ".exe"

  proc resolveVsBootstrapper(edition: string): string =
    ## Locate the edition-specific bootstrapper `vs_<edition>.exe` used
    ## for a FRESH install. Unlike the resident `vs_installer.exe`,
    ## this binary is NOT installed by the OS — the harness / dev
    ## environment must stage it. Preference order:
    ##   * next to the running binary (`getAppDir()` — the future
    ##     embedded / dev-shell copy),
    ##   * next to the staged `repro.exe` (parent dir of the
    ##     `REPROBUILD_REPRO` env var, or the `REPRO_TEST_BIN_DIR`
    ##     override the M69 destructive gates set when the gate test
    ##     exe lives in a DIFFERENT dir from the staged `repro.exe`
    ##     and `getAppDir()` therefore does not point at the
    ##     bootstrapper's actual home),
    ##   * in `%TEMP%\vs_<edition>.exe` (the path the provisioning
    ##     script downloads to),
    ##   * in `%LOCALAPPDATA%\Repro\vs_<edition>.exe`.
    ## Returns the empty string if none of the candidates exist — the
    ## caller must surface a clear "missing bootstrapper" error rather
    ## than silently launching a `vs_installer.exe install` that fails
    ## fast on a clean machine.
    let name = bootstrapperExeName(edition)
    let appDir = getAppDir()
    let beside = appDir / name
    if fileExists(beside):
      return beside
    # Parent dir of the staged `repro.exe`. The M69 destructive-gate
    # harness stages `vs_<edition>.exe` next to `repro.exe` (e.g.
    # `C:\harness\repro\vs_buildtools.exe`); the gate's test exe lives
    # under a sibling dir (e.g. `C:\harness\gate-bin\`) so `getAppDir()`
    # — the test exe's own dir — does NOT see the bootstrapper. The
    # harness publishes the staged `repro.exe` location via either
    # `REPROBUILD_REPRO` (full path) or `REPRO_TEST_BIN_DIR` (dir).
    proc tryReproDir(dir: string): string =
      if dir.len > 0 and dir != appDir:
        let cand = dir / name
        if fileExists(cand):
          return cand
      ""
    let reproExeEnv = getEnv("REPROBUILD_REPRO")
    if reproExeEnv.len > 0:
      let hit = tryReproDir(parentDir(reproExeEnv))
      if hit.len > 0:
        return hit
    let reproBinDir = getEnv("REPRO_TEST_BIN_DIR")
    if reproBinDir.len > 0:
      let hit = tryReproDir(reproBinDir)
      if hit.len > 0:
        return hit
    let tempDir = getEnv("TEMP")
    if tempDir.len > 0:
      let inTemp = tempDir / name
      if fileExists(inTemp):
        return inTemp
    let localAppData = getEnv("LOCALAPPDATA")
    if localAppData.len > 0:
      let inLocal = localAppData / "Repro" / name
      if fileExists(inLocal):
        return inLocal
    return ""

  proc runVsWhere(): tuple[output: string; code: int] =
    ## Run `vswhere -products * -include packages -format json -utf8`
    ## and capture stdout. `-include packages` makes vswhere emit the
    ## per-product workload/component package list the membership diff
    ## needs.
    let exe = resolveVsWhere()
    let cmd = quoteShell(exe) &
      " -products * -prerelease -include packages -format json -utf8"
    let (output, code) = execCmdEx(cmd)
    (output, code)

  proc runVsInstaller(args: seq[string]): tuple[output: string; code: int] =
    ## Run the resident `vs_installer.exe` with a typed argv. Used for
    ## `modify` / `uninstall` once VS is on the machine. Fresh installs
    ## go through `runVsBootstrapper` instead — the resident installer
    ## cannot perform a true fresh install on a machine where no
    ## product / channel is yet registered.
    let exe = resolveVsInstaller()
    var cmd = quoteShell(exe)
    for a in args:
      cmd.add(" ")
      cmd.add(quoteShell(a))
    let (output, code) = execCmdEx(cmd)
    (output, code)

  proc runVsBootstrapper(edition: string;
                          args: seq[string]):
      tuple[output: string; code: int; missing: bool] =
    ## Run the edition-specific bootstrapper for a fresh install.
    ## `missing = true` (with code != 0 and empty output) signals that
    ## the bootstrapper was NOT staged on the machine; the caller
    ## should surface that as a clear configuration error.
    let exe = resolveVsBootstrapper(edition)
    if exe.len == 0:
      return (output: "", code: -1, missing: true)
    var cmd = quoteShell(exe)
    for a in args:
      cmd.add(" ")
      cmd.add(quoteShell(a))
    let (output, code) = execCmdEx(cmd)
    (output: output, code: code, missing: false)

# ===========================================================================
# observe — read the live VS installation through vswhere.
# ===========================================================================

proc observeVsInstallerState*(op: PrivilegedOperation):
    tuple[diff: VsMembershipDiff; products: seq[VsInstalledProduct]] =
  ## Re-observe: run vswhere, parse its output, and diff the installed
  ## workload/component set against the resource's desired set. The
  ## PURE pieces (`parseVsWhereOutput`, `diffMembership`) are the same
  ## functions the cross-platform unit tests exercise.
  when defined(windows):
    let (rawJson, code) = runVsWhere()
    if code != 0 and rawJson.strip().len == 0:
      raiseProtocol("windows.vsInstaller: vswhere.exe exited " & $code &
        " with no output — cannot observe the VS installation state")
    let products = parseVsWhereOutput(rawJson)
    result.products = products
    result.diff = diffMembership(desiredStateOf(op), products)
  else:
    raiseNotImplementedPlatform("windows.vsInstaller observe")

proc observeWindowsVsInstaller*(op: PrivilegedOperation):
    ObservedOperationState =
  ## The `dispatch.nim`-facing observe entry point. `present` is true
  ## when a matching VS product is installed; `digestHex` covers the
  ## canonical observed state (product presence + actionable membership
  ## delta) so the broker's drift gate is uniform with the other
  ## drivers.
  when defined(windows):
    let observed = observeVsInstallerState(op)
    result.present = observed.diff.productInstalled
    if not observed.diff.productInstalled:
      result.digestHex = ZeroDigestHex
    else:
      result.digestHex = vsDigestHexOfText(
        canonicalVsInstallerState(observed.diff, op.vsStrict))
  else:
    raiseNotImplementedPlatform("windows.vsInstaller observe")

# ===========================================================================
# apply — converge the installation through the VS installer.
# ===========================================================================

proc applyWindowsVsInstaller*(op: PrivilegedOperation):
    tuple[state: ObservedOperationState; restartNeeded: bool] =
  ## Converge the VS installation to the declared workload/component
  ## membership. Runs `vs_<edition>.exe install` (the bootstrapper)
  ## for a fresh install, and `vs_installer.exe modify` / `uninstall`
  ## for in-place mutations of an existing installation, as
  ## `classifyDrift` / `op.vsDestroy` select. NEVER auto-reboots —
  ## `--norestart` is always in the argv and a reboot requirement is
  ## surfaced via `restartNeeded`.
  ##
  ## Why the binary split:
  ##   * The resident `vs_installer.exe` is for modifying or
  ##     uninstalling an EXISTING install. On a freshly-uninstalled or
  ##     clean machine it can return non-zero in seconds without doing
  ##     anything useful (no channel registered, no layout).
  ##   * The edition-specific bootstrapper `vs_<edition>.exe` is what
  ##     performs a true fresh install. The args set matches the
  ##     M69 Hyper-V provisioning script — see
  ##     `buildBootstrapperInstallArgs`.
  when defined(windows):
    let desired = desiredStateOf(op)
    if op.vsDestroy:
      let (uOut, uCode) = runVsInstaller(buildUninstallArgs(desired))
      if not vsInstallerSucceeded(uCode):
        raiseProtocol("windows.vsInstaller uninstall of edition '" &
          op.vsEdition & "' failed (installer exit " & $uCode & "): " &
          uOut.strip())
      result.restartNeeded = vsInstallerRestartNeeded(uCode)
      result.state = observeWindowsVsInstaller(op)
      return
    let observed = observeVsInstallerState(op)
    let cls = classifyDrift(observed.diff)
    if cls == vsdInSync:
      # Already in sync — no mutation.
      result.state = observeWindowsVsInstaller(op)
      return
    if cls == vsdMembershipDrift and not desired.strict:
      # Non-strict membership-drift: leave-alone policy.
      result.state = observeWindowsVsInstaller(op)
      return
    if cls == vsdNeedsInstall:
      # Fresh install: use the edition-specific bootstrapper. The
      # resident vs_installer.exe cannot perform a true fresh install
      # on a clean machine.
      let bootArgs = buildBootstrapperInstallArgs(desired)
      let (bOut, bCode, bMissing) = runVsBootstrapper(op.vsEdition, bootArgs)
      if bMissing:
        raiseProtocol("windows.vsInstaller fresh install of edition '" &
          op.vsEdition & "' cannot proceed: the bootstrapper '" &
          "vs_" & op.vsEdition.toLowerAscii() & ".exe' is not staged " &
          "on the host. Expected one of: alongside the running " &
          "repro binary, %TEMP%, or %LOCALAPPDATA%\\Repro\\.")
      if not vsInstallerSucceeded(bCode):
        raiseProtocol("windows.vsInstaller fresh install of edition '" &
          op.vsEdition & "' failed (bootstrapper exit " & $bCode & "): " &
          bOut.strip())
      result.restartNeeded = vsInstallerRestartNeeded(bCode)
      result.state = observeWindowsVsInstaller(op)
      return
    # vsdNeedsModify OR (vsdMembershipDrift + strict): in-place
    # modification of an existing install.
    let args = buildInstallerArgs(desired, observed.diff)
    if args.len == 0:
      # Defensive: buildInstallerArgs returned no work even though
      # classifyDrift said we needed mutation. Treat as no-op rather
      # than crash.
      result.state = observeWindowsVsInstaller(op)
      return
    let (iOut, iCode) = runVsInstaller(args)
    if not vsInstallerSucceeded(iCode):
      raiseProtocol("windows.vsInstaller " & args[0] & " of edition '" &
        op.vsEdition & "' failed (installer exit " & $iCode & "): " &
        iOut.strip())
    result.restartNeeded = vsInstallerRestartNeeded(iCode)
    result.state = observeWindowsVsInstaller(op)
  else:
    raiseNotImplementedPlatform("windows.vsInstaller apply")
