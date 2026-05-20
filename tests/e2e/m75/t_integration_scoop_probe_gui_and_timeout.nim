## M75 Verification Gate: integration_scoop_probe_gui_and_timeout
##
## The Scoop adapter's post-realize verification used to *execute* the
## realized executable (an `--version`-style probe) to confirm it runs.
## For a GUI application — Chrome, Firefox, VS Code — that launches the
## full application, which never exits, hanging `repro home apply`
## indefinitely. Discovered when the M70 attempt-4 real-host migration
## hung after realizing `googlechrome` running `chrome.exe --version`.
##
## M75 makes the adapter:
##   (1) NEVER exec-probe a GUI / no-console application — presence-on-
##       disk verification ONLY — where "GUI" means the installed Scoop
##       manifest declares a `shortcuts` field OR the primary
##       executable's PE subsystem is the GUI subsystem; and
##   (2) hard-bound every executable probe that IS run with a wall-clock
##       timeout (`probeTimeoutSeconds`) and a process-tree kill, so a
##       misbehaving probe can never hang an apply and never leaves an
##       orphaned child process tree.
##
## Per the M75 verification block this gate exercises the real
## `resolveScoopTool` realize + post-realize verification path against a
## sandboxed Scoop root (the M55 sandboxed-Scoop fixture pattern) with:
##
##   * Case GUI/shortcuts: a fixture app with a `shortcuts` manifest
##     field whose on-disk "executable" would HANG FOREVER and write a
##     side-effect marker if executed. Realization SUCCEEDS and the
##     marker is never written — proving presence-on-disk-only
##     verification (the binary was not run).
##
##   * Case timeout/hang: a fixture app, NOT a GUI app, whose probe
##     binary deliberately blocks forever AND spawns a long-lived child
##     process. `resolveScoopTool` is bounded by the M75 timeout: it
##     returns (raising a structured `EScoopInstallFailed`) within the
##     wall-clock bound, and the probe's child process tree is reaped —
##     the recorded child PID is dead afterwards (no orphan).
##
##   * Case console/normal: a normal console fixture app still probes
##     and verifies as before — realization succeeds, the probe ran.

import std/[json, os, osproc, strutils, tempfiles, times, unittest]

import repro_tool_profiles

import ../scoop/scoop_sandbox

# ---------------------------------------------------------------------------
# M75 fixture helpers.
# ---------------------------------------------------------------------------

type
  M75Fixture = object
    name: string
    version: string
    versionDir: string

proc writeFile0(path, content: string) =
  createDir(path.parentDir)
  writeFile(path, content)

proc stageScoopApp(sandbox: ScoopSandbox; app, version: string;
                   binField: JsonNode; manifestExtra: JsonNode;
                   exeRel, exeBody: string): M75Fixture =
  ## Stage an already-installed Scoop app under the sandboxed root.
  ##   * `binField`      — the JSON `bin` value (string / array).
  ##   * `manifestExtra` — extra top-level manifest keys merged in (used
  ##                       to add a `shortcuts` field). May be `nil`.
  ##   * `exeRel`        — version-dir-relative path of the fixture
  ##                       "executable".
  ##   * `exeBody`       — verbatim bytes of that fixture executable.
  ## Scoop copies the bucket manifest into `<versionDir>/manifest.json`
  ## on install; this writes both the bucket manifest and the
  ## version-dir copy with the same fields, mirroring real Scoop.
  let versionDir = sandbox.appsDir / app / version
  createDir(versionDir)
  writeFile0(versionDir / exeRel.replace('/', DirSep).replace('\\', DirSep),
    exeBody)
  writeFile(versionDir / "install.json",
    ($ %*{"architecture": "64bit", "bucket": sandbox.bucketName}))
  var manifest = %*{
    "version": version,
    "description": "Reprobuild M75 probe fixture",
    "bin": binField}
  if manifestExtra != nil and manifestExtra.kind == JObject:
    for k, v in manifestExtra:
      manifest[k] = v
  writeFile(versionDir / "manifest.json", manifest.pretty())
  let bucketManifestPath = sandbox.bucketManifestDir / (app & ".json")
  createDir(bucketManifestPath.parentDir)
  writeFile(bucketManifestPath, manifest.pretty())
  M75Fixture(name: app, version: version, versionDir: versionDir)

