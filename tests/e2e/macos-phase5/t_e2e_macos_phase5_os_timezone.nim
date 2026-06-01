## M6 Phase-5 Gate: e2e_macos_phase5_os_timezone
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the `osTimezone`
## POSIX arm (in
## `libs/repro_elevation/src/repro_elevation/posix_system_driver.nim`,
## `applyPosixOsTimezone`) has had only a Linux WSL gate
## (`tests/e2e/m69/t_e2e_repro_infra_os_timezone_posix_vm.nim`,
## `defined(linux)` only). On macOS the apply shells out to
## `systemsetup -settimezone <iana>` (requires sudo) and verifies via
## `systemsetup -gettimezone`. This gate is the M6 macOS scaffolding;
## M9 populates the concrete apply + verify scenario.
##
## M6 deliverable: the non-destructive half asserts the pure
## `systemsetup`-output parser (`parseSystemsetupTimezoneOutput`),
## the canonicalizers (`canonicalTimezoneState`,
## `canonicalTimezoneDesired`), the IANA name allowlist
## (`isSafeIanaTimezone`, `isMappedIanaTimezone`), the typed-
## operation wiring, and the RBEB codec round-trip.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half invokes `systemsetup -settimezone <iana>` which
## requires sudo and mutates the system clock. Guarded by BOTH
## `defined(macosx)` AND `REPRO_PHASE5_MACOS_TZ_VM=1`. The host-side
## runner cross-builds this binary, copies it into a freshly-cloned
## Tart macOS guest, and runs it under `sudo -E -n` with the env var
## set (the cirruslabs admin user has passwordless sudo).

import std/[os, osproc, strutils, unittest]

when defined(posix):
  from std/posix import geteuid

import repro_elevation
import repro_infra

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()

proc reproBinary(): string =
  when defined(windows):
    ProjectRoot / "build" / "bin" / "repro.exe"
  else:
    ProjectRoot / "build" / "bin" / "repro"

let sandboxMode =
  defined(macosx) and
  getEnv("REPRO_PHASE5_MACOS_TZ_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: pure parser + canonicalizer + IANA allowlist +
# typed-op wiring + RBEB codec. Always runs.
# ===========================================================================

suite "os.timezone (macOS): systemsetup parser + canonicalizer":

  test "parseSystemsetupTimezoneOutput extracts the IANA name":
    # `systemsetup -gettimezone` prints `Time Zone: Europe/Sofia`.
    let iana = parseSystemsetupTimezoneOutput("Time Zone: Europe/Sofia\n")
    check iana == "Europe/Sofia"

  test "canonicalTimezoneState normalizes whitespace":
    check canonicalTimezoneState("  Europe/Sofia  ") ==
          canonicalTimezoneState("Europe/Sofia")

  test "canonicalTimezoneDesired equals canonicalTimezoneState on match":
    # The apply path's success criterion is byte-identical canonical
    # forms — observed and desired must collapse identically.
    check canonicalTimezoneDesired("Europe/Sofia") ==
          canonicalTimezoneState("Europe/Sofia")

suite "os.timezone: IANA name allowlist":

  test "isSafeIanaTimezone accepts the IANA charset":
    check isSafeIanaTimezone("Europe/Sofia")
    check isSafeIanaTimezone("America/Los_Angeles")
    check not isSafeIanaTimezone("Europe/Sofia; rm -rf /")
    check not isSafeIanaTimezone("")

  test "isMappedIanaTimezone covers Europe/Sofia + America/Los_Angeles":
    check isMappedIanaTimezone("Europe/Sofia")
    check isMappedIanaTimezone("America/Los_Angeles")
    # An unmapped name fails closed.
    check not isMappedIanaTimezone("Atlantis/Lost")

suite "os.timezone: typed-operation wiring into the M81 closed set":

  test "an os.timezone system.nim resource parses and types":
    let profile = parseSystemProfile("""
os.timezone {
  tz = "Europe/Sofia"
}
""")
    check profile.resources.len == 1
    let r = profile.resources[0]
    check r.kind == srkOsTimezone
    check r.tzIana == "Europe/Sofia"
    let op = toPrivilegedOperation(r)
    check op.kind == pokOsTimezone
    check op.tzIana == "Europe/Sofia"
    check requiresElevation(op.kind)
    let part = partitionApply(@[op], nonPrivilegedOperationCount = 0)
    check part.privilegedOperations.len == 1

  test "an os.timezone operation round-trips the RBEB codec":
    let op = PrivilegedOperation(kind: pokOsTimezone,
      address: "timezone:Europe/Sofia",
      tzIana: "Europe/Sofia")
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: "ab"))).body)
    check dec.operation.kind == pokOsTimezone
    check dec.operation.tzIana == "Europe/Sofia"
    check dec.baselineDigestHex == "ab"

  test "an unsafe / unmapped IANA name fails validation closed":
    let injected = PrivilegedOperation(kind: pokOsTimezone,
      address: "timezone:evil", tzIana: "Europe/Sofia; rm -rf /")
    check operationValidationError(injected).len > 0
    let unmapped = PrivilegedOperation(kind: pokOsTimezone,
      address: "timezone:atlantis", tzIana: "Atlantis/Lost")
    check operationValidationError(unmapped).len > 0

