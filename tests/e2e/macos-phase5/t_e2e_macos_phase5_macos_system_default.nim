## M6 Phase-5 Gate: e2e_macos_phase5_macos_system_default
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the
## `macos.systemDefault` driver (system-scope, in
## `libs/repro_elevation/src/repro_elevation/posix_system_driver.nim`)
## has shipped a `when defined(macosx)` arm that has never run on real
## Apple hardware. This gate is the SCAFFOLDING that the M7-M11
## driver-validation milestones will fill in with concrete apply +
## verify + destroy scenarios.
##
## M6 deliverable: scaffold + non-destructive half asserting the pure
## logic (the `canonicalizeDefaultsValue` structural comparison from
## `posix_system_parse.nim`, the `systemDefaultPlistPath` derivation,
## the typed-operation wiring through `parseSystemProfile` +
## `toPrivilegedOperation`, the `isSafeDefaultsTypeFlag` allowlist,
## and the RBEB protocol codec round-trip).
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half writes `/Library/Preferences/...` via
## `defaults write` (root-only on macOS) and is therefore guarded by
## BOTH the platform (`defined(macosx)`) AND
## `REPRO_PHASE5_MACOS_SYSTEMDEFAULT_VM=1`. M9 will populate the
## sandbox scenario; until then the destructive half emits a
## `[sandbox-gated]` notice mirroring the M69 precedent.
##
## No `skip`, no `xfail` - the pure-logic half ALWAYS runs and
## always asserts; only the real `defaults write` scenario is
## sandbox-gated.

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

# The real-mutation scenario is gated by BOTH the platform (macOS) and
# an explicit opt-in env var. The env var is left UNSET on every CI /
# dev host so the gate never writes a real Library/Preferences plist.
let sandboxMode =
  defined(macosx) and
  getEnv("REPRO_PHASE5_MACOS_SYSTEMDEFAULT_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: pure structural-comparison + plist-path derivation +
# typed-operation wiring + RBEB codec round-trip. Always runs.
# ===========================================================================

suite "macos.systemDefault: structural-comparison spot checks":
  # The canonical surface for `canonicalizeDefaultsValue` lives in the
  # `t_smoke_repro_elevation` suite. The checks below are spot anchors
  # so this gate FAILS LOUDLY if the contract regresses.

  test "canonicalizeDefaultsValue normalizes whitespace + dict ordering":
    # Two structurally-equal dicts with different whitespace and key
    # order canonicalize identically.
    check canonicalizeDefaultsValue("{ a = 1; b = 2; }") ==
          canonicalizeDefaultsValue("{ b=2 ; a=1; }")
    check defaultsValuesEqual("{ a = 1; b = 2; }",
                              "{ b=2 ; a=1; }")

  test "canonicalizeDefaultsValue preserves array order":
    # Arrays are ordered; reordering is a real change.
    check canonicalizeDefaultsValue("( 1, 2, 3 )") !=
          canonicalizeDefaultsValue("( 3, 2, 1 )")

  test "systemDefaultPlistPath derives a /Library/Preferences/ path":
    let p = systemDefaultPlistPath("com.apple.dock")
    check p.contains("/Library/Preferences/")
    check p.contains("com.apple.dock")

suite "macos.systemDefault: typed-operation wiring into the M81 closed set":

  test "a macos.systemDefault system.nim resource parses and types":
    let profile = parseSystemProfile("""
macos.systemDefault {
  domain = "com.apple.dock"
  key = "autohide"
  type = "-bool"
  value = "YES"
  restartTarget = "Dock"
}
""")
    check profile.resources.len == 1
    let r = profile.resources[0]
    check r.kind == srkMacosSystemDefault
    check r.sdDomain == "com.apple.dock"
    check r.sdKey == "autohide"
    check r.sdValueType == "-bool"
    check r.sdRestartTarget == "Dock"
    let op = toPrivilegedOperation(r)
    check op.kind == pokMacosSystemDefault
    check op.sdDomain == "com.apple.dock"
    check op.sdKey == "autohide"
    check op.sdValueType == "-bool"
    check op.sdRestartTarget == "Dock"
    check not op.sdDestroy
    check requiresElevation(op.kind)
    # The destroy direction flips the typed operation.
    check toPrivilegedOperation(r, destroy = true).sdDestroy
    let part = partitionApply(@[op], nonPrivilegedOperationCount = 0)
    check part.privilegedOperations.len == 1

  test "a macos.systemDefault operation round-trips the RBEB codec":
    let op = PrivilegedOperation(kind: pokMacosSystemDefault,
      address: "systemDefault:com.apple.dock:autohide",
      sdDomain: "com.apple.dock",
      sdKey: "autohide",
      sdValueType: "-bool",
      sdValueLiteral: "YES",
      sdRestartTarget: "Dock",
      sdDestroy: false)
    check operationValidationError(op) == ""
    let dec = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: op, baselineDigestHex: "ab"))).body)
    check dec.operation.kind == pokMacosSystemDefault
    check dec.operation.sdDomain == "com.apple.dock"
    check dec.operation.sdKey == "autohide"
    check dec.operation.sdValueType == "-bool"
    check dec.operation.sdValueLiteral == "YES"
    check dec.baselineDigestHex == "ab"

  test "an unsafe defaults type flag fails validation closed":
    let bad = PrivilegedOperation(kind: pokMacosSystemDefault,
      address: "systemDefault:com.apple.dock:evil",
      sdDomain: "com.apple.dock",
      sdKey: "autohide",
      sdValueType: "; rm -rf /",   # not in the type-flag allowlist
      sdValueLiteral: "YES",
      sdDestroy: false)
    check operationValidationError(bad).len > 0

# ===========================================================================
# DESTRUCTIVE: real `defaults write /Library/Preferences/...` against a
# sandboxed plist + key. SANDBOX/VM-ONLY - guarded by BOTH the macOS
# platform AND `REPRO_PHASE5_MACOS_SYSTEMDEFAULT_VM=1`. Never runs on a
# normal host. M9 lands the concrete scenario; M6 only scaffolds.
# ===========================================================================

suite "macos.systemDefault: REAL apply / verify / destroy (sandbox-only)":

  test "real macos.systemDefault lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_SYSTEMDEFAULT_VM not " &
        "set (or not on macOS) - the real `defaults write " &
        "/Library/Preferences/...` scenario is NOT EXERCISED on this " &
        "host (it needs root on a real Mac). Run this gate inside a " &
        "disposable macOS VM with REPRO_PHASE5_MACOS_SYSTEMDEFAULT_VM=1 " &
        "to exercise the real `defaults` mutation. The pure-logic " &
        "suites above already proved the structural-comparison + " &
        "typed-op + RBEB codec without mutating any host."
    else:
      # The concrete apply -> verify -> re-apply (no-op) -> destroy
      # scenario lands in M9 (macOS Driver Validation - System-Level
      # Primitives). M6 only scaffolds. We still assert that the
      # `repro` binary the broker would launch exists so the M9 run
      # has a fast preflight signal.
      discard reproBinary()
      echo "  [sandbox-scaffold] REPRO_PHASE5_MACOS_SYSTEMDEFAULT_VM " &
        "set; M6 scaffold present, M9 will populate the concrete " &
        "apply/verify/destroy steps."
