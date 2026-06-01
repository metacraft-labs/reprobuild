## M6 Phase-5 Gate: e2e_macos_phase5_os_hostname
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the `osHostname`
## POSIX arm (in
## `libs/repro_elevation/src/repro_elevation/posix_system_driver.nim`,
## `applyPosixOsHostname`) has had only a Linux WSL gate
## (`tests/e2e/m69/t_e2e_repro_infra_os_hostname_posix_vm.nim`,
## `defined(linux)` only). On macOS the apply must write the three
## hostname slots via `scutil --set ComputerName/HostName/
## LocalHostName`; the verification reads all three back via
## `scutil --get`. This gate is the M6 macOS scaffolding; M9
## populates the concrete apply + triple-slot verification + destroy
## scenario.
##
## M6 deliverable: the non-destructive half asserts the pure
## hostname parser (`parseHostnameOutput`), the canonicalizers
## (`canonicalHostnameState`), the RFC 1123 allowlist
## (`isSafeHostname`), the typed-operation wiring, and the RBEB
## codec round-trip.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half invokes `scutil --set` (requires sudo) and
## mutates all three macOS hostname slots. Guarded by BOTH
## `defined(macosx)` AND `REPRO_PHASE5_MACOS_OS_HOSTNAME_VM=1`. M9
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
  getEnv("REPRO_PHASE5_MACOS_OS_HOSTNAME_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: pure parser + canonicalizer + RFC 1123 allowlist +
# typed-op wiring + RBEB codec. Always runs.
# ===========================================================================

suite "os.hostname: hostname parser + canonicalizer":

  test "parseHostnameOutput strips trailing whitespace":
    check parseHostnameOutput("test-host\n") == "test-host"
    check parseHostnameOutput("test-host") == "test-host"

  test "canonicalHostnameState normalizes case":
    # macOS scutil round-trips uppercase to lowercase; the canonical
    # form is lowercase so a TestHost vs testhost compare equal.
    check canonicalHostnameState("TestHost") ==
          canonicalHostnameState("testhost")

suite "os.hostname: RFC 1123 allowlist":

  test "isSafeHostname accepts RFC 1123":
    check isSafeHostname("test-host")
    check isSafeHostname("repro-m6-1")
    check not isSafeHostname("")
    check not isSafeHostname("-leading-dash")
    check not isSafeHostname("trailing-dash-")
    check not isSafeHostname("has spaces")
    check not isSafeHostname("has;semicolon")

suite "os.hostname: typed-operation wiring into the M81 closed set":

  test "an os.hostname system.nim resource parses and types":
    let profile = parseSystemProfile("""
os.hostname {
  hostname = "repro-m6-test"
}
""")
    check profile.resources.len == 1
    let r = profile.resources[0]
    check r.kind == srkOsHostname
    check r.hostnameName == "repro-m6-test"
    let op = toPrivilegedOperation(r)
    check op.kind == pokOsHostname
    check op.hostnameName == "repro-m6-test"
    check requiresElevation(op.kind)
    let part = partitionApply(@[op], nonPrivilegedOperationCount = 0)
    check part.privilegedOperations.len == 1

  test "an os.hostname operation round-trips the RBEB codec":
    let op = PrivilegedOperation(kind: pokOsHostname,
      address: "hostname:repro-m6-test",
      hostnameName: "repro-m6-test")
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: "ab"))).body)
    check dec.operation.kind == pokOsHostname
    check dec.operation.hostnameName == "repro-m6-test"
    check dec.baselineDigestHex == "ab"

  test "an unsafe hostname fails validation closed":
    let bad = PrivilegedOperation(kind: pokOsHostname,
      address: "hostname:evil",
      hostnameName: "evil host;rm -rf /")
    check operationValidationError(bad).len > 0

# ===========================================================================
# DESTRUCTIVE: real `scutil --set ComputerName/HostName/LocalHostName`.
# SANDBOX/VM-ONLY - guarded by BOTH macOS +
# `REPRO_PHASE5_MACOS_OS_HOSTNAME_VM=1`. M9 lands the concrete
# scenario; M6 only scaffolds.
# ===========================================================================

suite "os.hostname (macOS): REAL apply / verify / destroy (sandbox-only)":

  test "real os.hostname lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_OS_HOSTNAME_VM not " &
        "set (or not on macOS) - the real `scutil --set` triple-slot " &
        "scenario is NOT EXERCISED on this host (it needs sudo on a " &
        "real Mac and mutates the system identity). Run this gate " &
        "inside a disposable macOS VM with " &
        "REPRO_PHASE5_MACOS_OS_HOSTNAME_VM=1 to exercise the real " &
        "`scutil` mutation. The pure-logic suites above already " &
        "proved the parser + canonicalizer + RFC 1123 allowlist + " &
        "typed-op + RBEB codec without mutating any host."
    else:
      discard reproBinary()
      echo "  [sandbox-scaffold] REPRO_PHASE5_MACOS_OS_HOSTNAME_VM " &
        "set; M6 scaffold present, M9 will populate the concrete " &
        "`scutil --set ComputerName/HostName/LocalHostName` apply + " &
        "`scutil --get` triple-slot verify steps."
