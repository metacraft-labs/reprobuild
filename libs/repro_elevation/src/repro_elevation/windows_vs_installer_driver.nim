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
    ## Run the VS installer with a typed argv. The argument LIST is
    ## built by `buildInstallerArgs` from typed operation fields — no
    ## operator string is ever interpolated into a shell command.
    let exe = resolveVsInstaller()
    var cmd = quoteShell(exe)
    for a in args:
      cmd.add(" ")
      cmd.add(quoteShell(a))
    let (output, code) = execCmdEx(cmd)
    (output, code)

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
  ## membership. Runs `vs_installer install` / `modify` / `uninstall`
  ## as `classifyDrift` / `op.vsDestroy` select. NEVER auto-reboots —
  ## `--norestart` is always in the argv and a reboot requirement is
  ## surfaced via `restartNeeded`.
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
    let args = buildInstallerArgs(desired, observed.diff)
    if args.len == 0:
      # No mutation required (already in sync, or a non-strict
      # membership-drift the leave-alone policy ignores).
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
