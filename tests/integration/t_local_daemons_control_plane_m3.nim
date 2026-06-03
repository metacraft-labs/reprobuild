import std/[os, osproc, strutils, tempfiles, times, unittest]

import repro_test_support

proc repoRoot(): string =
  getCurrentDir()

proc publicReproBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)

proc fixtureSource(): string =
  repoRoot() / "tests" / "fixtures" / "local-daemons-control-plane" /
    "direct-mode-parity" / "project"

proc daemonEndpoint(tempRoot: string): string =
  daemonSocketEndpoint(tempRoot.extractFilename)

proc daemonStateDir(tempRoot: string): string =
  tempRoot / "state"

proc daemonLogPath(tempRoot: string): string =
  daemonStateDir(tempRoot) / "logs" / "repro-daemon.log"

proc daemonArgs(tempRoot: string): seq[string] =
  @[
    "--endpoint", daemonEndpoint(tempRoot),
    "--state-dir", daemonStateDir(tempRoot),
    "--log", daemonLogPath(tempRoot)
  ]

proc daemonEnv(tempRoot: string): seq[(string, string)] =
  @[
    ("REPRO_DAEMON_ENDPOINT", daemonEndpoint(tempRoot)),
    ("REPRO_DAEMON_STATE_DIR", daemonStateDir(tempRoot)),
    ("REPROBUILD_STORE_ROOT", tempRoot / "store")
  ]

proc stopDaemon(tempRoot: string) =
  discard runShell(shellCommand(@[publicReproBin(), "daemon", "stop"] &
    daemonArgs(tempRoot)), repoRoot())
  try: removeFile(daemonEndpoint(tempRoot)) except OSError: discard

proc copyFixtureProject(dest: string) =
  createDir(dest.parentDir)
  copyDir(fixtureSource(), dest)

proc baseBuildArgs(projectRoot, tempRoot: string): seq[string] =
  @[
    publicReproBin(), "build", projectRoot,
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / "work",
    "--action-cache-root=" & tempRoot / "action-cache",
    "--progress=quiet",
    "--log=summary",
    "--no-runquota"
  ]

proc buildCommand(projectRoot, tempRoot: string; extra: openArray[string] = [];
                  env: openArray[(string, string)] = []): CmdSpec =
  shellCommand(baseBuildArgs(projectRoot, tempRoot) & @extra,
    daemonEnv(tempRoot) & @env)

proc waitForLogContains(path, needle: string; timeoutSeconds = 10.0) =
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    if fileExists(path):
      let body = readFile(path)
      if body.contains(needle):
        return
    sleep(25)
  checkpoint(if fileExists(path): readFile(path) else: "missing log " & path)
  check false

