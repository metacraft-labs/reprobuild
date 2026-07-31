## Regression tests for the `windows.service` recovery-policy digest
## round-trip — the seam where a declared failure-recovery policy
## (typed `WindowsServiceRecoveryActionKind` enum) has to meet the same
## policy read back out of the SCM as `sc.exe qfailure` TEXT.
##
## WHY THIS FILE EXISTS
##
## `repro infra apply` decides applied-vs-no-op by comparing the digest
## of the OBSERVED live state against the digest of the DESIRED state.
## A managed service reported `applied` on every apply forever, with
## identical pre- and post-digests, because the desired side rendered
## only `service:<startType>:<running>` while the observed side folded
## in the declared displayName / binPath / recovery policy. The two
## strings could never be equal, so the resource never converged.
##
## The digest-symmetry suite in `t_smoke_repro_elevation.nim` pins that
## desired/observed asymmetry, but it hand-builds every
## `ServiceObservation` from string literals. That leaves the LAST link
## untested: nothing checks that the action tokens
## `parseScQfailureOutput` produces from real `sc.exe qfailure` text are
## the same vocabulary `windowsServiceRecoveryActionToken` emits for the
## typed enum. If those two vocabularies disagreed (`RESTART` vs
## `restart`, seconds vs milliseconds), the desired state would be
## unreachable and the resource would re-apply forever EVEN THOUGH the
## symmetry tests pass. These tests close that gap by driving the
## observation through the real parser.
##
## MOCKS: NONE, and none are justified-away.
##
## The `sc.exe qfailure` and `Get-Service` probe blocks below are the
## VERBATIM bytes captured from a live Windows Server host running a
## service that declares three restart slots — column alignment, the
## blank `REBOOT_MESSAGE` / `COMMAND_LINE` fields, the `[SC]` banner and
## the indented continuation lines are exactly as `sc.exe` printed them.
## Only the service name, display name and binary path were replaced
## with generic placeholders (this repository is public); the shape the
## parser walks is untouched. The capture contains no credentials.
##
## The drivers that shell out to PowerShell (`observeWindowsService` /
## `applyWindowsService`) sit behind `when defined(windows)` and are not
## reachable from a Linux test binary. What IS reachable — and what the
## defect actually lived in — is the pure parse + canonicalize + digest
## path, which these tests exercise end to end against the real text.

import std/[strutils, unittest]

import repro_elevation

# ---------------------------------------------------------------------------
# Real captured probe output (see MOCKS note in the header).
# ---------------------------------------------------------------------------

const realGetServiceProbe = """StartType=Automatic
Status=Running
DisplayName=Example Runner Service
BinPath=C:\example-runner\bin\RunnerService.exe
"""

const realScQfailureOutput = """[SC] QueryServiceConfig2 SUCCESS

SERVICE_NAME: example.runner.service
        RESET_PERIOD (in seconds)    : 3600
        REBOOT_MESSAGE               :
        COMMAND_LINE                 :
        FAILURE_ACTIONS              : RESTART -- Delay = 60000 milliseconds.
                                       RESTART -- Delay = 60000 milliseconds.
                                       RESTART -- Delay = 60000 milliseconds.
"""

## The same host's `sc.exe qfailure` output for a service with NO
## failure-recovery policy configured — the genuine-drift counterpart.
const realScQfailureNoPolicy = """[SC] QueryServiceConfig2 SUCCESS

SERVICE_NAME: example.runner.service
        RESET_PERIOD (in seconds)    : 0
        REBOOT_MESSAGE               :
        COMMAND_LINE                 :
        FAILURE_ACTIONS              :
"""

proc declaredOp(): PrivilegedOperation =
  ## The operation a profile declaring three 60-second restart slots and
  ## a one-hour reset window compiles to.
  PrivilegedOperation(kind: pokWindowsService,
    address: "runnerService",
    serviceName: "example.runner.service",
    serviceStartType: "Automatic", serviceRunning: true,
    serviceDisplayName: "Example Runner Service",
    serviceBinPath: "C:\\example-runner\\bin\\RunnerService.exe",
    serviceRecoveryActions: @[
      WindowsServiceRecoverySpec(action: wsrakRestart, delayMs: 60_000),
      WindowsServiceRecoverySpec(action: wsrakRestart, delayMs: 60_000),
      WindowsServiceRecoverySpec(action: wsrakRestart, delayMs: 60_000)],
    serviceRecoveryResetSeconds: 3600)

proc observeFrom(op: PrivilegedOperation; probeText, qfailureText: string):
    string =
  ## Reproduce EXACTLY what `observeWindowsService` digests: parse the
  ## `Get-Service` probe, overlay the `sc qfailure` policy, then
  ## canonicalize against the fields the operation declares.
  var obs = parseServiceQuery(probeText)
  let qf = parseScQfailureOutput(qfailureText)
  obs.recoveryActions = qf.actions
  obs.recoveryResetSeconds = qf.resetSeconds
  digestHexOfText(canonicalServiceState(obs,
    wantDisplayName = op.serviceDisplayName,
    wantBinPath = op.serviceBinPath,
    wantRecoveryActions = desiredServiceRecoverySlots(op),
    wantRecoveryResetSeconds = op.serviceRecoveryResetSeconds))