proc pidIsAlive(pid: int): bool =
  ## Report whether process `pid` is currently running. Uses the
  ## Windows `tasklist` filter, which prints the process row when the
  ## PID is live and a fixed "No tasks" line when it is not.
  when defined(windows):
    let res = execCmdEx("tasklist /FI " &
      quoteShell("PID eq " & $pid) & " /NH")
    if res.exitCode != 0:
      return false
    # When no process matches, tasklist prints
    # "INFO: No tasks are running which match the specified criteria."
    result = not res.output.toLowerAscii().contains("no tasks") and
      res.output.contains($pid)
  else:
    let res = execCmdEx("kill -0 " & $pid & " 2>/dev/null")
    result = res.exitCode == 0

when not defined(windows):
  suite "integration_scoop_probe_gui_and_timeout":
    test "platform N/A":
      echo "[platform N/A] t_integration_scoop_probe_gui_and_timeout: requires Windows and a real Scoop install"
      check true
else:
  suite "integration_scoop_probe_gui_and_timeout":
    test "integration_scoop_probe_gui_and_timeout":
      let scoopBinary = resolveScoopBinary()
      if scoopBinary.len == 0:
        raise newException(OSError,
          "M75 gate requires a real scoop binary on PATH (none found). " &
          "Install Scoop from https://scoop.sh/ before running this test.")

      let tempRoot = createTempDir("repro-m75-probe-", "")
      defer: safeRemoveTempRoot(tempRoot)
      let sandbox = setupScoopSandbox(tempRoot, "main")
      let storeRoot = tempRoot / "tool-store"

      # =================================================================
      # Case GUI/shortcuts: a Scoop app whose manifest declares a
      # `shortcuts` field — the reliable Scoop GUI signal. Its on-disk
      # "executable" would HANG FOREVER and write a marker file if run.
      # Realization must succeed WITHOUT executing the binary (presence-
      # on-disk verification only); the marker file must never appear.
      # =================================================================
      block guiShortcutsApp:
        # Marker the fixture exe writes IF it is ever executed. Living
        # outside the sandboxed app dir so realization does not touch it.
        let guiMarker = tempRoot / "gui-probe-was-executed.marker"
        # A `.cmd` that, if executed at all, writes the marker and then
        # blocks forever (the GUI-app failure mode the adapter must NOT
        # trigger). If the adapter exec-probed this, the gate would hang.
        let hangingBody =
          "@echo off\r\n" &
          "echo executed > " & quoteShell(guiMarker) & "\r\n" &
          ":loop\r\n" &
          "ping -n 60 127.0.0.1 >nul\r\n" &
          "goto loop\r\n"
        let fixture = stageScoopApp(sandbox,
          app = "m75-gui-app", version = "1.0.0",
          binField = %"m75gui.cmd",
          manifestExtra = %*{
            "shortcuts": [["m75gui.cmd", "M75 GUI App"]]},
          exeRel = "m75gui.cmd", exeBody = hangingBody)
        let useDef = fixtureUseDef(
          packageSelector = "m75-gui",
          executableName = "m75gui",
          bucket = sandbox.bucketName,
          app = fixture.name,
          version = fixture.version,
          preferredVersion = "",
          manifestChecksum = "",
          executablePath = "m75gui.cmd",
          requiresExecutionProfileChecksum = true)

        # If the adapter exec-probed a GUI app this call would block
        # forever; that it returns at all is the core M75 invariant.
        let started = epochTime()
        let profile = resolveScoopTool(useDef, storeRoot)
        let elapsed = epochTime() - started

        # Realization completed near-instantly — no exec-probe occurred.
        check elapsed < probeTimeoutSeconds.float
        # Presence-on-disk verification: the executable resolves and exists.
        check profile.resolvedExecutablePath.len > 0
        check fileExists(profile.resolvedExecutablePath)
        # The binary was NEVER executed — its side-effect marker is absent.
        check not fileExists(guiMarker)
        # The receipt records no probe was run (presence-only path).
        let receipt = parseFile(
          profile.selectedStorePath / ".repro-receipt.json")
        check receipt{"declaredExecutablePath"}.getStr().len > 0
        check profile.probes.len == 0

      # =================================================================
      # Case timeout/hang: a Scoop app that is NOT a GUI app (no
      # `shortcuts`, a `.cmd` script primary so the PE signal is
      # unknown) whose probe binary deliberately blocks forever AND
      # spawns a long-lived child process. The adapter exec-probes it;
      # the M75 wall-clock timeout must kill the probe AND its child
      # process tree, the apply must not hang, and the recorded child
      # PID must be dead afterwards (no orphan).
      # =================================================================
      block timeoutHangApp:
        # The probe `.cmd` records its spawned child's PID here.
        let childPidFile = tempRoot / "m75-timeout-child.pid"
        # A `.cmd` that on `--version`:
        #   1. starts a detached PowerShell child that records its own
        #      PID and then sleeps for 10 minutes (the "GUI helper
        #      process" stand-in: a child that outlives a bare
        #      parent-kill);
        #   2. then blocks FOREVER itself.
        # The M75 timeout must reap the whole tree — cmd.exe, this
        # script, and the PowerShell grandchild.
        let psChild =
          "$pid | Out-File -Encoding ascii " &
          quoteShell(childPidFile) & "; Start-Sleep -Seconds 600"
        let hangingProbeBody =
          "@echo off\r\n" &
          "if /I \"%1\"==\"--version\" (\r\n" &
          "  start \"\" /b powershell -NoProfile -Command " &
          quoteShell(psChild) & "\r\n" &
          "  :hang\r\n" &
          "  ping -n 600 127.0.0.1 >nul\r\n" &
          "  goto hang\r\n" &
          ")\r\n" &
          "echo m75-timeout 1.0.0\r\n" &
          "exit /b 0\r\n"
        let fixture = stageScoopApp(sandbox,
          app = "m75-timeout-app", version = "1.0.0",
          binField = %"m75hang.cmd",
          manifestExtra = nil,
          exeRel = "m75hang.cmd", exeBody = hangingProbeBody)
        let useDef = fixtureUseDef(
          packageSelector = "m75-timeout",
          executableName = "m75hang",
          bucket = sandbox.bucketName,
          app = fixture.name,
          version = fixture.version,
          preferredVersion = "",
          manifestChecksum = "",
          executablePath = "m75hang.cmd",
          requiresExecutionProfileChecksum = true)

        var raised = false
        var diagnostic = ""
        let started = epochTime()
        try:
          discard resolveScoopTool(useDef, storeRoot)
        except EScoopInstallFailed as err:
          raised = true
          diagnostic = err.msg
        let elapsed = epochTime() - started

        # The probe was bounded: a structured failure, NOT a hang.
        check raised
        # Wall-clock bound: the timeout fired and the apply did not hang.
        # `probeTimeoutSeconds` + a generous margin for process spawn /
        # tree-kill / scoop sandbox overhead.
        check elapsed < (probeTimeoutSeconds + 30).float
        # The structured diagnostic names the timeout, not a crash.
        check diagnostic.contains("timed out")
        check diagnostic.contains($probeTimeoutSeconds & "s")

        # The probe's child process tree was reaped — no orphan. Give the
        # async `taskkill /T` a brief grace window to land, then assert
        # the recorded child PID is dead.
        check fileExists(childPidFile)
        let childPid = readFile(childPidFile).strip().splitWhitespace()[0]
          .parseInt()
        var childDead = false
        let killDeadline = epochTime() + 15.0
        while epochTime() < killDeadline:
          if not pidIsAlive(childPid):
            childDead = true
            break
          sleep(200)
        check childDead

      # =================================================================
      # Case console/normal: a normal console fixture app — no
      # `shortcuts`, a probe that prints `--version` and exits 0. It
      # still probes and verifies exactly as before M75.
      # =================================================================
      block normalConsoleApp:
        let normalBody =
          "@echo off\r\n" &
          "if /I \"%1\"==\"--version\" ( echo m75-console 2.0.0 & exit /b 0 )\r\n" &
          "echo m75-console args=%*\r\n" &
          "exit /b 0\r\n"
        let fixture = stageScoopApp(sandbox,
          app = "m75-console-app", version = "2.0.0",
          binField = %"m75con.cmd",
          manifestExtra = nil,
          exeRel = "m75con.cmd", exeBody = normalBody)
        let useDef = fixtureUseDef(
          packageSelector = "m75-console",
          executableName = "m75con",
          bucket = sandbox.bucketName,
          app = fixture.name,
          version = fixture.version,
          preferredVersion = "",
          manifestChecksum = "",
          executablePath = "m75con.cmd",
          requiresExecutionProfileChecksum = true)

        let started = epochTime()
        let profile = resolveScoopTool(useDef, storeRoot)
        let elapsed = epochTime() - started

        # A fast, legitimate console probe completes well inside the bound.
        check elapsed < probeTimeoutSeconds.float
        check profile.resolvedExecutablePath.len > 0
        check fileExists(profile.resolvedExecutablePath)
        # The console app WAS probed — a probe result is recorded and it
        # passed (exit 0, not timed out).
        check profile.probes.len == 1
        check profile.probes[0].exitCode == 0
        check not profile.probes[0].timedOut
        check profile.probes[0].output.contains("m75-console 2.0.0")

        # The executable still runs through the typed launch wrapper.
        let launched = launchScoopExecutable(profile.selectedStorePath,
          ["--version"])
        check launched.exitCode == 0
        check launched.output.contains("m75-console 2.0.0")
