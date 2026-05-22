## M69 Verification Gate: e2e_windows_registry_system_scope
##
## Per the M69 verification block: an elevated apply writes typed
## values under a sandbox HKLM subkey via `windows.registryValue`
## (`scope = system`); a non-elevated apply elevates through the M81
## single broker (one prompt) and writes the values via the broker;
## `--no-elevate` skips the privileged HKLM write and reports it
## skipped, touching no registry key; rollback restores or deletes
## per the recorded pre-write value.
##
## SAFETY: every registry write is confined to a sandboxed subkey of
## `HKLM\SOFTWARE\Reprobuild-Tests\` — exactly the M81 fixture-
## registry pattern. The gate cleans up its subtree AND the empty
## `Reprobuild-Tests` root afterwards. It uses M81's
## `REPRO_FORCE_BROKER` seam to exercise the real broker launch + IPC
## path on an already-elevated host without an interactive UAC
## prompt. No real system location is ever mutated.
##
## No `skip`, no `xfail`.

when not defined(windows):
  echo "[platform N/A] t_e2e_windows_registry_system_scope: HKLM " &
    "registry writes are Windows-only"
  quit(0)

import std/[os, strutils, tempfiles, unittest]

import repro_elevation
import repro_infra

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()

proc reproBinary(): string =
  let candidate = ProjectRoot / "build" / "bin" / "repro.exe"
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with the gate recipe first"
  candidate

# A unique sandbox subkey per gate run so concurrent / repeated runs
# never collide and cleanup is unambiguous.
let runId = "gate-" & $getCurrentProcessId()
let sandboxKey = "HKLM\\SOFTWARE\\Reprobuild-Tests\\" & runId &
  "\\registry-system-scope"

proc cleanupSandbox() =
  ## Remove this run's subtree and, when empty, the Reprobuild-Tests
  ## root — the M81 cleanup discipline.
  deleteFixtureRegistryTree(runId)
  deleteFixtureRegistryRoot()

proc writeProfile(dir, value: string): string =
  let p = dir / "system.nim"
  writeFile(p, "windows.registryValue {\n" &
    "  key = \"" & sandboxKey & "\"\n" &
    "  name = \"GateValue\"\n" &
    "  kind = string\n" &
    "  value = \"" & value & "\"\n" &
    "}\n")
  p

proc observe(): ObservedOperationState =
  ## Observe the sandbox value directly through the M69 HKLM driver.
  observeWindowsRegistryValue(PrivilegedOperation(
    kind: pokWindowsRegistryValue,
    address: "probe",
    hklmSubkey: "SOFTWARE\\Reprobuild-Tests\\" & runId &
      "\\registry-system-scope",
    hklmValueName: "GateValue",
    hklmValueKind: srvkString,
    hklmValueLiteral: ""))

