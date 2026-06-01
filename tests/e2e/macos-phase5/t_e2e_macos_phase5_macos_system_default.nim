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
## `REPRO_PHASE5_MACOS_DEFAULTS_VM=1`. The host-side runner cross-builds
## this binary, copies it into a freshly-cloned Tart macOS guest, and
## runs it under `sudo -E -n` with the env var set (the `defaults
## write /Library/Preferences/...` path is system-scope and needs
## root). M9 lands the concrete apply / verify / re-apply (no-op) /
## destroy lifecycle.
##
## No `skip`, no `xfail` - the pure-logic half ALWAYS runs and
## always asserts; only the real `defaults write` scenario is
## sandbox-gated.

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

# The real-mutation scenario is gated by BOTH the platform (macOS) and
# an explicit opt-in env var. The env var is left UNSET on every CI /
# dev host so the gate never writes a real Library/Preferences plist.
let sandboxMode =
  defined(macosx) and
  getEnv("REPRO_PHASE5_MACOS_DEFAULTS_VM") == "1"

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
# platform AND `REPRO_PHASE5_MACOS_DEFAULTS_VM=1`. Never runs on a
# normal host. The host-side runner (`run_phase5_in_tart.nim`) wraps
# this binary in `sudo -E -n` inside the guest so the system-scope
# `defaults write /Library/Preferences/...` path can run as root.
# ===========================================================================

when defined(macosx):

  proc defaultsReadRaw(plistPath, key: string):
      tuple[present: bool; value: string; exitCode: int] =
    ## Re-implement the driver's `readSystemDefault` shape from outside
    ## the driver so the assertion is independent of the driver's own
    ## codepath (we want to PROVE the write landed on disk, not just
    ## trust the driver's post-apply re-probe).
    let (output, code) = execCmdEx("defaults read " & quoteShell(plistPath) &
      " " & quoteShell(key))
    if code != 0:
      return (false, "", code)
    (true, output.strip(), code)

