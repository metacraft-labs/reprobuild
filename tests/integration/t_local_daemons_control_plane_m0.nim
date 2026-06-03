import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc repoRoot(): string =
  getCurrentDir()

proc publicReproBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)

proc userDaemonBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro-daemon", ExeExt)

proc storeDaemonBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("reprostored", ExeExt)

proc requireReproFailure(args: openArray[string]): string =
  requireFailure(shellCommand(@[publicReproBin()] & @args), repoRoot())

proc entrypointNames(): seq[string] =
  for line in lines(repoRoot() / "apps" / "entrypoints.txt"):
    let stripped = line.strip()
    if stripped.len == 0 or stripped.startsWith("#"):
      continue
    result.add(stripped.splitWhitespace()[0])

proc copyFixtureProject(source, dest: string) =
  createDir(dest.parentDir)
  copyDir(source, dest)

suite "Local daemons/control-plane M0 current-state gates":
  test "test_daemon_entrypoint_builds":
    check "repro-daemon" in entrypointNames()
    check fileExists(userDaemonBin())
    let output = requireSuccess(shellCommand([userDaemonBin(), "--version"]),
      repoRoot())
    check output.strip().startsWith("repro-daemon ")
    check "reprostored" in entrypointNames()
    check fileExists(storeDaemonBin())
    let storeOutput = requireSuccess(shellCommand([storeDaemonBin(),
      "--version"]), repoRoot())
    check storeOutput.strip().startsWith("reprostored ")

  test "test_daemon_track_current_surface_inventory":
    check fileExists(publicReproBin())

    let tempRoot = createTempDir("repro-daemon-m0-inventory", "")
    defer: removeDir(tempRoot)
    let daemon = requireSuccess(shellCommand([
      publicReproBin(), "daemon", "status",
      "--endpoint", tempRoot / "repro-daemon-m0-inventory.sock",
      "--state-dir", tempRoot / "state"
    ]), repoRoot())
    check daemon.contains("repro daemon: not-running")
    check not daemon.contains("repro store daemon")

    let invalidDaemon = requireReproFailure(["build", "--daemon=invalid"])
    check invalidDaemon.contains(
      "repro build: error: unsupported --daemon=invalid")

    let statsCapture = requireReproFailure([
      "build", "--stats-capture=invalid"])
    check statsCapture.contains(
      "repro build: error: unsupported --stats-capture=invalid")

    let stats = requireSuccess(shellCommand([
      publicReproBin(), "stats", "status", "--project-root=" & tempRoot
    ]), repoRoot())
    check stats.contains("stats capture: disabled by default")
    check stats.contains("flushed: 0")

    let storeDaemon = requireReproFailure([
      "store", "daemon", "status", "--store-root=" & tempRoot / "store"])
    check storeDaemon.contains("only --dev is implemented")

  test "direct-mode parity fixture builds through current direct path":
    let tempRoot = createTempDir("repro-daemon-m0-parity", "")
    defer: removeDir(tempRoot)
    let sourceFixture = repoRoot() / "tests" / "fixtures" /
      "local-daemons-control-plane" / "direct-mode-parity" / "project"
    let projectRoot = tempRoot / "project"
    copyFixtureProject(sourceFixture, projectRoot)

    let storeRoot = tempRoot / "store"
    let buildOutput = requireSuccess(shellCommand([
      publicReproBin(), "build", projectRoot,
      "--daemon=off",
      "--tool-provisioning=path",
      "--work-root=" & tempRoot / "work",
      "--action-cache-root=" & tempRoot / "action-cache",
      "--progress=quiet",
      "--log=actions",
      "--no-runquota"
    ], env = [("REPROBUILD_STORE_ROOT", storeRoot)]), repoRoot())
    check buildOutput.contains("project: localDaemonParity")
    check buildOutput.contains("scheduler: actions=3")
    check buildOutput.contains(
      "action: write-generated status=asSucceeded")
    check readFile(projectRoot / "dist" / "copied.txt") ==
      "direct-mode fixture\n"
    check readFile(projectRoot / "dist" / "stamp.txt") ==
      "local-daemons-direct-mode-parity\ndist/copied.txt\n"

    let watchOutput = requireSuccess(shellCommand([
      publicReproBin(), "watch", projectRoot,
      "--daemon=off",
      "--tool-provisioning=path",
      "--work-root=" & tempRoot / "watch-work",
      "--max-cycles=1",
      "--debounce-ms=10"
    ], env = [("REPROBUILD_STORE_ROOT", storeRoot)]), repoRoot())
    check watchOutput.contains("repro watch: cycle 1 start initial")
    check watchOutput.contains("repro watch: cycle 1 result exitCode=0")
    check watchOutput.contains("repro watch: max cycles reached")
