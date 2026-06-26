## Portable-Macos-Sandbox-Tools B1/B2 — engine-side macOS SIP-safe monitored
## action launch.
##
## These tests lock in the Phase-1 engine fixes for monitoring its own actions
## on macOS, with every expectation justified by the specs:
##
##   * **B2 — real failure diagnostics survive** (``Monitor-Hook-Shim.md``,
##     Acceptance Criteria "child stdout/stderr pass through without corrupting
##     monitor event streams" + §"conservative failure diagnostics"). The io-mon
##     shim writes a per-process ``io-mon: macOS body-patch …`` banner to stderr
##     on every monitored (grand)child; for a deep tree this floods the captured
##     log and buries the failing command's real error. ``stripMonitorBanner``
##     separates the monitor's own noise from the action's output so a failing
##     action shows its actual error. This is platform-agnostic (the banner is a
##     fixed string) so the test runs everywhere.
##
##   * **B1 + fail-safe — SIP-safe launch or conservative failure**
##     (``Monitor-Hook-Shim.md:501`` "injection failure MUST fail the monitored
##     action or make it non-cacheable"; ``Sandbox-And-Monitoring.md`` ~line 575
##     "SIP path rewriting from propagation.nim";
##     ``MacOS-Interpose-Limitations-Under-Chained-Fixups.md`` drop-in /
##     ``CT_SANDBOX_TOOLS_DIR`` mechanism). On macOS the engine MUST NOT route a
##     monitored action through the SIP-protected ``/bin/sh`` (which strips
##     ``DYLD_INSERT_LIBRARIES`` and degrades injection); it resolves a non-SIP
##     drop-in / PATH shell instead, and when none is resolvable it FAILS the
##     action rather than running it unmonitored. The macOS-only arms assert both
##     halves of that contract.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine

suite "Portable-Macos-Sandbox-Tools B2: monitor banner does not bury real stderr":

  test "stripMonitorBanner removes io-mon banner lines, keeps the real error":
    # A realistic captured stderr from a failing monitored autotools action:
    # many shim banner lines (one per injected process) interleaved with the
    # single real error line the user actually needs to see.
    # The current io-mon macOS banners: the install banner (one per injected
    # process), optionally carrying a debug per-mechanism note, and the
    # body-patch-skipped line emitted when body-patch is disabled for diagnosis.
    # All begin ``io-mon: macOS body-patch ``.
    let captured =
      "io-mon: macOS body-patch installed=24 failed=2 absent=3 fork_tramp=ok spawn_tramp=skip spawnp_tramp=skip\n" &
      "io-mon: macOS body-patch installed=28 failed=0 absent=3 fork_tramp=ok spawn_tramp=ok spawnp_tramp=ok [debug] interpose disabled\n" &
      "configure: error: C compiler cannot create executables\n" &
      "io-mon: macOS body-patch installed=28 failed=0 absent=3 fork_tramp=ok spawn_tramp=ok spawnp_tramp=ok\n" &
      "io-mon: macOS body-patch not installed [debug] body-patch disabled\n"
    let cleaned = stripMonitorBanner(captured)
    # The real error MUST survive verbatim.
    check cleaned.contains("configure: error: C compiler cannot create executables")
    # Every banner line MUST be gone — otherwise the failure diagnostic is
    # buried and the user is forced back to the raw log (the B2 regression).
    check not cleaned.contains("io-mon: macOS body-patch")

  test "stripMonitorBanner is a no-op on banner-free output":
    let captured = "ld: symbol(s) not found for architecture arm64\n"
    check stripMonitorBanner(captured).strip() ==
      "ld: symbol(s) not found for architecture arm64"

  test "stripMonitorBanner preserves empty input":
    check stripMonitorBanner("") == ""

