## M6 Phase-5 Gate: e2e_macos_phase5_launchd_system_daemon
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the
## `launchd.systemDaemon` driver (system-scope, in
## `libs/repro_elevation/src/repro_elevation/posix_system_driver.nim`)
## has shipped a `when defined(macosx)` arm that has never run on real
## Apple hardware. This gate is the M6 scaffolding; M10
## (`macOS Driver Validation - launchd Services`) populates the
## concrete apply/verify/destroy scenario.
##
## M6 deliverable: the non-destructive half asserts the pure plist
## generator (`buildLaunchDaemonPlist`), the `daemonPlistPath`
## derivation, the `isSafeLaunchdLabel` allowlist, the typed-operation
## wiring through `parseSystemProfile` + `toPrivilegedOperation`, and
## the RBEB codec round-trip.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half writes
## `/Library/LaunchDaemons/<label>.plist` + invokes
## `launchctl bootstrap system <plist>` (root-only). Guarded by BOTH
## `defined(macosx)` AND `REPRO_PHASE5_MACOS_LAUNCHD_VM=1`. M10
## populates the concrete sandbox scenario; until then the destructive
## half emits a `[sandbox-gated]` notice.

import std/[os, strutils, unittest]

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
  getEnv("REPRO_PHASE5_MACOS_LAUNCHD_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: plist generator + path derivation + label safety +
# typed-operation wiring + RBEB codec. Always runs.
# ===========================================================================

suite "launchd.systemDaemon: plist generator + path derivation":

  test "buildLaunchDaemonPlist emits the Label + ProgramArguments":
    let plist = buildLaunchDaemonPlist("com.repro.m6.gate",
      @["/bin/sleep", "3600"], true)
    check plist.contains("<key>Label</key>")
    check plist.contains("com.repro.m6.gate")
    check plist.contains("<key>ProgramArguments</key>")
    check plist.contains("/bin/sleep")
    check plist.contains("3600")
    check plist.contains("<key>RunAtLoad</key>")

  test "daemonPlistPath lands under /Library/LaunchDaemons/":
    let p = daemonPlistPath("com.repro.m6.gate")
    check p.contains("/Library/LaunchDaemons/")
    check p.contains("com.repro.m6.gate")

  test "isSafeLaunchdLabel rejects shell metacharacters":
    check isSafeLaunchdLabel("com.repro.m6.gate")
    check not isSafeLaunchdLabel("")
    check not isSafeLaunchdLabel("../evil")
    check not isSafeLaunchdLabel("com.repro;rm -rf /")

suite "launchd.systemDaemon: typed-operation wiring into the M81 closed set":

  test "a launchd.systemDaemon system.nim resource parses and types":
    let profile = parseSystemProfile("""
launchd.systemDaemon {
  label = "com.repro.m6.gate"
  programArgs = ["/bin/sleep", "3600"]
  runAtLoad = true
}
""")
    check profile.resources.len == 1
    let r = profile.resources[0]
    check r.kind == srkLaunchdSystemDaemon
    check r.sdaLabel == "com.repro.m6.gate"
    check r.sdaProgramArgs == @["/bin/sleep", "3600"]
    check r.sdaRunAtLoad
    let op = toPrivilegedOperation(r)
    check op.kind == pokLaunchdSystemDaemon
    check op.sdaLabel == "com.repro.m6.gate"
    check op.sdaProgramArgs == @["/bin/sleep", "3600"]
    check op.sdaRunAtLoad
    check not op.sdaDestroy
    check requiresElevation(op.kind)
    check toPrivilegedOperation(r, destroy = true).sdaDestroy
    let part = partitionApply(@[op], nonPrivilegedOperationCount = 0)
    check part.privilegedOperations.len == 1

  test "a launchd.systemDaemon operation round-trips the RBEB codec":
    let op = PrivilegedOperation(kind: pokLaunchdSystemDaemon,
      address: "systemDaemon:com.repro.m6.gate",
      sdaLabel: "com.repro.m6.gate",
      sdaProgramArgs: @["/bin/sleep", "3600"],
      sdaRunAtLoad: true,
      sdaDestroy: false)
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: "ab"))).body)
    check dec.operation.kind == pokLaunchdSystemDaemon
    check dec.operation.sdaLabel == "com.repro.m6.gate"
    check dec.operation.sdaProgramArgs == @["/bin/sleep", "3600"]
    check dec.operation.sdaRunAtLoad
    check dec.baselineDigestHex == "ab"

  test "an unsafe launchd label fails validation closed":
    let bad = PrivilegedOperation(kind: pokLaunchdSystemDaemon,
      address: "systemDaemon:../evil",
      sdaLabel: "../evil",
      sdaProgramArgs: @["/bin/true"],
      sdaRunAtLoad: false,
      sdaDestroy: false)
    check operationValidationError(bad).len > 0

# ===========================================================================
# DESTRUCTIVE: real `/Library/LaunchDaemons/...` write +
# `launchctl bootstrap system`. SANDBOX/VM-ONLY - guarded by BOTH the
# macOS platform AND `REPRO_PHASE5_MACOS_LAUNCHD_VM=1`. M10 lands the
# concrete scenario; M6 only scaffolds.
# ===========================================================================

suite "launchd.systemDaemon: REAL bootstrap / verify / destroy (sandbox-only)":

  test "real launchd.systemDaemon lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_LAUNCHD_VM not set " &
        "(or not on macOS) - the real `launchctl bootstrap system` " &
        "scenario is NOT EXERCISED on this host (it needs root on a " &
        "real Mac). Run this gate inside a disposable macOS VM with " &
        "REPRO_PHASE5_MACOS_LAUNCHD_VM=1 to exercise the real " &
        "`launchctl` mutation. The pure-logic suites above already " &
        "proved the plist generator + typed-op + RBEB codec without " &
        "mutating any host."
    else:
      discard reproBinary()
      echo "  [sandbox-scaffold] REPRO_PHASE5_MACOS_LAUNCHD_VM set; " &
        "M6 scaffold present, M10 will populate the concrete " &
        "bootstrap/verify/destroy steps."
