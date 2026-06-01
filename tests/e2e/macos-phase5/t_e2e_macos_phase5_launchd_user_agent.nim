## M6 / M10 Phase-5 Gate: e2e_macos_phase5_launchd_user_agent
##
## Per the macOS Mac-host validation checklist in
## `metacraft/reprobuild-specs/Nix-Flake-Migration-Roadmap.md` ("Drivers
## with shipped macOS arms - never E2E-validated"), the
## `launchd.userAgent` driver (home-scope, in
## `libs/repro_home_resources/src/repro_home_resources/drivers/launchd_user.nim`)
## has shipped a `when defined(macosx)` arm that has never run on real
## Apple hardware. M6 landed the scaffolding + non-destructive half;
## M10 (`macOS Driver Validation - launchd Services`) lands the
## concrete apply/verify/destroy scenario in the destructive half
## below.
##
## M6 deliverable: the non-destructive half asserts the pure plist
## generator (`buildLaunchAgentPlist`), the `agentPlistPath`
## derivation, the `escapeXml` helper, the resource-typed digest
## (`digestOfResource(rkLaunchdUserAgent)`), and the resource
## validation (`resourceValidationError`).
##
## M10 deliverable: the destructive half drives `applyLaunchAgent`
## inside a disposable macOS VM, asserts that
##   1. the plist file appears under `~/Library/LaunchAgents/`,
##   2. `launchctl print gui/<uid>/<label>` succeeds AND mentions the
##      label (proves the agent is registered with launchd, not just
##      a plist file on disk),
##   3. the destroy direction (`destroyLaunchAgent`) unregisters the
##      agent AND removes the plist, with no orphaned plists left in
##      `~/Library/LaunchAgents/`.
##
## ===========================================================================
## DESTRUCTIVE GATE - REQUIRES A macOS SANDBOX / VM. DO NOT RUN ON A
## REAL HOST.
## ===========================================================================
##
## The destructive half writes
## `~/Library/LaunchAgents/<label>.plist` + invokes
## `launchctl bootstrap gui/<uid> <plist>`. Even though this is
## home-scope and does not need root, the apply mutates the user's
## live LaunchAgents tree and registers a real launchd service —
## therefore it is guarded by BOTH `defined(macosx)` AND
## `REPRO_PHASE5_MACOS_LAUNCHD_AGENT_VM=1`. The host-side runner
## cross-builds this binary, copies it into a freshly-cloned Tart
## macOS guest, and runs it as the cirruslabs admin user (NOT under
## sudo — agents live in the user's gui/<uid> domain).

import std/[os, osproc, strutils, unittest]

import repro_home_resources

# The real-mutation scenario is gated by BOTH the platform (macOS) and
# the explicit opt-in env var. The env var is left UNSET on every CI /
# dev host so the gate never writes a real `~/Library/LaunchAgents/`
# plist or invokes `launchctl bootstrap`.
let sandboxMode =
  defined(macosx) and
  getEnv("REPRO_PHASE5_MACOS_LAUNCHD_AGENT_VM") == "1"

# ===========================================================================
# NON-DESTRUCTIVE: plist generator + path derivation + validation +
# digest assertion. Always runs.
# ===========================================================================

suite "launchd.userAgent: plist generator + path derivation":

  test "buildLaunchAgentPlist emits Label + ProgramArguments + RunAtLoad":
    let plist = buildLaunchAgentPlist("com.metacraft.repro.m6",
      @["/bin/sleep", "3600"], true, false)
    check plist.contains("<key>Label</key>")
    check plist.contains("com.metacraft.repro.m6")
    check plist.contains("<key>ProgramArguments</key>")
    check plist.contains("/bin/sleep")
    check plist.contains("3600")
    check plist.contains("<key>RunAtLoad</key>")
    check plist.contains("<true/>")
    check plist.contains("<key>KeepAlive</key>")

  test "buildLaunchAgentPlist KeepAlive flag flips":
    let off = buildLaunchAgentPlist("com.x", @["/bin/true"], true, false)
    let on  = buildLaunchAgentPlist("com.x", @["/bin/true"], true, true)
    check off != on

  test "agentPlistPath lands under ~/Library/LaunchAgents/":
    let p = agentPlistPath("/Users/zahary", "com.metacraft.repro.m6")
    check p.contains("/Library/LaunchAgents/")
    check p.contains("com.metacraft.repro.m6")

  test "escapeXml escapes the five predefined entities":
    check escapeXml("<a&b>") == "&lt;a&amp;b&gt;"
    check escapeXml("\"hi\"") == "&quot;hi&quot;"
    check escapeXml("'q'") == "&apos;q&apos;"

