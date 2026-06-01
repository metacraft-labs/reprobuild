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
## `defined(macosx)` AND `REPRO_PHASE5_MACOS_OS_TIMEZONE_VM=1`. M9
## lands the concrete sandbox scenario.

import std/[os, unittest]

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
  getEnv("REPRO_PHASE5_MACOS_OS_TIMEZONE_VM") == "1"

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
# ONLY - guarded by BOTH macOS + `REPRO_PHASE5_MACOS_OS_TIMEZONE_VM=1`.
# M9 lands the concrete scenario; M6 only scaffolds.
# ===========================================================================

suite "os.timezone (macOS): REAL apply / verify / destroy (sandbox-only)":

  test "real os.timezone lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_OS_TIMEZONE_VM not " &
        "set (or not on macOS) - the real `systemsetup -settimezone " &
        "<iana>` scenario is NOT EXERCISED on this host (it needs " &
        "sudo on a real Mac and mutates the system clock). Run this " &
        "gate inside a disposable macOS VM with " &
        "REPRO_PHASE5_MACOS_OS_TIMEZONE_VM=1 to exercise the real " &
        "`systemsetup` mutation. The pure-logic suites above already " &
        "proved the parser + canonicalizer + IANA allowlist + typed-" &
        "op + RBEB codec without mutating any host."
    else:
      discard reproBinary()
      echo "  [sandbox-scaffold] REPRO_PHASE5_MACOS_OS_TIMEZONE_VM " &
        "set; M6 scaffold present, M9 will populate the concrete " &
        "`systemsetup -settimezone Europe/Sofia` apply + " &
        "`systemsetup -gettimezone` verify steps."
