## Test: Python Nix Evaluation Daemon & Client Provisioning Integration
##
## This test validates the full integration of the in-repo Python Nix evaluation
## daemon (`tools/reprobuild-nix-daemon/reprobuild-nix-daemon`) and the build
## engine client's `bakForeignProvision` execution flow.
##
## Scenarios Tested:
##   * Scenario 3.1: Cold Start and Materialisation
##     Spins up the daemon, executes the `bakForeignProvision` action for the local
##     flake, asserts that the output receipt is successfully created containing a valid
##     Nix store path, and ensures that the daemon exits successfully.
##   * Scenario 3.2: Observed Dependencies Capture
##     Asserts that the file paths read during flake evaluation (specifically `flake.nix`
##     and `flake.lock`) are returned as observed input dependencies (`monitorReads`)
##     within the action result's evidence.
##
## Testing Strategy:
##   * Pure, mock-free integration test running against the Python daemon shim
##     and the build engine's socket client logic.

import std/[unittest, os, osproc, strutils, tempfiles]
import repro_core
import repro_core/dependency_gathering
import repro_build_engine

const RepoMarker = "repro.nim"
const FixtureRelRoot = "tests/fixtures/nix-daemon-local-flake"
const FixtureSelector = ".#hello-sh"
const FixtureExecutable = "bin/reprobuild-nix-daemon-fixture"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc findNixDaemon(repoRoot: string): string =
  let envBin = getEnv("REPROBUILD_NIX_DAEMON_BIN")
  for candidate in [
    envBin,
    repoRoot / "build" / "reprobuild-nix-daemon",
    repoRoot / "tools" / "reprobuild-nix-daemon" / "reprobuild-nix-daemon",
    repoRoot.parentDir / "reprobuild-nix-daemon" / "build" /
      "reprobuild-nix-daemon"
  ]:
    if candidate.len == 0:
      continue
    if fileExists(candidate):
      when defined(posix):
        let perms = getFilePermissions(candidate)
        if fpUserExec notin perms and fpGroupExec notin perms and
            fpOthersExec notin perms:
          raise newException(IOError,
            "reprobuild-nix-daemon is not executable: " & candidate)
      return candidate
  raise newException(IOError,
    "reprobuild-nix-daemon missing; set REPROBUILD_NIX_DAEMON_BIN")

proc prepareFixtureRoot(repoRoot: string): string =
  let sourceRoot = repoRoot / FixtureRelRoot
  result = createTempDir("repro-nix-daemon-fixture-", "")
  copyFile(sourceRoot / "flake.nix", result / "flake.nix")
  copyFile(sourceRoot / "flake.lock", result / "flake.lock")
  for args in [
    "init -q",
    "add flake.nix flake.lock"
  ]:
    let (output, code) = execCmdEx("git -C " & quoteShell(result) & " " & args)
    if code != 0:
      raise newException(IOError,
        "failed to prepare Nix fixture git index: " & output)

when defined(posix):
  proc makeNonExecutableDaemonCandidate(): string =
    result = getTempDir() / ("reprobuild-nix-daemon-nonexec-" &
      $getCurrentProcessId())
    writeFile(result, "#!/bin/sh\necho should-not-run\n")
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpGroupRead,
      fpOthersRead})

