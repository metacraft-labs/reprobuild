## M6 / M10 Phase-5 Gate: e2e_macos_phase5_launchd_system_daemon
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the
## `launchd.systemDaemon` driver (system-scope, in
## `libs/repro_elevation/src/repro_elevation/posix_system_driver.nim`)
## has shipped a `when defined(macosx)` arm that has never run on real
## Apple hardware. M6 landed the scaffolding + non-destructive half;
## M10 (`macOS Driver Validation - launchd Services`) lands the
## concrete apply/verify/destroy scenario in the destructive half
## below.
##
## M6 deliverable: the non-destructive half asserts the pure plist
## generator (`buildLaunchDaemonPlist`), the `daemonPlistPath`
## derivation, the `isSafeLaunchdLabel` allowlist, the typed-operation
## wiring through `parseSystemProfile` + `toPrivilegedOperation`, and
## the RBEB codec round-trip.
##
## M10 deliverable: the destructive half drives `applyLaunchdSystemDaemon`
## inside a disposable macOS VM, asserts that
##   1. the plist file appears under `/Library/LaunchDaemons/`,
##   2. `launchctl print system/<label>` succeeds AND mentions the
##      label (proves the daemon is registered with launchd, not just
##      a plist file on disk),
##   3. the destroy direction unregisters the daemon AND removes the
##      plist, with no orphaned plists left in `/Library/LaunchDaemons/`.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half writes
## `/Library/LaunchDaemons/<label>.plist` + invokes
## `launchctl bootstrap system <plist>` (root-only). Guarded by BOTH
## `defined(macosx)` AND `REPRO_PHASE5_MACOS_LAUNCHD_DAEMON_VM=1`. The
## host-side runner cross-builds this binary, copies it into a
## freshly-cloned Tart macOS guest, and runs it under `sudo -E -n`
## with the env var set (the `/Library/LaunchDaemons/` write +
## `launchctl bootstrap system` path is system-scope and needs root).

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
  getEnv("REPRO_PHASE5_MACOS_LAUNCHD_DAEMON_VM") == "1"

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
# macOS platform AND `REPRO_PHASE5_MACOS_LAUNCHD_DAEMON_VM=1`. M10
# lands the concrete scenario.
# ===========================================================================

when defined(macosx):

  proc launchctlPrintSystem(label: string):
      tuple[output: string; exitCode: int] =
    ## Re-implement the `launchctl print system/<label>` probe from
    ## outside the driver so the assertion is independent of the
    ## driver's own observation codepath. We want to PROVE the daemon
    ## is registered with launchd, not just that the plist file
    ## exists on disk.
    let (out0, code) = execCmdEx("launchctl print " &
      quoteShell("system/" & label),
      options = {poStdErrToStdOut})
    (out0, code)

