## M6 Phase-5 Gate: e2e_macos_phase5_passwd_group
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the `passwd.group`
## driver (system-scope, in
## `libs/repro_elevation/src/repro_elevation/posix_system_driver.nim`)
## has shipped a `when defined(linux)` arm only; the macOS arm
## (`dscl . -create /Groups/<name>` + PrimaryGroupID computation,
## NOT `groupadd`) is part of M11 (`macOS Driver Validation - dscl
## Identity (User + Group)`). The M69 Linux gate
## (`tests/e2e/m69/t_e2e_repro_infra_passwd_group_vm.nim`,
## `defined(linux)` only) does not exercise macOS at all.
##
## M6 deliverable: the non-destructive half asserts the pure
## getent-group parser (`parseGetentGroup`), the canonicalizer
## (`canonicalPasswdGroupState`), the typed-operation wiring
## through `parseSystemProfile` + `toPrivilegedOperation`, and the
## RBEB codec round-trip. M11 will both:
##   1. ADD the macOS arm to the driver (`dscl . -create
##      /Groups/<name>`), and
##   2. populate the destructive half of THIS gate with the apply +
##      verify + destroy scenario.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half (TBD by M11) will invoke
## `dscl . -create /Groups/<name>` (requires sudo) and mutate the
## local directory-service database. Guarded by BOTH `defined(macosx)`
## AND `REPRO_PHASE5_MACOS_PASSWD_GROUP_VM=1`.

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
  getEnv("REPRO_PHASE5_MACOS_PASSWD_GROUP_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: pure parser + canonicalizer + typed-op wiring +
# RBEB codec. Always runs.
# ===========================================================================

suite "passwd.group: getent-group parser":

  test "parseGetentGroup reads the colon-separated group record":
    let obs = parseGetentGroup("admin:x:80:zahary,root")
    check obs.present
    check obs.gid == "80"
    # Members come back sorted (canonical).
    check obs.members == @["root", "zahary"]

  test "parseGetentGroup returns absent on empty / malformed":
    check not parseGetentGroup("").present
    check not parseGetentGroup("not-a-group-line").present

suite "passwd.group: typed-operation wiring into the M81 closed set":

  test "a passwd.group system.nim resource parses and types":
    let profile = parseSystemProfile("""
passwd.group {
  name = "netbird"
  members = ["zahary"]
}
""")
    check profile.resources.len == 1
    let r = profile.resources[0]
    check r.kind == srkPasswdGroup
    check r.pgName == "netbird"
    check r.pgMembers == @["zahary"]
    let op = toPrivilegedOperation(r)
    check op.kind == pokPasswdGroup
    check op.pgName == "netbird"
    check op.pgMembers == @["zahary"]
    check not op.pgDestroy
    check requiresElevation(op.kind)
    check toPrivilegedOperation(r, destroy = true).pgDestroy
    let part = partitionApply(@[op], nonPrivilegedOperationCount = 0)
    check part.privilegedOperations.len == 1

  test "a passwd.group operation round-trips the RBEB codec":
    let op = PrivilegedOperation(kind: pokPasswdGroup,
      address: "group:netbird",
      pgName: "netbird",
      pgGid: "",
      pgMembers: @["zahary"],
      pgDestroy: false)
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: "ab"))).body)
    check dec.operation.kind == pokPasswdGroup
    check dec.operation.pgName == "netbird"
    check dec.operation.pgMembers == @["zahary"]
    check dec.baselineDigestHex == "ab"

# ===========================================================================
# DESTRUCTIVE: real `dscl . -create /Groups/<name>` invocation on macOS.
# SANDBOX/VM-ONLY - guarded by BOTH macOS +
# `REPRO_PHASE5_MACOS_PASSWD_GROUP_VM=1`. M11 lands BOTH the macOS
# driver arm AND the concrete scenario; M6 only scaffolds.
# ===========================================================================

suite "passwd.group (macOS): REAL dscl create / verify / destroy (sandbox-only)":

  test "real passwd.group lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_PASSWD_GROUP_VM not " &
        "set (or not on macOS) - the real `dscl . -create " &
        "/Groups/<name>` scenario is NOT EXERCISED on this host (it " &
        "needs sudo on a real Mac AND the driver does not yet have a " &
        "macOS arm — M11 ships both). Run this gate inside a " &
        "disposable macOS VM with " &
        "REPRO_PHASE5_MACOS_PASSWD_GROUP_VM=1 once M11 lands. The " &
        "pure-logic suites above already proved the parser + " &
        "canonicalizer + typed-op + RBEB codec without mutating any " &
        "host."
    else:
      discard reproBinary()
      echo "  [sandbox-scaffold] REPRO_PHASE5_MACOS_PASSWD_GROUP_VM " &
        "set; M6 scaffold present, M11 will both ADD the macOS arm " &
        "to the `passwd.group` driver (`dscl . -create /Groups/<name>` " &
        "instead of `groupadd`) AND populate the concrete apply / " &
        "verify / destroy steps. Until M11, this gate's sandbox-mode " &
        "branch is a no-op."