when defined(macosx):
  suite "Portable-Macos-Sandbox-Tools B1: macOS SIP-safe monitored launch":

    test "resolveNonSipShell never returns a SIP-protected shell":
      # The dev shell always has a non-SIP bash on PATH, so resolution should
      # succeed AND the resolved shell must live outside the SIP prefixes
      # (/bin, /sbin, /usr/bin, /usr/sbin) — otherwise routing a monitored
      # action through it would strip DYLD_INSERT_LIBRARIES (B1).
      let sh = resolveNonSipShell()
      if sh.len > 0:
        for prefix in ["/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/"]:
          check not sh.startsWith(prefix)

    test "resolveNonSipShell prefers the CT_SANDBOX_TOOLS_DIR drop-in":
      # When a drop-in bundle is present, the engine wrapper shell must be the
      # drop-in /bin/sh (the canonical rewriteSipPath target) so it matches the
      # shell the monitor's own exec-redirect would pick
      # (MacOS-Interpose-Limitations-Under-Chained-Fixups.md).
      let tempRoot = createTempDir("repro-b1-dropin", "")
      defer: removeDir(tempRoot)
      let dropInBin = tempRoot / "bin"
      createDir(dropInBin)
      # A trivial executable standing in for the drop-in sh.
      let dropInSh = dropInBin / "sh"
      writeFile(dropInSh, "#!/bin/sh\nexit 0\n")
      setFilePermissions(dropInSh, {fpUserExec, fpUserRead, fpUserWrite,
        fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

      let prevSandbox = getEnv("CT_SANDBOX_TOOLS_DIR")
      putEnv("CT_SANDBOX_TOOLS_DIR", tempRoot)
      defer:
        if prevSandbox.len > 0: putEnv("CT_SANDBOX_TOOLS_DIR", prevSandbox)
        else: delEnv("CT_SANDBOX_TOOLS_DIR")
      check resolveNonSipShell() == dropInSh

    test "fail-safe: monitored action fails when no non-SIP shell is resolvable":
      # Monitor-Hook-Shim.md:501 — when monitoring is required but injection
      # cannot be preserved (no non-SIP wrapper shell), the action MUST fail
      # (and therefore is never published/cached) rather than run unmonitored.
      # We force that state by pointing PATH at a directory with no `sh` and
      # clearing CT_SANDBOX_TOOLS_DIR, so resolveNonSipShell() returns "".
      let tempRoot = createTempDir("repro-b1-failsafe", "")
      defer: removeDir(tempRoot)
      let workRoot = tempRoot / "work"
      let cacheRoot = tempRoot / ".repro-cache"
      let emptyBin = tempRoot / "empty-bin"  # no `sh` here
      createDir(workRoot)
      createDir(emptyBin)

      let prevPath = getEnv("PATH")
      let prevSandbox = getEnv("CT_SANDBOX_TOOLS_DIR")
      putEnv("PATH", emptyBin)
      delEnv("CT_SANDBOX_TOOLS_DIR")
      defer:
        putEnv("PATH", prevPath)
        if prevSandbox.len > 0: putEnv("CT_SANDBOX_TOOLS_DIR", prevSandbox)

      # Sanity: in this environment no non-SIP shell resolves.
      check resolveNonSipShell().len == 0

      var config = defaultBuildEngineConfig(cacheRoot)
      config.bypassRunQuota = true
      config.maxParallelism = 1'u32
      config.stdoutLimit = 65536
      config.stderrLimit = 65536
      # Wire a (dummy but non-empty) monitor CLI path so the engine tags the
      # action as monitored (monitorDepfile gets set) and routes it through the
      # bypass launch — where the SIP-safe gate lives. The monitor itself is
      # never actually exec'd because the launch fails first.
      config.monitorCliPath = "/usr/bin/true"
      config.monitorCliArgs = @[]

      let buildResult = runBuild(graph([
        action("sip-failsafe", ["/usr/bin/true"], cwd = workRoot,
          outputs = @[], commandStatsId = "b1-failsafe")
      ]), config)

      var sawAction = false
      for item in buildResult.results:
        if item.id == "sip-failsafe":
          sawAction = true
          # The action MUST be failed (conservative fail-safe), not succeeded.
          check item.status == asFailed
          # The diagnostic MUST explain the SIP-safety refusal so the failure
          # is actionable (conservative failure diagnostics).
          check item.stderr.contains("SIP-safe") or
            item.stderr.contains("non-SIP shell")
      check sawAction

    test "positive: monitored action launches via a non-SIP wrapper shell":
      # B1 positive path: with a non-SIP shell resolvable (always true in the
      # dev shell), a monitored action is launched through it (NOT the SIP
      # /bin/sh) and runs to completion. We assert the action ran by having it
      # write a marker file; a SIP-strip degradation would not change this
      # process-creation outcome, but the launch path itself is what the fix
      # touches, so the load-bearing check is that the action is NOT failed by
      # the SIP-safety gate (contrast with the fail-safe arm above).
      check resolveNonSipShell().len > 0  # dev shell precondition

      let tempRoot = createTempDir("repro-b1-positive", "")
      defer: removeDir(tempRoot)
      let workRoot = tempRoot / "work"
      let cacheRoot = tempRoot / ".repro-cache"
      createDir(workRoot)
      let marker = workRoot / "ran.marker"

      # A tiny "fake monitor" that mirrors the real ``repro internal io
      # monitor`` argv contract — it consumes everything up to and including the
      # ``--`` separator (``--depfile <path> --``) and exec's the remaining argv
      # (the real command). It writes a stub depfile so monitor-evidence reads
      # don't escalate, and lets us exercise the engine's launch wrapping
      # without needing the real shim/injection in a unit test.
      let fakeMonitor = tempRoot / "fake-monitor.sh"
      writeFile(fakeMonitor,
        "#!/bin/sh\n" &
        "depfile=\"\"\n" &
        "while [ \"$#\" -gt 0 ]; do\n" &
        "  case \"$1\" in\n" &
        "    --depfile) depfile=\"$2\"; shift 2;;\n" &
        "    --) shift; break;;\n" &
        "    *) shift;;\n" &
        "  esac\n" &
        "done\n" &
        "[ -n \"$depfile\" ] && printf 'RMDF' > \"$depfile\"\n" &
        "exec \"$@\"\n")
      setFilePermissions(fakeMonitor, {fpUserExec, fpUserRead, fpUserWrite,
        fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

      var config = defaultBuildEngineConfig(cacheRoot)
      config.bypassRunQuota = true
      config.maxParallelism = 1'u32
      config.stdoutLimit = 65536
      config.stderrLimit = 65536
      # Tagging the action as monitored (non-empty monitorCliPath) is what
      # routes it through the SIP-safe launch gate on macOS.
      config.monitorCliPath = fakeMonitor
      config.monitorCliArgs = @[]

      let buildResult = runBuild(graph([
        action("sip-positive",
          ["/bin/sh", "-c", "printf ok > " & marker],
          cwd = workRoot, outputs = @[], commandStatsId = "b1-positive")
      ]), config)

      var sawAction = false
      for item in buildResult.results:
        if item.id == "sip-positive":
          sawAction = true
          # MUST NOT be failed by the SIP-safety gate.
          check not (item.status == asFailed and
            item.stderr.contains("SIP-safe"))
      check sawAction
      # The marker proves the wrapped command actually executed through the
      # resolved non-SIP wrapper shell.
      check fileExists(marker)
      check readFile(marker).strip() == "ok"
