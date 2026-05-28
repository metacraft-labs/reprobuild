import std/[os, osproc, strutils, tempfiles, unittest]

proc q(value: string): string =
  quoteShell(value)

proc shellCommand(args: openArray[string];
                  env: openArray[(string, string)] = []): string =
  var parts: seq[string] = @[]
  for (name, value) in env:
    parts.add(name & "=" & q(value))
  for arg in args:
    parts.add(q(arg))
  parts.join(" ")

proc runShell(command: string; cwd = getCurrentDir()):
    tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireSuccess(command: string; cwd = getCurrentDir()): string =
  let res = runShell(command, cwd)
  if res.code != 0:
    checkpoint(res.output)
  check res.code == 0
  res.output

proc requireFailure(command: string; cwd = getCurrentDir()): string =
  let res = runShell(command, cwd)
  if res.code == 0:
    checkpoint(res.output)
  check res.code != 0
  res.output

proc repoRoot(): string =
  getCurrentDir()

proc publicReproBin(): string =
  repoRoot() / "build" / "bin" / "repro"

proc userDaemonBin(): string =
  repoRoot() / "build" / "bin" / "repro-daemon"

proc storeDaemonBin(): string =
  repoRoot() / "build" / "bin" / "reprostored"

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

    for value in ["auto", "require", "off"]:
      let output = requireReproFailure(["build", "--daemon=" & value])
      check output.contains(
        "repro build: error: unsupported build flag: --daemon=" & value)

    let statsCapture = requireReproFailure([
      "build", "--stats-capture=decision,timing"])
    check statsCapture.contains(
      "repro build: error: unsupported build flag: --stats-capture=decision,timing")

    let stats = requireReproFailure(["stats"])
    check stats.contains("usage: repro")
    check not stats.contains("repro stats")

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
      "--tool-provisioning=path",
      "--work-root=" & tempRoot / "watch-work",
      "--max-cycles=1",
      "--debounce-ms=10"
    ], env = [("REPROBUILD_STORE_ROOT", storeRoot)]), repoRoot())
    check watchOutput.contains("repro watch: cycle 1 start initial")
    check watchOutput.contains("repro watch: cycle 1 result exitCode=0")
    check watchOutput.contains("repro watch: max cycles reached")