suite "launchd.userAgent: typed-resource wiring + digest + validation":

  test "a launchd.userAgent Resource accepts the canonical fields":
    let r = Resource(kind: rkLaunchdUserAgent,
      address: "agent:com.metacraft.repro.m6",
      lifecyclePolicy: lpDefault,
      launchdLabel: "com.metacraft.repro.m6",
      launchdProgramArgs: @["/bin/sleep", "3600"],
      launchdRunAtLoad: true,
      launchdKeepAlive: false)
    check resourceValidationError(r) == ""
    check realWorldIdentity(r) == "launchd:user:com.metacraft.repro.m6"

  test "resourceValidationError rejects an injected launchd label":
    let bad = Resource(kind: rkLaunchdUserAgent,
      address: "agent:evil",
      lifecyclePolicy: lpDefault,
      launchdLabel: "com.x;touch /tmp/pwn",   # not in launchd charset
      launchdPlistContent: "<plist/>")
    check resourceValidationError(bad).len > 0
    # An empty label is also rejected.
    let empty = Resource(kind: rkLaunchdUserAgent,
      address: "agent:empty",
      lifecyclePolicy: lpDefault,
      launchdLabel: "",
      launchdPlistContent: "<plist/>")
    check resourceValidationError(empty).len > 0

  test "digestOfResource changes when ProgramArguments change":
    var r = Resource(kind: rkLaunchdUserAgent,
      address: "agent:digest",
      lifecyclePolicy: lpDefault,
      launchdLabel: "com.metacraft.repro.m6",
      launchdProgramArgs: @["/bin/true"],
      launchdRunAtLoad: true,
      launchdKeepAlive: false)
    let d0 = digestOfResource(r)
    r.launchdProgramArgs = @["/bin/true", "--new-flag"]
    let d1 = digestOfResource(r)
    check d0 != d1

  test "digestOfResource changes when keepAlive flips":
    var r = Resource(kind: rkLaunchdUserAgent,
      address: "agent:keep",
      lifecyclePolicy: lpDefault,
      launchdLabel: "com.metacraft.repro.m6",
      launchdProgramArgs: @["/bin/true"],
      launchdRunAtLoad: true,
      launchdKeepAlive: false)
    let d0 = digestOfResource(r)
    r.launchdKeepAlive = true
    let d1 = digestOfResource(r)
    check d0 != d1

  test "resourceKindFromString recognizes launchd.userAgent":
    check resourceKindFromString("launchd.userAgent") == rkLaunchdUserAgent

# ===========================================================================
# DESTRUCTIVE: real `~/Library/LaunchAgents/<label>.plist` write +
# `launchctl bootstrap gui/<uid>`. SANDBOX/VM-ONLY - guarded by BOTH
# the macOS platform AND `REPRO_PHASE5_MACOS_LAUNCHD_AGENT_VM=1`. M10
# lands the concrete scenario.
# ===========================================================================

when defined(macosx):

  proc currentUidString(): string =
    ## The numeric uid of the running user, for `launchctl print
    ## gui/<uid>/<label>` re-probes.
    let (out0, code) = execCmdEx("id -u")
    if code == 0:
      return out0.strip()
    "501"  # conservative fallback for the default first user

  proc launchctlPrintGui(uid, label: string):
      tuple[output: string; exitCode: int] =
    ## Re-implement the `launchctl print gui/<uid>/<label>` probe from
    ## outside the driver so the assertion is independent of the
    ## driver's own observation codepath. We want to PROVE the agent
    ## is registered with launchd, not just that the plist file
    ## exists on disk.
    let (out0, code) = execCmdEx("launchctl print " &
      quoteShell("gui/" & uid & "/" & label),
      options = {poStdErrToStdOut})
    (out0, code)