suite "repro_elevation: windows.service recovery-policy digest round-trip":

  test "sc qfailure tokens match the tokens the typed enum renders":
    # The identity the whole resource rests on: the vocabulary the
    # OBSERVED side parses out of sc.exe text and the vocabulary the
    # DESIRED side renders from the typed enum must be the same, in the
    # same units (milliseconds), in declaration order.
    let op = declaredOp()
    let parsed = parseScQfailureOutput(realScQfailureOutput)
    let declared = desiredServiceRecoverySlots(op)
    check parsed.actions.len == declared.len
    for i in 0 ..< declared.len:
      check parsed.actions[i].action == declared[i].action
      check parsed.actions[i].delayMs == declared[i].delayMs
    check parsed.resetSeconds == op.serviceRecoveryResetSeconds
    # Pin the vocabulary itself so a rename on either side is caught.
    check declared[0].action == "restart"
    check declared[0].delayMs == 60_000

  test "a service already at its declared policy digests equal on both sides":
    # THE IDENTITY THAT WAS BROKEN. Desired and observed are computed by
    # the two production entry points, with the observation coming from
    # real sc.exe / Get-Service text rather than hand-built literals.
    let op = declaredOp()
    check systemDesiredDigestHex(op) ==
      observeFrom(op, realGetServiceProbe, realScQfailureOutput)

  test "the converged canonical string carries the full declared policy":
    # Guards against "converging" by dropping fields from BOTH sides:
    # the digest must still cover displayName, binPath, every recovery
    # slot and the reset window.
    var obs = parseServiceQuery(realGetServiceProbe)
    let qf = parseScQfailureOutput(realScQfailureOutput)
    obs.recoveryActions = qf.actions
    obs.recoveryResetSeconds = qf.resetSeconds
    let op = declaredOp()
    let canon = canonicalServiceState(obs,
      wantDisplayName = op.serviceDisplayName,
      wantBinPath = op.serviceBinPath,
      wantRecoveryActions = desiredServiceRecoverySlots(op),
      wantRecoveryResetSeconds = op.serviceRecoveryResetSeconds)
    check canon == "service:Automatic:running" &
      ":displayName=Example Runner Service" &
      ":binPath=C:\\example-runner\\bin\\RunnerService.exe" &
      ":recovery=restart/60000,restart/60000,restart/60000" &
      ":reset=3600"
    check canonicalServiceDesired(op.serviceStartType, op.serviceRunning,
      wantDisplayName = op.serviceDisplayName,
      wantBinPath = op.serviceBinPath,
      wantRecoveryActions = desiredServiceRecoverySlots(op),
      wantRecoveryResetSeconds = op.serviceRecoveryResetSeconds) == canon

  test "a service with NO recovery policy still digests as drift":
    # Genuine drift: the operator declared three restart slots, the SCM
    # has none. The resource MUST still apply.
    let op = declaredOp()
    check systemDesiredDigestHex(op) !=
      observeFrom(op, realGetServiceProbe, realScQfailureNoPolicy)
    var obs = parseServiceQuery(realGetServiceProbe)
    let qf = parseScQfailureOutput(realScQfailureNoPolicy)
    obs.recoveryActions = qf.actions
    obs.recoveryResetSeconds = qf.resetSeconds
    check not serviceMatchesDesired(obs, op.serviceStartType,
      op.serviceRunning,
      wantDisplayName = op.serviceDisplayName,
      wantBinPath = op.serviceBinPath,
      wantRecoveryActions = desiredServiceRecoverySlots(op),
      wantRecoveryResetSeconds = op.serviceRecoveryResetSeconds)

  test "a drifted backoff delay digests as drift":
    # Same three restart slots, wrong backoff — the delay must be part
    # of the comparison, not just the action token.
    let driftedDelay = realScQfailureOutput.replace(
      "Delay = 60000 milliseconds.", "Delay = 30000 milliseconds.")
    let op = declaredOp()
    check systemDesiredDigestHex(op) !=
      observeFrom(op, realGetServiceProbe, driftedDelay)

  test "a drifted reset window digests as drift":
    let driftedReset = realScQfailureOutput.replace(
      "(in seconds)    : 3600", "(in seconds)    : 86400")
    let op = declaredOp()
    check systemDesiredDigestHex(op) !=
      observeFrom(op, realGetServiceProbe, driftedReset)

  test "a service missing one of the three restart slots digests as drift":
    # Partial policy — two slots where three were declared.
    let twoSlots = """[SC] QueryServiceConfig2 SUCCESS

SERVICE_NAME: example.runner.service
        RESET_PERIOD (in seconds)    : 3600
        REBOOT_MESSAGE               :
        COMMAND_LINE                 :
        FAILURE_ACTIONS              : RESTART -- Delay = 60000 milliseconds.
                                       RESTART -- Delay = 60000 milliseconds.
"""
    let op = declaredOp()
    check systemDesiredDigestHex(op) !=
      observeFrom(op, realGetServiceProbe, twoSlots)