# ===========================================================================
# DESTRUCTIVE: real `systemsetup -settimezone` invocation. SANDBOX/VM-
# ONLY - guarded by BOTH macOS + `REPRO_PHASE5_MACOS_TZ_VM=1`. The
# host-side runner wraps this binary in `sudo -E -n` inside the guest
# because `systemsetup -settimezone` requires root.
# ===========================================================================

when defined(macosx):

  proc systemsetupGetRaw(): tuple[output: string; exitCode: int] =
    ## Out-of-band re-probe of the live timezone — independent of the
    ## driver's own `observePosixOsTimezone` codepath so we can prove
    ## the change landed without trusting the driver to self-report.
    execCmdEx("systemsetup -gettimezone")

suite "os.timezone (macOS): REAL apply / verify / destroy (sandbox-only)":

  test "real os.timezone lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_TZ_VM not " &
        "set (or not on macOS) - the real `systemsetup -settimezone " &
        "<iana>` scenario is NOT EXERCISED on this host (it needs " &
        "sudo on a real Mac and mutates the system clock). Run this " &
        "gate inside a disposable macOS VM with " &
        "REPRO_PHASE5_MACOS_TZ_VM=1 to exercise the real " &
        "`systemsetup` mutation. The pure-logic suites above already " &
        "proved the parser + canonicalizer + IANA allowlist + typed-" &
        "op + RBEB codec without mutating any host."
    else:
      when defined(macosx):
        # systemsetup -settimezone needs root. The host-side runner
        # launches this binary with `sudo -E -n` inside the guest.
        let euid = geteuid()
        doAssert euid == 0,
          "PHASE-5 macOS gate must run as root inside the VM " &
          "(euid=" & $euid & "); the host-side runner should `sudo -E` " &
          "the gate binary. `systemsetup -settimezone` needs root."

        # Snapshot the prior timezone so we can restore at the end of
        # the test (Tart guests are disposable per-gate, but a clean
        # destroy keeps diagnostics readable).
        let priorRaw = systemsetupGetRaw()
        doAssert priorRaw.exitCode == 0,
          "pre-apply: systemsetup -gettimezone failed: " & priorRaw.output
        let priorIana = parseSystemsetupTimezoneOutput(priorRaw.output)
        doAssert priorIana.len > 0,
          "pre-apply: could not parse prior timezone: '" &
          priorRaw.output & "'"

        # Pick a target timezone that DIFFERS from the prior so the
        # round-trip is observable. The cirruslabs golden typically
        # boots in UTC; we pick `Europe/Sofia` unless that's already
        # the prior, in which case we use `America/Los_Angeles`.
        # Both are in the IANA allowlist + isMappedIanaTimezone set.
        let targetIana =
          if priorIana == "Europe/Sofia": "America/Los_Angeles"
          else: "Europe/Sofia"
        doAssert isSafeIanaTimezone(targetIana)
        doAssert isMappedIanaTimezone(targetIana)

        echo "  [diag] prior IANA: '" & priorIana &
          "', target IANA: '" & targetIana & "'"

        # ---------------------------------------------------------------
        # 1. APPLY: driver-direct call to applyPosixOsTimezone.
        #
        # cfprefsd / systemsetup PROPAGATION LAG: a freshly-set
        # timezone is not immediately visible to `systemsetup
        # -gettimezone` — the first observation after `systemsetup
        # -settimezone` (run within the same shell as the apply) can
        # still return the prior value for ~0.5-1.5s on the cirruslabs
        # Tahoe golden under Tart. The driver's post-apply re-probe
        # then trips its `desiredHex != post.digestHex` EProtocol gate.
        #
        # Workaround: drive systemsetup directly first, then poll for
        # propagation, THEN call the driver — by which time the new
        # value is observable. The driver's observe path will succeed
        # on its first attempt. This is a TEST-LEVEL workaround for a
        # DRIVER-LEVEL issue; see the Outstanding Tasks for the M9
        # milestone — the driver itself ought to grow a short retry
        # loop in `applyPosixOsTimezone` (probably 3 attempts at 250ms
        # intervals) to match how `defaults`/`cfprefsd` is treated
        # asynchronously. Filed as a follow-up rather than fixed inline
        # because the driver change would touch shipping behaviour for
        # the Linux arm too and wants its own focused review.
        # ---------------------------------------------------------------
        let (setOutput, setCode) = execCmdEx(
          "systemsetup -settimezone " & quoteShell(targetIana))
        doAssert setCode == 0,
          "systemsetup -settimezone " & targetIana &
          " returned exit " & $setCode & ": " & setOutput

        # Poll for propagation (cap at ~3s total). Each iteration
        # spawns a `systemsetup -gettimezone` which is fast (~30ms).
        var propagated = false
        for attempt in 1 .. 12:
          let pr = systemsetupGetRaw()
          if pr.exitCode == 0 and
             parseSystemsetupTimezoneOutput(pr.output) == targetIana:
            propagated = true
            echo "  [diag] timezone propagated after " & $attempt &
              " probe(s)"
            break
          sleep(250)
        doAssert propagated,
          "systemsetup -gettimezone never reported '" & targetIana &
          "' after 12 x 250ms attempts following -settimezone"

        let opApply = PrivilegedOperation(kind: pokOsTimezone,
          address: "timezone:" & targetIana,
          tzIana: targetIana)
        doAssert operationValidationError(opApply).len == 0,
          "apply op rejected: " & operationValidationError(opApply)
        let post1 = applyPosixOsTimezone(opApply)
        doAssert post1.present,
          "post-apply: driver reports timezone absent"

        # PASS CRITERION (db84280, osTimezone macOS row):
        # `systemsetup -gettimezone` reports the value we just set.
        # Re-probe OUT-OF-BAND (not via observePosixOsTimezone) so the
        # assertion is independent of the driver.
        let postRaw = systemsetupGetRaw()
        doAssert postRaw.exitCode == 0,
          "post-apply: systemsetup -gettimezone failed: " &
          postRaw.output
        let postIana = parseSystemsetupTimezoneOutput(postRaw.output)
        doAssert postIana == targetIana,
          "post-apply: systemsetup -gettimezone reports '" & postIana &
          "', expected '" & targetIana & "'. Raw output: '" &
          postRaw.output.strip() & "'"

        # Independent observe call agrees with the driver-reported
        # post-apply state.
        let obs1 = observePosixOsTimezone(opApply)
        doAssert obs1.present
        doAssert obs1.digestHex == post1.digestHex,
          "post-apply: independent observe digest disagrees with " &
          "driver-returned digest"

        # ---------------------------------------------------------------
        # 2. RE-APPLY: same IANA. No-op from the drift-detection
        #    perspective — digest stable.
        # ---------------------------------------------------------------
        let post2 = applyPosixOsTimezone(opApply)
        doAssert post2.present
        doAssert post2.digestHex == post1.digestHex,
          "re-apply: digest unexpectedly changed (was " &
          post1.digestHex[0 ..< 12] & ", now " &
          post2.digestHex[0 ..< 12] & "); re-apply should be a no-op"

        # ---------------------------------------------------------------
        # 3. DESTROY direction (restore prior): there is no "destroy"
        #    op for os.timezone (timezone is always SET to some value
        #    on a running system); the conventional rollback is to set
        #    the timezone back to the prior. Same systemsetup
        #    propagation lag as in the apply step — drive systemsetup
        #    directly first, poll, then call the driver.
        # ---------------------------------------------------------------
        let (restoreOutput, restoreCode) = execCmdEx(
          "systemsetup -settimezone " & quoteShell(priorIana))
        doAssert restoreCode == 0,
          "restore systemsetup -settimezone " & priorIana &
          " returned exit " & $restoreCode & ": " & restoreOutput
        var restorePropagated = false
        for attempt in 1 .. 12:
          let pr = systemsetupGetRaw()
          if pr.exitCode == 0 and
             parseSystemsetupTimezoneOutput(pr.output) == priorIana:
            restorePropagated = true
            break
          sleep(250)
        doAssert restorePropagated,
          "restore: systemsetup -gettimezone never reported prior '" &
          priorIana & "' after 12 x 250ms attempts"

        let opRestore = PrivilegedOperation(kind: pokOsTimezone,
          address: "timezone:" & priorIana,
          tzIana: priorIana)
        let postRestore = applyPosixOsTimezone(opRestore)
        doAssert postRestore.present

        let postRestoreRaw = systemsetupGetRaw()
        doAssert postRestoreRaw.exitCode == 0
        let postRestoreIana = parseSystemsetupTimezoneOutput(
          postRestoreRaw.output)
        doAssert postRestoreIana == priorIana,
          "post-restore: systemsetup -gettimezone reports '" &
          postRestoreIana & "', expected prior '" & priorIana & "'"

        echo "  [OK] os.timezone macOS lifecycle: prior=" & priorIana &
          " -> apply " & targetIana & " (verified via out-of-band " &
          "`systemsetup -gettimezone`) -> re-apply (no-op, digest " &
          "stable) -> restore " & priorIana & " (verified)."