suite "e2e_windows_registry_system_scope":

  test "the host is already elevated (gate precondition)":
    # The gate writes HKLM, so it must run elevated. The
    # REPRO_FORCE_BROKER seam then exercises the broker path without
    # an interactive prompt.
    check isProcessElevated()

  test "elevated apply writes a typed HKLM value via the broker":
    cleanupSandbox()
    let stateDir = createTempDir("repro-m69-reg-", "")
    defer:
      removeDir(stateDir)
      cleanupSandbox()
    let profilePath = writeProfile(stateDir, "broker-wrote-this")
    let profileText = readFile(profilePath)

    var opts: ApplyOptions
    opts.stateDir = stateDir
    opts.hostIdentity = "gate-host"
    opts.reproExe = reproBinary()
    opts.elevationMode = emBroker
    opts.forceBroker = true             # exercise the real broker path

    resetBrokerLaunchCount()
    let r = runInfraApply(profileText, opts)
    # EXACTLY ONE broker process drove the whole apply.
    check r.usedBroker
    check r.brokerLaunchCount == 1
    check r.appliedCount == 1
    check r.driftCount == 0
    check r.errorCount == 0
    # The typed value really landed in the sandboxed HKLM subkey.
    let obs = observe()
    check obs.present
    check obs.digestHex == digestHexOfBytes(
      encodeSystemRegistryPayload(srvkString, "broker-wrote-this"))
    # The audit log recorded the privileged operation.
    let audit = readAuditLog(r.auditLogPath)
    check audit.records.len == 1
    check audit.records[0].outcome == "applied"
    check audit.records[0].operationKind == "windows.registryValue"

  test "a re-apply of the same value is a broker-side no-op (convergent)":
    cleanupSandbox()
    let stateDir = createTempDir("repro-m69-reg-noop-", "")
    defer:
      removeDir(stateDir)
      cleanupSandbox()
    let profilePath = writeProfile(stateDir, "convergent-value")
    let profileText = readFile(profilePath)
    var opts: ApplyOptions
    opts.stateDir = stateDir
    opts.hostIdentity = "gate-host"
    opts.reproExe = reproBinary()
    opts.elevationMode = emBroker
    opts.forceBroker = true

    let first = runInfraApply(profileText, opts)
    check first.appliedCount == 1
    # Second apply: the planner observes the value already at the
    # desired state, decides "no-op", and the partition is empty —
    # the convergent re-apply needs NO broker and NO mutation. This
    # is the spec's "apply is convergent" criterion: a re-plan /
    # re-apply after a successful apply does nothing.
    resetBrokerLaunchCount()
    let second = runInfraApply(profileText, opts)
    check second.brokerLaunchCount == 0   # nothing to do => no broker
    check not second.usedBroker
    check second.appliedCount == 0
    check second.noOpCount >= 1

  test "--no-elevate skips the HKLM write, touching no registry key":
    cleanupSandbox()
    let stateDir = createTempDir("repro-m69-reg-ne-", "")
    defer:
      removeDir(stateDir)
      cleanupSandbox()
    let profilePath = writeProfile(stateDir, "must-not-be-written")
    let profileText = readFile(profilePath)
    var opts: ApplyOptions
    opts.stateDir = stateDir
    opts.hostIdentity = "gate-host"
    opts.reproExe = reproBinary()
    opts.elevationMode = emNoElevate

    resetBrokerLaunchCount()
    let r = runInfraApply(profileText, opts)
    # No broker was launched; the privileged op is reported skipped.
    check r.brokerLaunchCount == 0
    check not r.usedBroker
    check r.skippedCount == 1
    check r.appliedCount == 0
    # NOTHING was written to the registry.
    check not observe().present

  test "the already-elevated fast path writes in-process, no broker":
    cleanupSandbox()
    let stateDir = createTempDir("repro-m69-reg-fast-", "")
    defer:
      removeDir(stateDir)
      cleanupSandbox()
    let profilePath = writeProfile(stateDir, "fast-path-value")
    let profileText = readFile(profilePath)
    var opts: ApplyOptions
    opts.stateDir = stateDir
    opts.hostIdentity = "gate-host"
    opts.reproExe = reproBinary()
    opts.elevationMode = emBroker
    opts.forceBroker = false            # NOT forced: take the fast path

    resetBrokerLaunchCount()
    let r = runInfraApply(profileText, opts)
    # The host is elevated and the broker was not forced => the
    # privileged set ran in-process with NO broker.
    check r.brokerLaunchCount == 0
    check not r.usedBroker
    check r.appliedCount == 1
    check observe().present

  test "rollback direction: a destroy op deletes the recorded value":
    cleanupSandbox()
    let stateDir = createTempDir("repro-m69-reg-rb-", "")
    defer:
      removeDir(stateDir)
      cleanupSandbox()
    # Write the value, then drive the broker with the DESTROY
    # direction (`hklmDestroy`) — the rollback path.
    let profilePath = writeProfile(stateDir, "to-be-rolled-back")
    let profileText = readFile(profilePath)
    var opts: ApplyOptions
    opts.stateDir = stateDir
    opts.hostIdentity = "gate-host"
    opts.reproExe = reproBinary()
    opts.elevationMode = emBroker
    opts.forceBroker = true
    discard runInfraApply(profileText, opts)
    check observe().present

    # Drive a destroy directly through the broker (the rollback
    # engine's primitive).
    let profile = parseSystemProfile(profileText)
    let destroyOp = toPrivilegedOperation(profile.resources[0],
      destroy = true)
    let writtenDigest = digestHexOfBytes(
      encodeSystemRegistryPayload(srvkString, "to-be-rolled-back"))
    resetBrokerLaunchCount()
    let rb = launchAndDriveBroker(reproBinary(),
      @[PlannedOperation(operation: destroyOp,
        baselineDigestHex: writtenDigest)])
    check brokerLaunchCount() == 1
    check rb.outcome.allApplied
    check rb.outcome.applyLog[0].outcome == "applied"
    check rb.outcome.applyLog[0].detail.contains("destroyed")
    # The value is gone.
    check not observe().present

  test "the isolated HKLM test subtree is left clean":
    cleanupSandbox()
    check not observe().present