suite "launchd.userAgent: REAL bootstrap / verify / destroy (sandbox-only)":

  test "real launchd.userAgent lifecycle (only under macOS + env var)":
    if not sandboxMode:
      echo "  [sandbox-gated] REPRO_PHASE5_MACOS_LAUNCHD_AGENT_VM " &
        "not set (or not on macOS) - the real " &
        "`~/Library/LaunchAgents/...` plist write + " &
        "`launchctl bootstrap gui/<uid>` scenario is NOT EXERCISED " &
        "on this host. Run this gate inside a disposable macOS VM " &
        "with REPRO_PHASE5_MACOS_LAUNCHD_AGENT_VM=1 to exercise the " &
        "real `launchctl` mutation. The pure-logic suites above " &
        "already proved the plist generator + typed-field digest + " &
        "validation without mutating any host."
    else:
      when defined(macosx):
        # ---------------------------------------------------------------
        # Test label: pick a DISPOSABLE reverse-DNS label that does NOT
        # collide with any user-installed agent on the guest. We use a
        # PID-scoped suffix so even if the guest were reused (it isn't
        # — Tart clones a fresh disposable per gate), concurrent runs
        # wouldn't collide.
        # ---------------------------------------------------------------
        let pid = $getCurrentProcessId()
        let home = getEnv("HOME")
        doAssert home.startsWith("/Users/"),
          "macOS $HOME '" & home & "' is not Apple-flavored (/Users/...)"
        let uid = currentUidString()
        doAssert uid.len > 0 and uid != "0",
          "launchd.userAgent gate must NOT run as root (uid=" & uid &
          "); agents live in the gui/<uid> domain of an interactive " &
          "user, not in system/<label>. The host-side runner must " &
          "invoke this binary WITHOUT `sudo`."

        let testLabel = "com.metacraft.repro-phase5-launchd-agent-" & pid
        let testProgramArgs = @["/bin/sleep", "3600"]
        let testRunAtLoad = true
        let testKeepAlive = false
        let testPlistPath = agentPlistPath(home, testLabel)
        doAssert testPlistPath.contains("/Library/LaunchAgents/")
        doAssert testPlistPath.contains(testLabel)

        # Ensure no stale plist or registration from a prior aborted
        # run.
        if fileExists(testPlistPath):
          discard execCmd("launchctl bootout " &
            quoteShell("gui/" & uid & "/" & testLabel))
          try: removeFile(testPlistPath)
          except OSError: discard

        # Prior state: plist absent + label NOT registered with launchd.
        doAssert not fileExists(testPlistPath),
          "pre-apply: stale plist exists at " & testPlistPath
        let prePrint = launchctlPrintGui(uid, testLabel)
        doAssert prePrint.exitCode != 0,
          "pre-apply: `launchctl print gui/" & uid & "/" & testLabel &
          "` unexpectedly succeeded (exit " & $prePrint.exitCode &
          "); test cannot prove round-trip."

        # Snapshot the prior observe state — both the bytes of any
        # existing plist (there shouldn't be one) and the typed
        # ObservedState.
        let preObserve = observeLaunchAgent(home, testLabel)
        doAssert not preObserve.present,
          "pre-apply: observeLaunchAgent reports present before " &
          "applyLaunchAgent was called."

        # ---------------------------------------------------------------
        # 1. APPLY: render plist via `launchAgentPlistFor` + call
        #    `applyLaunchAgent` which writes the plist AND invokes
        #    `launchctl bootstrap gui/<uid> <plist>`.
        # ---------------------------------------------------------------
        let plistContent = launchAgentPlistFor(testLabel,
          testProgramArgs, testRunAtLoad, testKeepAlive)
        doAssert plistContent.contains("<key>Label</key>")
        doAssert plistContent.contains(testLabel)
        let payload1 = applyLaunchAgent(home, testLabel, plistContent,
          testRunAtLoad, testKeepAlive)
        doAssert payload1.len == plistContent.len,
          "applyLaunchAgent returned payload of size " & $payload1.len &
          ", expected " & $plistContent.len & " (plist content size)"

        # PASS CRITERION (db84280, launchd.userAgent row): the plist
        # file exists AND `launchctl print gui/<uid>/<label>` succeeds.
        # We re-check OUT-OF-BAND (no driver call) to prove the bytes
        # landed on disk AND the agent is registered with launchd.
        doAssert fileExists(testPlistPath),
          "post-apply: plist missing at " & testPlistPath
        let onDisk = readFile(testPlistPath)
        doAssert onDisk == plistContent,
          "post-apply: on-disk plist bytes differ from desired plist " &
          "content (on-disk len=" & $onDisk.len & ", desired len=" &
          $plistContent.len & ")"

        let postPrint = launchctlPrintGui(uid, testLabel)
        doAssert postPrint.exitCode == 0,
          "post-apply: `launchctl print gui/" & uid & "/" & testLabel &
          "` failed (exit " & $postPrint.exitCode & "): " &
          postPrint.output.strip()
        doAssert postPrint.output.contains(testLabel),
          "post-apply: `launchctl print` output does not mention the " &
          "label '" & testLabel & "': " & postPrint.output.strip()

        # Independent observe call should report present and carry the
        # same digest as a fresh `observeLaunchAgent`.
        let obs1 = observeLaunchAgent(home, testLabel)
        doAssert obs1.present,
          "post-apply: observeLaunchAgent reports absent after apply"
        doAssert obs1.rawBytes.len == plistContent.len,
          "post-apply: observeLaunchAgent.rawBytes len=" &
          $obs1.rawBytes.len & " differs from plist content len=" &
          $plistContent.len

        # ---------------------------------------------------------------
        # 2. RE-APPLY: same plist content. The driver boots out the
        #    prior registration first, so `bootstrap` lands a fresh
        #    registration each time; the on-disk bytes should be
        #    byte-stable.
        # ---------------------------------------------------------------
        let payload2 = applyLaunchAgent(home, testLabel, plistContent,
          testRunAtLoad, testKeepAlive)
        doAssert payload2.len == plistContent.len
        let onDisk2 = readFile(testPlistPath)
        doAssert onDisk2 == plistContent,
          "re-apply: on-disk plist bytes drifted; re-apply should be " &
          "a no-op from the drift-detection perspective"
        let postPrint2 = launchctlPrintGui(uid, testLabel)
        doAssert postPrint2.exitCode == 0,
          "re-apply: `launchctl print` failed after re-apply (exit " &
          $postPrint2.exitCode & "): " & postPrint2.output.strip()

        # ---------------------------------------------------------------
        # 3. DESTROY: `destroyLaunchAgent` calls
        #    `launchctl bootout gui/<uid>/<label>` + removes the plist.
        #    Post-destroy the plist must be absent AND `launchctl
        #    print` must fail (label unregistered).
        # ---------------------------------------------------------------
        destroyLaunchAgent(home, testLabel)
        doAssert not fileExists(testPlistPath),
          "post-destroy: plist STILL exists at " & testPlistPath &
          " (out-of-band check after destroyLaunchAgent)"

        let postDestroyPrint = launchctlPrintGui(uid, testLabel)
        doAssert postDestroyPrint.exitCode != 0,
          "post-destroy: `launchctl print gui/" & uid & "/" &
          testLabel & "` STILL succeeds after destroy (exit " &
          $postDestroyPrint.exitCode & "): " &
          postDestroyPrint.output.strip()

        let postDestroyObs = observeLaunchAgent(home, testLabel)
        doAssert not postDestroyObs.present,
          "post-destroy: observeLaunchAgent reports present after " &
          "destroyLaunchAgent"

        # No orphaned plists: confirm ~/Library/LaunchAgents/ contains
        # nothing with our PID-scoped sentinel in the name.
        let agentDir = home / "Library" / "LaunchAgents"
        if dirExists(agentDir):
          for kind, path in walkDir(agentDir):
            if kind == pcFile and path.contains(pid) and
               path.contains("repro-phase5-launchd-agent"):
              doAssert false,
                "post-destroy: orphaned plist left behind: " & path

        echo "  [OK] launchd.userAgent lifecycle: apply / re-apply " &
          "(no-op) / destroy round-trip on disposable label " &
          testLabel & "; out-of-band `launchctl print gui/" & uid &
          "/<label>` verified registration; destroy unregisters and " &
          "removes the plist with no orphans."
