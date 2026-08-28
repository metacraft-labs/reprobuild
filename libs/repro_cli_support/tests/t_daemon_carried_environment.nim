import std/[os, sequtils, strutils, unittest]

import repro_cli_support
import repro_daemon_core/protocol

proc hasEnvPair(values: openArray[string]; key, value: string): bool =
  let expected = key & "=" & value
  for item in values:
    if item == expected:
      return true
  false

proc replaceAscii(body: var seq[byte]; oldValue, newValue: string): bool =
  if oldValue.len != newValue.len:
    return false
  let offset = cast[string](body).find(oldValue)
  if offset < 0:
    return false
  for index, value in newValue:
    body[offset + index] = byte(value)
  true

suite "daemon carried environment":
  test "auto runquota memory budget accepts a positive byte override":
    const Key = "REPROBUILD_RUNQUOTA_MEMORY_BYTES"
    let previous = getEnv(Key)
    let wasPresent = existsEnv(Key)
    defer:
      if wasPresent:
        putEnv(Key, previous)
      else:
        delEnv(Key)

    delEnv(Key)
    check autoRunQuotaMemoryBytes() == DefaultAutoRunQuotaMemoryBytes
    putEnv(Key, "68719476736")
    check autoRunQuotaMemoryBytes() == 68719476736'u64
    for invalid in ["0", "not-a-number"]:
      putEnv(Key, invalid)
      expect ValueError:
        discard autoRunQuotaMemoryBytes()

  test "daemon and runquota isolation is forwarded to nested daemon-hosted builds":
    let keys = [
      "REPRO_DAEMON_ENDPOINT",
      "REPRO_DAEMON_STATE_DIR",
      "REPRO_DAEMON_RUNTIME_DIR",
      "RUNQUOTAD_BIN",
      "RUNQUOTA_BIN",
      "REPROBUILD_RUNQUOTA_MEMORY_BYTES",
      "STACKABLE_HOOKS_SRC",
      "CLINGO_PREFIX",
      "REPROBUILD_RUNTIME_LIBRARY_PATH",
      "SHM_QUEUE_SRC"
    ]
    var previous: seq[tuple[key: string; value: string; present: bool]]
    for key in keys:
      previous.add((key: key, value: getEnv(key), present: existsEnv(key)))
    defer:
      for item in previous:
        if item.present:
          putEnv(item.key, item.value)
        else:
          delEnv(item.key)

    let endpoint = getTempDir() / "repro-daemon-carried-env.sock"
    let stateDir = getTempDir() / "repro-daemon-carried-env-state"
    let runtimeDir = getTempDir() / "repro-daemon-carried-env-runtime"
    let runquotadBin = getTempDir() / "runquotad-carried-env"
    let runquotaBin = getTempDir() / "runquota-carried-env"
    let runquotaMemoryBytes = "68719476736"
    let stackableHooksSrc = getTempDir() / "stackable-hooks-src-carried-env"
    let clingoPrefix = getTempDir() / "clingo-prefix-carried-env"
    let runtimeLibraryPath = getTempDir() / "runtime-libraries-carried-env"
    let shmQueueSrc = getTempDir() / "shm-queue-src-carried-env"
    putEnv("REPRO_DAEMON_ENDPOINT", endpoint)
    putEnv("REPRO_DAEMON_STATE_DIR", stateDir)
    putEnv("REPRO_DAEMON_RUNTIME_DIR", runtimeDir)
    putEnv("RUNQUOTAD_BIN", runquotadBin)
    putEnv("RUNQUOTA_BIN", runquotaBin)
    putEnv("REPROBUILD_RUNQUOTA_MEMORY_BYTES", runquotaMemoryBytes)
    putEnv("STACKABLE_HOOKS_SRC", stackableHooksSrc)
    putEnv("CLINGO_PREFIX", clingoPrefix)
    putEnv("REPROBUILD_RUNTIME_LIBRARY_PATH", runtimeLibraryPath)
    putEnv("SHM_QUEUE_SRC", shmQueueSrc)

    let carried = daemonCarriedEnvironment()
    check carried.hasEnvPair("REPRO_DAEMON_ENDPOINT", endpoint)
    check carried.hasEnvPair("REPRO_DAEMON_STATE_DIR", stateDir)
    check carried.hasEnvPair("REPRO_DAEMON_RUNTIME_DIR", runtimeDir)
    check carried.hasEnvPair("RUNQUOTAD_BIN", runquotadBin)
    check carried.hasEnvPair("RUNQUOTA_BIN", runquotaBin)
    check carried.hasEnvPair("REPROBUILD_RUNQUOTA_MEMORY_BYTES",
      runquotaMemoryBytes)
    check carried.hasEnvPair("STACKABLE_HOOKS_SRC", stackableHooksSrc)
    check carried.hasEnvPair("CLINGO_PREFIX", clingoPrefix)
    check carried.hasEnvPair("REPROBUILD_RUNTIME_LIBRARY_PATH",
      runtimeLibraryPath)
    check carried.hasEnvPair("SHM_QUEUE_SRC", shmQueueSrc)

  test "source provisioning and cache configuration follow daemon-hosted builds":
    let settings = [
      ("REPROBUILD_REPO_ROOT", "/workspace/reprobuild-repo"),
      ("REPROBUILD_SRC", "/workspace/reprobuild"),
      ("REPROBUILD_PACKAGES_ROOT", "/workspace/reprobuild-packages"),
      ("REPROBUILD_NIX_DAEMON_BIN", "/workspace/reprobuild-nix-daemon"),
      ("REPRO_CACHES_CONFIG", "/home/test/.config/repro/caches.conf"),
      ("REPRO_BINARY_CACHE_URL", "https://cache.example.invalid"),
      ("REPRO_BINARY_CACHE_KEY_PATH", "/home/test/.config/repro/publisher.key"),
      ("REPRO_BINARY_CACHE_CERT_PATH", "/home/test/.config/repro/publisher.cert"),
      ("REPRO_BINARY_CACHE_SCOPE", "release"),
    ]
    var previous: seq[tuple[key: string; value: string; present: bool]]
    for (key, value) in settings:
      previous.add((key: key, value: getEnv(key), present: existsEnv(key)))
      putEnv(key, value)
    defer:
      for item in previous:
        if item.present:
          putEnv(item.key, item.value)
        else:
          delEnv(item.key)

    let carried = daemonCarriedEnvironment()
    for (key, value) in settings:
      check carried.hasEnvPair(key, value)

  test "project-defined action passthroughs follow daemon-hosted builds":
    const settings = [
      ("REPRO_E2E_CUSTOM_ACTION_STATE_DIR", "/tmp/custom-action-state"),
      ("GUI_ASSERT_ROOT", "/workspace/gui-assert"),
    ]
    var previous: seq[tuple[key: string; value: string; present: bool]]
    for (key, value) in settings:
      previous.add((key: key, value: getEnv(key), present: existsEnv(key)))
      putEnv(key, value)
    defer:
      for item in previous:
        if item.present:
          putEnv(item.key, item.value)
        else:
          delEnv(item.key)

    let carried = daemonCarriedEnvironment()
    for (key, value) in settings:
      check carried.hasEnvPair(key, value)

  test "private runner ownership is excluded without changing unrelated env":
    const
      OwnerTokenEnv = "REPRO_TEST_RUNNER_OWNER_TOKEN"
      OwnerToken = "private-owner-value-that-must-not-cross-the-wire"
    let input = @[
      "PATH=/first",
      OwnerTokenEnv & "=" & OwnerToken,
      "MALFORMED_UNRELATED",
      "REPRO_TEST_RUNNER_OWNER_TOKEN_SUFFIX=preserved",
      "VALUE_CONTAINS=" & OwnerTokenEnv & "=" & OwnerToken,
      OwnerTokenEnv,
      "PATH=/second",
    ]
    let expected = @[
      "PATH=/first",
      "MALFORMED_UNRELATED",
      "REPRO_TEST_RUNNER_OWNER_TOKEN_SUFFIX=preserved",
      "VALUE_CONTAINS=" & OwnerTokenEnv & "=" & OwnerToken,
      "PATH=/second",
    ]
    check sanitizeUserDaemonRequestEnvironment(input) == expected

  test "caller environment snapshot excludes private runner ownership":
    const
      OwnerTokenEnv = "REPRO_TEST_RUNNER_OWNER_TOKEN"
      OwnerToken = "caller-owner-value-that-must-not-enter-a-request"
    let hadOwnerToken = existsEnv(OwnerTokenEnv)
    let priorOwnerToken = getEnv(OwnerTokenEnv)
    defer:
      if hadOwnerToken:
        putEnv(OwnerTokenEnv, priorOwnerToken)
      else:
        delEnv(OwnerTokenEnv)

    putEnv(OwnerTokenEnv, OwnerToken)
    let carried = daemonCarriedEnvironment()
    check not carried.hasEnvPair(OwnerTokenEnv, OwnerToken)
    check carried.allIt(not it.startsWith(OwnerTokenEnv & "="))

  test "build and watch wire codecs exclude private runner ownership":
    const
      OwnerTokenEnv = "REPRO_TEST_RUNNER_OWNER_TOKEN"
      OwnerToken = "wire-owner-value-that-must-not-be-serialized"
    let environment = @[
      "PATH=/daemon-actions",
      OwnerTokenEnv & "=" & OwnerToken,
      "HOME=/daemon-home",
    ]
    let expected = @["PATH=/daemon-actions", "HOME=/daemon-home"]

    let buildBody = buildRequestBody(UserDaemonBuildRequest(
      runId: "build-owner-filter",
      target: ".",
      environment: environment,
      attached: true,
      cancelOnDisconnect: true))
    check OwnerToken notin cast[string](buildBody)
    check OwnerTokenEnv notin cast[string](buildBody)
    check parseBuildRequestBody(buildBody).environment == expected

    let watchBody = watchRequestBody(UserDaemonWatchRequest(
      runId: "watch-owner-filter",
      target: ".",
      environment: environment,
      attached: true,
      cancelOnDisconnect: true))
    check OwnerToken notin cast[string](watchBody)
    check OwnerTokenEnv notin cast[string](watchBody)
    check parseWatchRequestBody(watchBody).environment == expected

  test "build and watch decoders reject a private marker from hostile wire":
    const
      OwnerTokenEnv = "REPRO_TEST_RUNNER_OWNER_TOKEN"
      LookalikeEnv = "REPRO_TEST_RUNNER_OWNER_TOKEO"
    let expected = @["PATH=/daemon-actions", "HOME=/daemon-home"]
    let hostileEnvironment = @[
      "PATH=/daemon-actions",
      LookalikeEnv & "=hostile-wire-owner-value",
      "HOME=/daemon-home",
    ]

    var buildBody = buildRequestBody(UserDaemonBuildRequest(
      runId: "hostile-build-owner-filter",
      environment: hostileEnvironment))
    check buildBody.replaceAscii(LookalikeEnv, OwnerTokenEnv)
    check parseBuildRequestBody(buildBody).environment == expected

    var watchBody = watchRequestBody(UserDaemonWatchRequest(
      runId: "hostile-watch-owner-filter",
      environment: hostileEnvironment))
    check watchBody.replaceAscii(LookalikeEnv, OwnerTokenEnv)
    check parseWatchRequestBody(watchBody).environment == expected