suite "Nix Evaluation Daemon and Foreign Provisioner Integration Tests":

  when defined(posix):
    test "production provisioner rejects non-executable REPROBUILD_NIX_DAEMON_BIN":
      let repoRoot = findRepoRoot()
      let fixtureRoot = prepareFixtureRoot(repoRoot)
      defer: removeDir(fixtureRoot)
      let sentinel = makeNonExecutableDaemonCandidate()
      defer: removeFile(sentinel)
      let previousDaemonBin = getEnv("REPROBUILD_NIX_DAEMON_BIN")
      putEnv("REPROBUILD_NIX_DAEMON_BIN", sentinel)
      defer: putEnv("REPROBUILD_NIX_DAEMON_BIN", previousDaemonBin)
      let previousUser = getEnv("USER")
      putEnv("USER", "repro-nix-nonexec-" & $getCurrentProcessId())
      defer: putEnv("USER", previousUser)

      let receiptFile = getTempDir() / ("reprobuild-nonexec-receipt-" &
        $getCurrentProcessId())
      if fileExists(receiptFile):
        removeFile(receiptFile)

      let action = BuildAction(
        governingLockIdentity: lockIdentityOutsideSolvedGraph(),
        kind: bakForeignProvision,
        id: "test.foreign.nix.nonexec-daemon",
        argv: @["nix", FixtureSelector],
        outputs: @[receiptFile],
        cwd: fixtureRoot,
        dependencyPolicy: DependencyGatheringPolicy(kind: dgAutomaticMonitor)
      )

      let res = executeBuiltinAction(action)
      check res.status == asFailed
      check "REPROBUILD_NIX_DAEMON_BIN exists but is not executable" in
        res.stderr
      check not fileExists(receiptFile)

  test "Scenario 3.1 & 3.2: Cold start, resolution, and dependency tracking":
    let repoRoot = findRepoRoot()
    let fixtureRoot = prepareFixtureRoot(repoRoot)
    defer: removeDir(fixtureRoot)
    let daemonPath = findNixDaemon(repoRoot)
    let previousDaemonBin = getEnv("REPROBUILD_NIX_DAEMON_BIN")
    putEnv("REPROBUILD_NIX_DAEMON_BIN", daemonPath)
    defer: putEnv("REPROBUILD_NIX_DAEMON_BIN", previousDaemonBin)
    let previousUser = getEnv("USER")
    putEnv("USER", "repro-nix-provisioner-" & $getCurrentProcessId())
    defer: putEnv("USER", previousUser)

    # Assert daemon binary is built and present
    check fileExists(daemonPath)

    # Prepare build receipt path
    let receiptDir = repoRoot / "build" / "test-foreign"
    let receiptFile = receiptDir / "reprobuild.receipt"
    if fileExists(receiptFile):
      removeFile(receiptFile)
    createDir(receiptDir)

    # Setup the bakForeignProvision action. Use a lightweight package already
    # present in the dev shell; this verifies real materialization without
    # rebuilding the full repo package.
    let action = BuildAction(
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      kind: bakForeignProvision,
      id: "test.foreign.nix.resolve",
      argv: @["nix", FixtureSelector],
      outputs: @[receiptFile],
      cwd: fixtureRoot,
      dependencyPolicy: DependencyGatheringPolicy(kind: dgAutomaticMonitor)
    )

    # Execute the builtin action (which spawns the daemon and performs socket query)
    let res = executeBuiltinAction(action)

    # Assert success status
    if res.status != asSucceeded:
      echo "=== Action Failed ==="
      echo "Stdout: ", res.stdout
      echo "Stderr: ", res.stderr
      echo "Reason: ", res.reason
      echo "====================="

    check res.status == asSucceeded
    check res.exitCode == 0

    # Verify receipt output contains a valid Nix store path
    check fileExists(receiptFile)
    let storePath = readFile(receiptFile).strip()
    check storePath.startsWith("/nix/store/")
    check fileExists(storePath / FixtureExecutable)
    checkpoint("Resolved store path: " & storePath)

    # Verify observed dependencies (monitorReads) carry the actual local flake
    # inputs used for resolution.
    let reads = res.evidence.monitorReads
    check reads.len > 0

    var foundFlakeNix = false
    var foundFlakeLock = false
    for path in reads:
      if path == "flake.nix":
        foundFlakeNix = true
      if path == "flake.lock":
        foundFlakeLock = true

    check foundFlakeNix
    check foundFlakeLock
    checkpoint("Observed dependencies: " & $reads)

    # Clean up receipt
    removeFile(receiptFile)