suite "macos.systemDefault: REAL apply / verify / destroy (sandbox-only)":

  test "real macos.systemDefault lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_DEFAULTS_VM not " &
        "set (or not on macOS) - the real `defaults write " &
        "/Library/Preferences/...` scenario is NOT EXERCISED on this " &
        "host (it needs root on a real Mac). Run this gate inside a " &
        "disposable macOS VM with REPRO_PHASE5_MACOS_DEFAULTS_VM=1 " &
        "to exercise the real `defaults` mutation. The pure-logic " &
        "suites above already proved the structural-comparison + " &
        "typed-op + RBEB codec without mutating any host."
    else:
      when defined(macosx):
        # The destructive arm of macos.systemDefault writes a plist
        # under /Library/Preferences/ — system-scope, root-only on
        # macOS. The host-side runner uses `sudo -E -n` to launch this
        # binary; we fail-closed if we're not root.
        let euid = geteuid()
        doAssert euid == 0,
          "PHASE-5 macOS gate must run as root inside the VM " &
          "(euid=" & $euid & "); the host-side runner should `sudo -E` " &
          "the gate binary before invocation. /Library/Preferences/ " &
          "writes need root."

        # ---------------------------------------------------------------
        # Test domain: pick a DISPOSABLE reverse-DNS domain that does NOT
        # collide with any Apple-owned domain on the guest. The driver
        # validator (`isSystemDefaultDomain`) requires the resolved path
        # land under `/Library/Preferences/`. We use a PID-scoped name
        # so even if the guest were reused (it isn't — Tart clones a
        # fresh disposable per gate), concurrent runs wouldn't collide.
        # ---------------------------------------------------------------
        let pid = $getCurrentProcessId()
        let testDomain = "com.metacraft.repro-phase5-defaults-" & pid
        # Use a string-typed key+value because the driver's post-apply
        # re-probe canonicalizes the OPERATOR-supplied literal and
        # compares it to the `defaults read` output. Bool-typed values
        # don't round-trip byte-equivalently (input `YES` is read back
        # as `1`); the structural canonicalizer treats them as distinct
        # tokens and the driver's `desiredHex != post.digestHex` check
        # would (correctly, per its contract) raise EProtocol. A string
        # value round-trips verbatim.
        let testKey = "repro-phase5-marker"
        let testValueLiteral = "phase5-" & pid
        let testValueType = "-string"
        let testPlistPath = systemDefaultPlistPath(testDomain)
        doAssert testPlistPath.startsWith("/Library/Preferences/")
        doAssert isSystemDefaultDomain(testDomain),
          "test domain '" & testDomain & "' unexpectedly rejected by " &
          "the isSystemDefaultDomain allowlist"

        # Ensure no stale plist from a prior aborted run.
        if fileExists(testPlistPath):
          # Best-effort cleanup; the driver itself does not depend on
          # this but we want a known-empty baseline for the round-trip.
          try: removeFile(testPlistPath)
          except OSError: discard

        # Prior state: domain absent (no plist; key has no value).
        let preState = defaultsReadRaw(testPlistPath, testKey)
        doAssert not preState.present,
          "pre-apply: key '" & testKey & "' unexpectedly already " &
          "present in domain '" & testDomain & "' (value='" &
          preState.value & "'). Test cannot prove round-trip."

        # ---------------------------------------------------------------
        # 1. APPLY: write `<testKey> -string <testValueLiteral>` into
        #    the test plist. No `restartTarget` — that field exists for
        #    Apple-owned domains like com.apple.dock where the running
        #    process must be restarted to pick up the change. Our test
        #    domain has no consumer process, so leaving sdRestartTarget
        #    empty deliberately exercises the no-`killall` codepath.
        # ---------------------------------------------------------------
        let opApply = PrivilegedOperation(kind: pokMacosSystemDefault,
          address: "systemDefault:" & testDomain & ":" & testKey,
          sdDomain: testDomain,
          sdKey: testKey,
          sdValueType: testValueType,
          sdValueLiteral: testValueLiteral,
          sdRestartTarget: "",
          sdDestroy: false)
        doAssert operationValidationError(opApply).len == 0,
          "apply op rejected by validator: " &
          operationValidationError(opApply)
        let post1 = applyMacosSystemDefault(opApply)
        doAssert post1.present,
          "post-apply: driver reports absent after `defaults write`"

        # PASS CRITERION (db84280, macos.systemDefault row): the value
        # is readable post-apply via `defaults read`. We re-read OUT-
        # OF-BAND (no driver call) to prove the bytes landed on disk.
        let postRead = defaultsReadRaw(testPlistPath, testKey)
        doAssert postRead.present,
          "post-apply: `defaults read` reports absent (exit=" &
          $postRead.exitCode & ")"
        # `defaults read` of a -bool YES prints `1`. We compare the
        # canonicalized form so trailing whitespace / formatting can't
        # cause a false negative.
        doAssert canonicalizeDefaultsValue(postRead.value) ==
                 canonicalizeDefaultsValue(testValueLiteral),
          "post-apply: `defaults read` returned '" & postRead.value &
          "', expected '" & testValueLiteral & "'"

        # Independent observe call should report the same digest the
        # apply path returned.
        let obs1 = observeMacosSystemDefault(opApply)
        doAssert obs1.present
        doAssert obs1.digestHex == post1.digestHex,
          "post-apply: independent observe digest disagrees with " &
          "driver-returned digest"

        # ---------------------------------------------------------------
        # 2. RE-APPLY: same value. The driver's contract is that a re-
        #    apply with the same desired value is a no-op (post-apply
        #    digest stable; the value remains correct). cfprefsd may
        #    re-serialize the plist with structurally-equivalent but
        #    byte-different output — the canonicalizer absorbs that.
        # ---------------------------------------------------------------
        let post2 = applyMacosSystemDefault(opApply)
        doAssert post2.present
        doAssert post2.digestHex == post1.digestHex,
          "re-apply: digest changed unexpectedly (was " &
          post1.digestHex[0 ..< 12] & ", now " &
          post2.digestHex[0 ..< 12] & "); re-apply should be a no-op " &
          "from the drift-detection perspective"

        # ---------------------------------------------------------------
        # 3. DESTROY: `defaults delete <plist> <key>`. Post-destroy the
        #    key must be absent — and we return to the prior state
        #    (since the prior state was also "absent", this is a clean
        #    round-trip). The driver's post-apply re-probe raises
        #    EProtocol if the destroy didn't take effect; we then re-
        #    read out-of-band to confirm.
        # ---------------------------------------------------------------
        let opDestroy = PrivilegedOperation(kind: pokMacosSystemDefault,
          address: "systemDefault:" & testDomain & ":" & testKey,
          sdDomain: testDomain,
          sdKey: testKey,
          sdValueType: testValueType,
          sdValueLiteral: "",
          sdRestartTarget: "",
          sdDestroy: true)
        let postDestroy = applyMacosSystemDefault(opDestroy)
        doAssert not postDestroy.present,
          "post-destroy: driver reports value still present"

        let postDestroyRead = defaultsReadRaw(testPlistPath, testKey)
        doAssert not postDestroyRead.present,
          "post-destroy: `defaults read` STILL returns the value " &
          "after `defaults delete` (out-of-band confirm): '" &
          postDestroyRead.value & "'"

        # Final state matches prior state (both "absent").
        doAssert postDestroyRead.present == preState.present,
          "post-destroy: did not return to prior state"

        # ---------------------------------------------------------------
        # Safety net: remove the test plist file itself if it lingers
        # empty after the key delete. `defaults delete` of the last
        # key in a domain leaves an empty plist on disk; clean it.
        # ---------------------------------------------------------------
        if fileExists(testPlistPath):
          try: removeFile(testPlistPath)
          except OSError: discard

        echo "  [OK] macos.systemDefault lifecycle: apply / re-apply " &
          "(no-op) / destroy round-trip on disposable plist " &
          testPlistPath & "; out-of-band `defaults read` verified " &
          "the bytes landed; destroy returned to prior 'absent' state."
