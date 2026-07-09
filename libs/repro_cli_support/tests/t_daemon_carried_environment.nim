import std/[os, unittest]

import repro_cli_support

proc hasEnvPair(values: openArray[string]; key, value: string): bool =
  let expected = key & "=" & value
  for item in values:
    if item == expected:
      return true
  false

suite "daemon carried environment":
  test "daemon and runquota isolation is forwarded to nested daemon-hosted builds":
    let keys = [
      "REPRO_DAEMON_ENDPOINT",
      "REPRO_DAEMON_STATE_DIR",
      "REPRO_DAEMON_RUNTIME_DIR",
      "RUNQUOTAD_BIN",
      "RUNQUOTA_BIN",
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
    let shmQueueSrc = getTempDir() / "shm-queue-src-carried-env"
    putEnv("REPRO_DAEMON_ENDPOINT", endpoint)
    putEnv("REPRO_DAEMON_STATE_DIR", stateDir)
    putEnv("REPRO_DAEMON_RUNTIME_DIR", runtimeDir)
    putEnv("RUNQUOTAD_BIN", runquotadBin)
    putEnv("RUNQUOTA_BIN", runquotaBin)
    putEnv("SHM_QUEUE_SRC", shmQueueSrc)

    let carried = daemonCarriedEnvironment()
    check carried.hasEnvPair("REPRO_DAEMON_ENDPOINT", endpoint)
    check carried.hasEnvPair("REPRO_DAEMON_STATE_DIR", stateDir)
    check carried.hasEnvPair("REPRO_DAEMON_RUNTIME_DIR", runtimeDir)
    check carried.hasEnvPair("RUNQUOTAD_BIN", runquotadBin)
    check carried.hasEnvPair("RUNQUOTA_BIN", runquotaBin)
    check carried.hasEnvPair("SHM_QUEUE_SRC", shmQueueSrc)