suite "launchd.systemDaemon: REAL bootstrap / verify / destroy (sandbox-only)":

  test "real launchd.systemDaemon lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_LAUNCHD_DAEMON_VM " &
        "not set (or not on macOS) - the real `launchctl bootstrap " &
        "system` scenario is NOT EXERCISED on this host (it needs " &
        "root on a real Mac). Run this gate inside a disposable " &
        "macOS VM with REPRO_PHASE5_MACOS_LAUNCHD_DAEMON_VM=1 to " &
        "exercise the real `launchctl` mutation. The pure-logic " &
        "suites above already proved the plist generator + typed-op " &
        "+ RBEB codec without mutating any host."
    else:
      when defined(macosx):
        discard reproBinary()  # M6 scaffold parity (kept for runner audit).

        # The destructive arm of launchd.systemDaemon writes a plist
        # under /Library/LaunchDaemons/ AND invokes
        # `launchctl bootstrap system` — both system-scope, root-only on
        # macOS. The host-side runner uses `sudo -E -n` to launch this
        # binary; we fail-closed if we're not root.
        let euid = geteuid()
        doAssert euid == 0,
          "PHASE-5 macOS gate must run as root inside the VM " &
          "(euid=" & $euid & "); the host-side runner should `sudo -E` " &
          "the gate binary before invocation. /Library/LaunchDaemons/ " &
          "writes + `launchctl bootstrap system` need root."

        # ---------------------------------------------------------------
        # Test label: pick a DISPOSABLE reverse-DNS label that does NOT
        # collide with any Apple-owned label on the guest. We use a
        # PID-scoped suffix so even if the guest were reused (it isn't
        # — Tart clones a fresh disposable per gate), concurrent runs
        # wouldn't collide.
        # ---------------------------------------------------------------
        let pid = $getCurrentProcessId()
        let testLabel = "com.metacraft.repro-phase5-launchd-daemon-" & pid
        let testProgramArgs = @["/bin/sleep", "3600"]
        let testPlistPath = daemonPlistPath(testLabel)
        doAssert testPlistPath.startsWith("/Library/LaunchDaemons/")
        doAssert isSafeLaunchdLabel(testLabel),
          "test label '" & testLabel & "' unexpectedly rejected by " &
          "the isSafeLaunchdLabel allowlist"

        # Ensure no stale plist from a prior aborted run.
        if fileExists(testPlistPath):
          discard execCmd("launchctl bootout " &
            quoteShell("system/" & testLabel))
          try: removeFile(testPlistPath)
          except OSError: discard

        # Prior state: plist absent + label NOT registered with launchd.
        doAssert not fileExists(testPlistPath),
          "pre-apply: stale plist exists at " & testPlistPath
        let prePrint = launchctlPrintSystem(testLabel)
        doAssert prePrint.exitCode != 0,
          "pre-apply: `launchctl print system/" & testLabel & "` " &
          "unexpectedly succeeded (exit " & $prePrint.exitCode &
          "); test cannot prove round-trip."

        # ---------------------------------------------------------------
        # 1. APPLY: write the plist + `launchctl bootstrap system`.
        # ---------------------------------------------------------------
        let opApply = PrivilegedOperation(kind: pokLaunchdSystemDaemon,
          address: "systemDaemon:" & testLabel,
          sdaLabel: testLabel,
          sdaProgramArgs: testProgramArgs,
          sdaRunAtLoad: true,
          sdaDestroy: false)
        doAssert operationValidationError(opApply).len == 0,
          "apply op rejected by validator: " &
          operationValidationError(opApply)
        let post1 = applyLaunchdSystemDaemon(opApply)
        doAssert post1.present,
          "post-apply: driver reports absent after `launchctl bootstrap`"

        # PASS CRITERION (db84280, launchd.systemDaemon row): the plist
        # file exists AND `launchctl print system/<label>` succeeds.
        # We re-check OUT-OF-BAND (no driver call) to prove the bytes
        # landed on disk AND the daemon is registered with launchd.
        doAssert fileExists(testPlistPath),
          "post-apply: plist missing at " & testPlistPath
        let postPrint = launchctlPrintSystem(testLabel)
        doAssert postPrint.exitCode == 0,
          "post-apply: `launchctl print system/" & testLabel &
          "` failed (exit " & $postPrint.exitCode & "): " &
          postPrint.output.strip()
        doAssert postPrint.output.contains(testLabel),
          "post-apply: `launchctl print` output does not mention the " &
          "label '" & testLabel & "': " & postPrint.output.strip()

        # Independent observe call should report the same digest the
        # apply path returned.
        let obs1 = observeLaunchdSystemDaemon(opApply)
        doAssert obs1.present
        doAssert obs1.digestHex == post1.digestHex,
          "post-apply: independent observe digest disagrees with " &
          "driver-returned digest"

        # ---------------------------------------------------------------
        # 2. RE-APPLY: same plist content. The driver's contract is
        #    that a re-apply with the same desired state is a no-op
        #    (post-apply digest stable; the plist remains correct).
        #    The driver boots out the prior registration first, so
        #    `bootstrap` lands a fresh registration each time.
        # ---------------------------------------------------------------
        let post2 = applyLaunchdSystemDaemon(opApply)
        doAssert post2.present
        doAssert post2.digestHex == post1.digestHex,
          "re-apply: digest changed unexpectedly (was " &
          post1.digestHex[0 ..< 12] & ", now " &
          post2.digestHex[0 ..< 12] & "); re-apply should be a no-op " &
          "from the drift-detection perspective"

        # ---------------------------------------------------------------
        # 3. DESTROY: `launchctl bootout system/<label>` + plist
        #    removal. Post-destroy the plist must be absent AND
        #    `launchctl print` must fail (label unregistered). The
        #    driver's post-apply re-probe raises EProtocol if the
        #    plist file still exists; we then re-check out-of-band.
        # ---------------------------------------------------------------
        let opDestroy = PrivilegedOperation(kind: pokLaunchdSystemDaemon,
          address: "systemDaemon:" & testLabel,
          sdaLabel: testLabel,
          sdaProgramArgs: testProgramArgs,
          sdaRunAtLoad: true,
          sdaDestroy: true)
        let postDestroy = applyLaunchdSystemDaemon(opDestroy)
        doAssert not postDestroy.present,
          "post-destroy: driver reports daemon still present"

        doAssert not fileExists(testPlistPath),
          "post-destroy: plist STILL exists at " & testPlistPath &
          " (out-of-band check after `launchctl bootout` + removeFile)"

        let postDestroyPrint = launchctlPrintSystem(testLabel)
        doAssert postDestroyPrint.exitCode != 0,
          "post-destroy: `launchctl print system/" & testLabel &
          "` STILL succeeds after destroy (exit " &
          $postDestroyPrint.exitCode & "): " &
          postDestroyPrint.output.strip()

        # No orphaned plists: confirm /Library/LaunchDaemons/ contains
        # nothing with our PID-scoped sentinel in the name.
        for kind, path in walkDir("/Library/LaunchDaemons/"):
          if kind == pcFile and path.contains(pid) and
             path.contains("repro-phase5-launchd-daemon"):
            doAssert false,
              "post-destroy: orphaned plist left behind: " & path

        echo "  [OK] launchd.systemDaemon lifecycle: apply / re-apply " &
          "(no-op) / destroy round-trip on disposable label " &
          testLabel & "; out-of-band `launchctl print system/<label>` " &
          "verified registration; destroy unregisters and removes the " &
          "plist with no orphans."