suite "Local daemons/control-plane M3 build routing":
  when isNixSupported:
    test "integration_repro_build_daemon_flag_matrix":
      let tempRoot = createTempDir("repro-daemon-m3-matrix", "")
      defer:
        stopDaemon(tempRoot)
        removeDir(tempRoot)

      let directProject = tempRoot / "direct-project"
      copyFixtureProject(directProject)
      let direct = requireSuccess(buildCommand(directProject, tempRoot,
        ["--daemon=off"]), repoRoot())
      check direct.contains("project: localDaemonParity")
      check readFile(directProject / "dist" / "copied.txt") ==
        "direct-mode fixture\n"

      let envOffProject = tempRoot / "env-off-project"
      copyFixtureProject(envOffProject)
      let envOff = requireSuccess(buildCommand(envOffProject, tempRoot,
        env = [("REPRO_DAEMON", "off")]), repoRoot())
      check envOff.contains("project: localDaemonParity")

      let precedenceProject = tempRoot / "precedence-project"
      copyFixtureProject(precedenceProject)
      let precedence = requireSuccess(buildCommand(precedenceProject, tempRoot,
        ["--daemon=off"], env = [("REPRO_DAEMON", "require")]), repoRoot())
      check precedence.contains("project: localDaemonParity")

      let badFlag = requireFailure(buildCommand(tempRoot / "missing", tempRoot,
        ["--daemon=sideways"]), repoRoot())
      check badFlag.contains("unsupported --daemon=sideways")

      let badEnv = requireFailure(buildCommand(tempRoot / "missing", tempRoot,
        env = [("REPRO_DAEMON", "sideways")]), repoRoot())
      check badEnv.contains("unsupported REPRO_DAEMON=sideways")

      let autoProject = tempRoot / "auto-project"
      copyFixtureProject(autoProject)
      let autoOutput = requireSuccess(buildCommand(autoProject, tempRoot,
        ["--daemon=auto"]), repoRoot())
      check not autoOutput.contains("daemon build unsupported")
      check autoOutput.contains("project: localDaemonParity")
      check readFile(autoProject / "dist" / "copied.txt") ==
        "direct-mode fixture\n"

      let requireProject = tempRoot / "require-project"
      copyFixtureProject(requireProject)
      let required = requireSuccess(buildCommand(requireProject, tempRoot,
        ["--daemon=require"]), repoRoot())
      check required.contains("project: localDaemonParity")
      check readFile(requireProject / "dist" / "copied.txt") ==
        "direct-mode fixture\n"

      let envRequireProject = tempRoot / "env-require-project"
      copyFixtureProject(envRequireProject)
      let envRequire = requireSuccess(buildCommand(envRequireProject, tempRoot,
        env = [("REPRO_DAEMON", "require")]), repoRoot())
      check envRequire.contains("project: localDaemonParity")
      check readFile(envRequireProject / "dist" / "copied.txt") ==
        "direct-mode fixture\n"

    test "integration_repro_build_attached_client_disconnect_cancels":
      when defined(posix):
        let tempRoot = createTempDir("repro-daemon-m3-cancel", "")
        defer:
          stopDaemon(tempRoot)
          removeDir(tempRoot)

        let projectRoot = tempRoot / "project"
        copyFixtureProject(projectRoot)

        putEnv("REPRO_DAEMON_M3_BUILD_RESPONSE_DELAY_MS", "10000")
        let daemon = startProcess(publicReproBin(),
          args = @["daemon", "start", "--foreground"] & daemonArgs(tempRoot),
          workingDir = repoRoot(),
          options = {poUsePath, poStdErrToStdOut})
        delEnv("REPRO_DAEMON_M3_BUILD_RESPONSE_DELAY_MS")
        defer:
          if daemon.running():
            stopDaemon(tempRoot)
            discard daemon.waitForExit()
          daemon.close()

        waitForLogContains(daemonLogPath(tempRoot),
          "started role=repro-daemon/user")

        let client = startProcess("env",
          args = @[
            "REPRO_DAEMON_ENDPOINT=" & daemonEndpoint(tempRoot),
            "REPRO_DAEMON_STATE_DIR=" & daemonStateDir(tempRoot),
            "REPROBUILD_STORE_ROOT=" & tempRoot / "store",
            publicReproBin(), "build", projectRoot,
            "--daemon=require",
            "--tool-provisioning=path",
            "--work-root=" & tempRoot / "work",
            "--action-cache-root=" & tempRoot / "action-cache",
            "--progress=quiet",
            "--log=summary",
            "--no-runquota"
          ],
          workingDir = repoRoot(),
          options = {poUsePath, poStdErrToStdOut})
        defer:
          if client.running():
            client.terminate()
            discard client.waitForExit()
          client.close()

        waitForLogContains(daemonLogPath(tempRoot),
          "build request accepted session=")
        check client.running()
        client.terminate()
        discard client.waitForExit()

        waitForLogContains(daemonLogPath(tempRoot),
          "build request cancelled session=")
        check not dirExists(projectRoot / "dist")
      else:
        echo "[platform N/A] POSIX attached build cancellation test"
