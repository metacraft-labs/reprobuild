import std/[options, os, osproc, sequtils, strutils, unittest]

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
    # Unset means NO budget from reprobuild: the daemon's own default
    # (a share of physical memory) or the host file decides.
    check autoRunQuotaMemoryBytes().isNone
    putEnv(Key, "68719476736")
    check autoRunQuotaMemoryBytes() == some(68719476736'u64)
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
      "RUNQUOTA_SOCKET",
      "RUNQUOTA_ENDPOINT_SCOPE",
      "REPROBUILD_RUNQUOTA_MEMORY_BYTES",
      "STACKABLE_HOOKS_SRC",
      "CLINGO_PREFIX",
      "REPROBUILD_RUNTIME_LIBRARY_PATH",
      "SHM_QUEUE_SRC",
      "CLI_SPEC_SRC",
      "CONFUTILS_SRC",
      "TEST_CERTIFICATES_TOOLS_SRC"
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
    let cliSpecSrc = getTempDir() / "cli-spec-src-carried-env"
    let confutilsSrc = getTempDir() / "confutils-src-carried-env"
    let testCertificatesToolsSrc = getTempDir() / "test-certificates-tools-carried-env"
    putEnv("REPRO_DAEMON_ENDPOINT", endpoint)
    putEnv("REPRO_DAEMON_STATE_DIR", stateDir)
    putEnv("REPRO_DAEMON_RUNTIME_DIR", runtimeDir)
    putEnv("RUNQUOTAD_BIN", runquotadBin)
    putEnv("RUNQUOTA_BIN", runquotaBin)
    putEnv("RUNQUOTA_SOCKET", getTempDir() / "private-invocation.sock")
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
    putEnv("REPROBUILD_RUNQUOTA_MEMORY_BYTES", runquotaMemoryBytes)
    putEnv("STACKABLE_HOOKS_SRC", stackableHooksSrc)
    putEnv("CLINGO_PREFIX", clingoPrefix)
    putEnv("REPROBUILD_RUNTIME_LIBRARY_PATH", runtimeLibraryPath)
    putEnv("SHM_QUEUE_SRC", shmQueueSrc)
    putEnv("CLI_SPEC_SRC", cliSpecSrc)
    putEnv("CONFUTILS_SRC", confutilsSrc)
    putEnv("TEST_CERTIFICATES_TOOLS_SRC", testCertificatesToolsSrc)

    let carried = daemonCarriedEnvironment()
    check carried.hasEnvPair("REPRO_DAEMON_ENDPOINT", endpoint)
    check carried.hasEnvPair("REPRO_DAEMON_STATE_DIR", stateDir)
    check carried.hasEnvPair("REPRO_DAEMON_RUNTIME_DIR", runtimeDir)
    check carried.hasEnvPair("RUNQUOTAD_BIN", runquotadBin)
    check carried.hasEnvPair("RUNQUOTA_BIN", runquotaBin)
    check carried.hasEnvPair("RUNQUOTA_SOCKET", getTempDir() / "private-invocation.sock")
    check carried.hasEnvPair("RUNQUOTA_ENDPOINT_SCOPE", "private")
    check carried.hasEnvPair("REPROBUILD_RUNQUOTA_MEMORY_BYTES",
      runquotaMemoryBytes)
    check carried.hasEnvPair("STACKABLE_HOOKS_SRC", stackableHooksSrc)
    check carried.hasEnvPair("CLINGO_PREFIX", clingoPrefix)
    check carried.hasEnvPair("REPROBUILD_RUNTIME_LIBRARY_PATH",
      runtimeLibraryPath)
    check carried.hasEnvPair("SHM_QUEUE_SRC", shmQueueSrc)
    check carried.hasEnvPair("CLI_SPEC_SRC", cliSpecSrc)
    check carried.hasEnvPair("CONFUTILS_SRC", confutilsSrc)
    check carried.hasEnvPair("TEST_CERTIFICATES_TOOLS_SRC",
      testCertificatesToolsSrc)

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
      "RUNQUOTA_SOCKET=/private/invocation.sock",
      "RUNQUOTA_ENDPOINT_SCOPE=private",
    ]
    let expected = @["PATH=/daemon-actions", "HOME=/daemon-home",
      "RUNQUOTA_SOCKET=/private/invocation.sock", "RUNQUOTA_ENDPOINT_SCOPE=private"]

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

suite "daemon request environment authority":
  # The invariant, not a duration: a daemon started with one value must honour
  # a client that sets a different value, and a client that sets NOTHING must
  # get reprobuild's default rather than whatever the daemon was started with.
  # The second half is the case an overlay could not express and therefore got
  # wrong for every variable in reprobuild's namespace.

  template withEnv(pairs: openArray[(string, string)]; body: untyped) =
    var saved: seq[tuple[key: string; value: string; present: bool]] = @[]
    for item in pairs:
      saved.add((key: item[0], value: getEnv(item[0]),
                 present: existsEnv(item[0])))
      putEnv(item[0], item[1])
    try:
      body
    finally:
      restoreDaemonRequestEnvironment(saved)

  test "a client value beats the daemon's start value":
    withEnv({"REPROBUILD_MAX_PARALLELISM": "1"}):
      check buildMaxParallelismResolved().value == 1'u32
      let saved = applyDaemonRequestEnvironment(
        @["REPROBUILD_MAX_PARALLELISM=4"])
      check buildMaxParallelismResolved().value == 4'u32
      restoreDaemonRequestEnvironment(saved)
      check buildMaxParallelismResolved().value == 1'u32

  test "a client that sets nothing gets the default, not the daemon's value":
    withEnv({"REPROBUILD_MAX_PARALLELISM": "1"}):
      check buildMaxParallelismResolved().value == 1'u32
      let saved = applyDaemonRequestEnvironment(@["PATH=" & getEnv("PATH")])
      # This is the defect: the request carries no parallelism, so the
      # daemon's 1 used to survive and serialise an unrelated client's build.
      check buildMaxParallelismResolved().value == 8'u32
      check buildMaxParallelismResolved().source == "default"
      restoreDaemonRequestEnvironment(saved)
      check buildMaxParallelismResolved().value == 1'u32

  test "the effective value reports where it came from":
    withEnv({"REPROBUILD_MAX_PARALLELISM": "3"}):
      check buildMaxParallelismResolved() ==
        (value: 3'u32, source: "REPROBUILD_MAX_PARALLELISM")
      # Provenance must follow the value across the request boundary, or the
      # reported source is the daemon's while the value is the client's --
      # a diagnostic that actively misleads. Asserted INSIDE the block that
      # sets the variable, so it can only pass if the unset happened.
      let cleared = applyDaemonRequestEnvironment(@["PATH=" & getEnv("PATH")])
      check buildMaxParallelismResolved() == (value: 8'u32, source: "default")
      restoreDaemonRequestEnvironment(cleared)
      let carried = applyDaemonRequestEnvironment(
        @["REPROBUILD_MAX_PARALLELISM=6"])
      check buildMaxParallelismResolved() ==
        (value: 6'u32, source: "REPROBUILD_MAX_PARALLELISM")
      restoreDaemonRequestEnvironment(carried)

  test "the rule covers the whole namespace, not just parallelism":
    let current = @[
      "REPROBUILD_MAX_PARALLELISM=1",
      "REPROBUILD_ACTION_CACHE_ROOT=/daemon-cache",
      "REPRO_STATS_DIR=/daemon-stats",
      "PATH=/daemon-path",
      "HOME=/daemon-home",
      "LANG=C",
    ]
    let unsets = daemonWorkerEnvUnsets(@["REPROBUILD_MAX_PARALLELISM=4"],
      current)
    # Carried by the request: left alone, the overlay installs the new value.
    check "REPROBUILD_MAX_PARALLELISM" notin unsets
    # Reprobuild's own knobs the request does not carry: unset. If parallelism
    # leaked, its neighbours leaked too.
    check "REPROBUILD_ACTION_CACHE_ROOT" in unsets
    check "REPRO_STATS_DIR" in unsets
    # Outside reprobuild's namespace: a request cannot distinguish "absent"
    # from "not forwarded", so clearing the ambient environment is not ours
    # to claim.
    check "PATH" notin unsets
    check "HOME" notin unsets
    check "LANG" notin unsets

  test "an unset is restored exactly, including having been absent":
    const Key = "REPROBUILD_ACTION_CACHE_ROOT"
    withEnv({Key: "/daemon-cache"}):
      let saved = applyDaemonRequestEnvironment(@["PATH=" & getEnv("PATH")])
      check not existsEnv(Key)
      restoreDaemonRequestEnvironment(saved)
      check getEnv(Key) == "/daemon-cache"
    delEnv(Key)
    let saved = applyDaemonRequestEnvironment(@[Key & "=/from-request"])
    check getEnv(Key) == "/from-request"
    restoreDaemonRequestEnvironment(saved)
    check not existsEnv(Key)

  test "the caller's IN_AGENT_SHELL governs the progress default, not the daemon's":
    # `IN_AGENT_SHELL` is outside reprobuild's namespace, but reprobuild reads
    # it: `configuredBuildProgressMode` falls back to quiet progress when it is
    # set, and quiet progress makes the `--log` default quiet. A daemon started
    # from an agent shell must not silence the status lines of a later caller
    # that is not in one (reprobuild-pm issue
    # 2026-10-20-daemon-worker-reads-in-agent-shell-from-the-daemon-not-the-caller).
    const Key = "IN_AGENT_SHELL"
    let current = @[Key & "=1", "PATH=/daemon-path"]
    check Key in daemonWorkerEnvUnsets(@["PATH=/client-path"], current)
    # A caller in an agent shell carries the variable; the overlay installs it.
    check Key notin daemonWorkerEnvUnsets(@[Key & "=1"], current)
    withEnv({Key: "1"}):
      let saved = applyDaemonRequestEnvironment(@["PATH=" & getEnv("PATH")])
      check not existsEnv(Key)
      restoreDaemonRequestEnvironment(saved)
      check getEnv(Key) == "1"

  test "the caller's Nix configuration governs a hosted build, not the daemon's":
    # Reprobuild reads NIX_CONFIG and the variables that locate Nix's
    # configuration files to compose every request to the shared Nix helper,
    # which runs that request's `nix` with them. A daemon started by an
    # earlier caller -- an earlier CI job on a persistent runner -- must not
    # lend its credential to a later caller that set none (reprobuild-pm issue
    # 2026-11-10-repro-daemon-nix-fetch-gets-http-401-on-a-persistent-macos-runner).
    const Key = "NIX_CONFIG"
    let current = @[Key & "=access-tokens = github.com=earlier-job",
      "XDG_CONFIG_HOME=/daemon-xdg", "PATH=/daemon-path"]
    let unsets = daemonWorkerEnvUnsets(@["PATH=/client-path"], current)
    check Key in unsets
    check "XDG_CONFIG_HOME" in unsets
    # A caller with its own value carries it; the overlay installs it.
    check Key notin daemonWorkerEnvUnsets(
      @[Key & "=!include /job/nix-access-tokens.conf"], current)
    withEnv({Key: "access-tokens = github.com=earlier-job"}):
      let saved = applyDaemonRequestEnvironment(@["PATH=" & getEnv("PATH")])
      check not existsEnv(Key)
      restoreDaemonRequestEnvironment(saved)
      check getEnv(Key) == "access-tokens = github.com=earlier-job"
      let carried = applyDaemonRequestEnvironment(
        @[Key & "=!include /job/nix-access-tokens.conf"])
      check getEnv(Key) == "!include /job/nix-access-tokens.conf"
      restoreDaemonRequestEnvironment(carried)

  test "the caller's compiler toolchain governs a hosted build, not the daemon's":
    # The cc-wrapper's inputs decide what an action compiles:
    # `NIX_HARDENING_ENABLE` containing `fortify` makes it add `-O2` and
    # `_FORTIFY_SOURCE`, and it reads that only for the roles a stdenv shell
    # activated (`NIX_CC_WRAPPER_TARGET_HOST_<triple>`). A daemon forked from a
    # `nix develop` shell must not compile a later plain-shell caller's code
    # with that shell's settings: `--daemon=off` from the caller's shell would
    # not, and the hosted build must be equivalent to it.
    const Hardening = "NIX_HARDENING_ENABLE"
    const Role = "NIX_CC_WRAPPER_TARGET_HOST_x86_64_unknown_linux_gnu"
    let current = @[Hardening & "=fortify fortify3 pic", Role & "=1",
      "NIX_CFLAGS_COMPILE=-isystem /daemon-shell/include",
      "PATH=/daemon-path", "SOME_PROJECT_SETTING=daemon"]
    let unsets = daemonWorkerEnvUnsets(@["PATH=/client-path"], current)
    check Hardening in unsets
    check Role in unsets
    check "NIX_CFLAGS_COMPILE" in unsets
    # Control: the rule is the toolchain set, not the whole environment.
    check "SOME_PROJECT_SETTING" notin unsets
    check "PATH" notin unsets
    # A caller in a dev shell carries its own values; the overlay installs them.
    check Hardening notin daemonWorkerEnvUnsets(
      @[Hardening & "=pic", Role & "=1"], current)
    check Role notin daemonWorkerEnvUnsets(
      @[Hardening & "=pic", Role & "=1"], current)
    withEnv({Hardening: "fortify fortify3 pic", Role: "1"}):
      let saved = applyDaemonRequestEnvironment(@["PATH=" & getEnv("PATH")])
      check not existsEnv(Hardening)
      check not existsEnv(Role)
      # What an action spawned now inherits: neither variable.
      let seen = execCmdEx("sh -c 'echo ${" & Hardening & "-unset}:${" &
        Role & "-unset}'")
      check seen.exitCode == 0
      check seen.output.strip == "unset:unset"
      restoreDaemonRequestEnvironment(saved)
      check getEnv(Hardening) == "fortify fortify3 pic"
      check getEnv(Role) == "1"
      let carried = applyDaemonRequestEnvironment(
        @["PATH=" & getEnv("PATH"), Hardening & "=pic"])
      check getEnv(Hardening) == "pic"
      check not existsEnv(Role)
      restoreDaemonRequestEnvironment(carried)
      check getEnv(Hardening) == "fortify fortify3 pic"

  test "a complete request is the hosted build's whole environment":
    # A daemon forked from a `nix develop` shell holds far more than the
    # cc-wrapper's inputs: `CC`, `CXX`, `PKG_CONFIG`, the pkg-config wrapper's
    # role variable, `CONFIG_SHELL`, a project's own settings. A plain-shell
    # caller of `--daemon=off` sees none of them, so a hosted build for a
    # client that sent its whole environment must not see them either.
    const PkgConfigRole =
      "NIX_PKG_CONFIG_WRAPPER_TARGET_HOST_x86_64_unknown_linux_gnu"
    let current = @["CC=gcc", "CXX=g++", "PKG_CONFIG=pkg-config",
      PkgConfigRole & "=1", "SOME_PROJECT_SETTING=daemon",
      "PATH=/daemon-path", "HOME=/home/caller"]
    let request = @["PATH=/client-path", "HOME=/home/caller"]
    let complete = daemonWorkerEnvUnsets(request, current,
      requestEnvIsComplete = true)
    for name in ["CC", "CXX", "PKG_CONFIG", PkgConfigRole,
                 "SOME_PROJECT_SETTING"]:
      check name in complete
    # Carried names are installed by the overlay, never unset.
    check "PATH" notin complete
    check "HOME" notin complete
    # Control: an incomplete request (a client before v0.2.0, which sent a
    # curated list) keeps the curated rule, so none of these is unset.
    let curated = daemonWorkerEnvUnsets(request, current)
    for name in ["CC", "CXX", "PKG_CONFIG", PkgConfigRole,
                 "SOME_PROJECT_SETTING"]:
      check name notin curated

    withEnv({"CC": "gcc", PkgConfigRole: "1",
             "SOME_PROJECT_SETTING": "daemon"}):
      # The caller's environment is the process's minus the daemon-shell names.
      var caller: seq[string]
      for key, value in envPairs():
        if key notin ["CC", PkgConfigRole, "SOME_PROJECT_SETTING"]:
          caller.add(key & "=" & value)
      let saved = applyDaemonRequestEnvironment(caller,
        requestEnvIsComplete = true)
      # What an action spawned now inherits: none of them.
      let seen = execCmdEx("sh -c 'echo ${CC-unset}:${" & PkgConfigRole &
        "-unset}:${SOME_PROJECT_SETTING-unset}'")
      check seen.exitCode == 0
      check seen.output.strip == "unset:unset:unset"
      restoreDaemonRequestEnvironment(saved)
      check getEnv("CC") == "gcc"
      check getEnv(PkgConfigRole) == "1"
      check getEnv("SOME_PROJECT_SETTING") == "daemon"

  test "both clients' requests say their environment is complete":
    # The flag travels as a trailing field. A body written by a client before
    # it ends without one and must decode as INCOMPLETE, so that client keeps
    # the curated rule rather than losing every name it never forwarded.
    let buildBody = buildRequestBody(UserDaemonBuildRequest(
      runId: "complete-env", target: ".", environment: @["PATH=/p"],
      environmentIsComplete: true, attached: true))
    check parseBuildRequestBody(buildBody).environmentIsComplete
    check not parseBuildRequestBody(
      buildBody[0 ..< buildBody.len - 1]).environmentIsComplete
    check not parseBuildRequestBody(buildRequestBody(UserDaemonBuildRequest(
      runId: "partial-env", target: ".",
      environment: @["PATH=/p"]))).environmentIsComplete
    let watchBody = watchRequestBody(UserDaemonWatchRequest(
      runId: "complete-env", target: ".", environment: @["PATH=/p"],
      environmentIsComplete: true, attached: true))
    check parseWatchRequestBody(watchBody).environmentIsComplete
    check not parseWatchRequestBody(
      watchBody[0 ..< watchBody.len - 1]).environmentIsComplete
    # The two production composers set it; a request built without it is an
    # in-process caller's partial environment.
    let cliSource = readFile(currentSourcePath().parentDir.parentDir /
      "src" / "repro_cli_support.nim")
    check cliSource.count("environmentIsComplete: true") == 2
    let thinSource = readFile(currentSourcePath().parentDir.parentDir.parentDir.parentDir /
      "apps" / "repro-client" / "repro_client.nim")
    check thinSource.count("environmentIsComplete: true") == 1
