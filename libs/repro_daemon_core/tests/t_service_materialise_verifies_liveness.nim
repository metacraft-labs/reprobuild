## Shared-Development-Services §4.5 — MATERIALISATION IS VERIFIED, NOT
## DECLARED, and the instance's output lands in a file.
##
## WHAT THIS FILE MEASURES. `applyServiceConverge` used to spawn the
## instance, close the handle and answer `ok: true` / `Materialise`
## without ever asking whether the child was still alive. A command that
## exits at once — a missing binary, a bad flag, a crash — was therefore
## reported AND REGISTERED as a running shared instance, and the output
## that would have said why went to a pipe whose read end had just been
## closed. Recorded as
## `reprobuild-pm/issues/2026-10-11-the-daemon-reports-materialise-ok-for-a-shared-instance-that-already-died.md`.
##
## The required behaviour (§4.5):
##
##   * the child's stdout and stderr go to
##     `<serviceStateRoot(storeRoot, key)>/instance-output.log`;
##   * after the spawn the daemon observes the child for a short grace
##     window, and a child that exits inside it is answered `ok: false`,
##     is NOT registered (no in-memory entry, no store record, no pid),
##     and the diagnostic names the address, the command, the exit
##     status, the log path and the tail of the log;
##   * a child still running after the window is `ok: true` exactly as
##     before — this is "did it die immediately", not a readiness probe.
##
## Both materialise paths are covered: the plain `scoMaterialise` and the
## `--replace` takeover, whose replacement is a separate spawn.
##
## THE LOG PATH IS DERIVED FROM THE SPEC, NOT FROM THE IMPLEMENTATION'S
## CONSTANT. `expectedLogPath` spells `serviceStateRoot(...) /
## "instance-output.log"` itself, so the test measures the location §4.5
## names; one case then asserts the public constant agrees with it.
##
## § TEST-DOUBLE POLICY — THERE ARE NO MOCKS, AND NONE IS NEEDED.
##
## The registry is the real `ServiceInstanceRegistry` over a real
## `StateStore` in a throwaway directory; the request goes through the
## real `applyServiceConverge`; the instances are real child processes
## started by the real materialiser, and their output is read from the
## real file on disk. The one injected function, the registry's liveness
## probe, is the real `serviceInstanceLivenessProbe()` — it is an
## injection point only because `writerLiveness` lives in this library
## and `service_registry` cannot import it (see `instance_registry.nim`'s
## header). Every long-running instance a case starts is stopped with the
## real `stopServiceInstanceProcess` in `teardown`, so a failing case
## cannot leak a `sleep` loop into the rest of the suite.

import std/[options, os, strutils, tables, times, unittest]

import repro_daemon_core
import repro_daemon_core/instance_registry
import repro_resources
import repro_resources/service_attach      # freshLiftGeneration
import repro_resources/service_identity
import repro_resources/service_registry
import repro_project_dsl                   # DslServiceDef / ServiceIdentityDef

const
  # Long enough that a dying `sh` is caught even on a loaded CI host (the
  # window ends EARLY when the child exits, so the dying cases do not pay
  # for it), and passed explicitly so the suite does not depend on the
  # production default.
  TestStartGraceMs = 2000

var caseCounter = 0

proc throwawayRoot(label: string): string =
  ## A throwaway directory, never `.repro/` and never a live state tree.
  caseCounter.inc
  result = getTempDir() / ("repro-materialise-liveness-" &
    $getCurrentProcessId() & "-" & $caseCounter & "-" & label)
  removeDir(result)
  createDir(result)

proc keyFor(root, stableId: string): ServiceInstanceKey =
  ## Through the real `serviceInstanceKey` over a real identity
  ## definition. `scope workspace` with a workspace id, so the address is
  ## the workspace-scoped one and not a degraded project-scoped one.
  serviceInstanceKey(
    DslServiceDef(packageName: "matLivePkg", serviceName: "zitadel",
      identity: ServiceIdentityDef(kind: sikStable, stableId: stableId),
      scope: sscWorkspace),
    ServiceScopeContext(projectRoot: root, workspaceRoot: root,
      workspaceId: "materialise-liveness", user: "matlivetester"),
    [], "dev")

proc snapshot(): ServiceInterfaceSnapshot =
  ServiceInterfaceSnapshot(serviceName: "zitadel",
    packageName: "matLivePkg", projectName: "matlive", activityName: "sso",
    handleType: "H", compatibilityMajor: 1, fingerprint: "f",
    projectFingerprint: "pf", members: @[])

proc expectedLogPath(storeRoot: string; key: ServiceInstanceKey): string =
  ## §4.5's location, spelled out independently of the implementation.
  serviceStateRoot(storeRoot, key) / "instance-output.log"

proc request(key: ServiceInstanceKey; holderId, workingDir: string;
             command: seq[string];
             replace = false): DaemonServiceConvergeRequest =
  ## The request the CLI sends, through the real encoders.
  DaemonServiceConvergeRequest(
    scope: dlsUser,
    keyJson: encodeServiceInstanceKey(key),
    snapshotJson: encodeServiceInterfaceSnapshot(snapshot()),
    holderId: holderId,
    ttlSeconds: -1,
    command: command,
    workingDir: workingDir,
    replace: replace,
    force: false,
    # Supplied because an absent answer refuses (§4.3); this suite is
    # about materialisation, not about the same-generation precondition.
    generationJson: encodeServiceArtifactGenerationCheck(
      freshLiftGeneration("<constructed in-process>", "matLivePkg",
        "matlive", "same-generation-by-construction")))

var spawned: seq[ServiceInstanceProcess] = @[]

proc remember(registry: ServiceInstanceRegistry) =
  ## Every process the registry names is stopped in `teardown`, whether
  ## the case passed or not.
  for address, entry in registry.entries:
    spawned.add(entry.record.process)

proc reapEverything() =
  for process in spawned:
    discard stopServiceInstanceProcess(process, graceMs = 1500)
  spawned.setLen(0)

proc assertNotRegistered(registry: ServiceInstanceRegistry;
                         storeRoot: string; key: ServiceInstanceKey) =
  ## "Not registered" in all three places it could leak: the daemon's
  ## in-memory registry, the persisted store, and a registry REBUILT from
  ## that store (which is what the next daemon would serve).
  check registry.lookupServiceInstance(key).isNone
  check not hasStateRecord(openStateStore(storeRoot),
    serviceInstanceAddress(key))
  let rebuilt = openServiceInstanceRegistry(storeRoot,
    serviceInstanceLivenessProbe())
  check rebuilt.lookupServiceInstance(key).isNone

suite "§4.5 — materialisation is verified, and the output is kept":
  teardown:
    reapEverything()

  test "a command that exits at once is refused, unregistered, and diagnosable":
    let root = throwawayRoot("dies")
    let storeRoot = root / "store"
    var registry = openServiceInstanceRegistry(storeRoot,
      serviceInstanceLivenessProbe())
    let key = keyFor(root, "com.example.matlive.dies")
    let logPath = expectedLogPath(storeRoot, key)
    let command = @["sh", "-c", "echo boom-diagnostic >&2; exit 3"]
    let response = applyServiceConverge(registry,
      request(key, "holder:dies", root, command),
      startGraceMs = TestStartGraceMs)
    registry.remember()
    checkpoint("ok=" & $response.ok & " outcome=" & response.outcome &
      " pid=" & $response.pid & "\ndiagnostic=" & response.diagnostic)
    check not response.ok
    check response.outcome == outcomeWord(scoMaterialise)
    check response.pid == 0
    # The diagnostic alone must explain the failure: the address, the
    # command, the exit status, where the output is, and what it said.
    check serviceInstanceAddress(key) in response.diagnostic
    check "exit 3" in response.diagnostic
    check "exit status 3" in response.diagnostic
    check logPath in response.diagnostic
    check "boom-diagnostic" in response.diagnostic
    # The output landed in the file §4.5 names.
    check fileExists(logPath)
    if fileExists(logPath):
      check "boom-diagnostic" in readFile(logPath)
    registry.assertNotRegistered(storeRoot, key)
    # And therefore the next converge decides MATERIALISE again, not
    # attach to the corpse.
    let again = convergeServiceInstance(registry, key, snapshot(),
      "holder:dies-again",
      freshLiftGeneration("<constructed in-process>", "matLivePkg",
        "matlive", "same-generation-by-construction"))
    check again.outcome == scoMaterialise
    check not again.hadInstance

  test "a nonexistent binary is refused, and the diagnostic says why":
    let root = throwawayRoot("missing")
    let storeRoot = root / "store"
    var registry = openServiceInstanceRegistry(storeRoot,
      serviceInstanceLivenessProbe())
    let key = keyFor(root, "com.example.matlive.missing")
    let logPath = expectedLogPath(storeRoot, key)
    let missing = "/nonexistent/definitely-not-a-binary"
    let response = applyServiceConverge(registry,
      request(key, "holder:missing", root, @[missing, "--flag"]),
      startGraceMs = TestStartGraceMs)
    registry.remember()
    checkpoint("ok=" & $response.ok & " outcome=" & response.outcome &
      "\ndiagnostic=" & response.diagnostic)
    check not response.ok
    check response.pid == 0
    check missing in response.diagnostic
    check logPath in response.diagnostic
    # The shell's own sentence for a missing command, and the exit status
    # POSIX gives it (127). Either spelling of "not found" is the shell's;
    # the test does not care which shell `/bin/sh` is.
    check "127" in response.diagnostic
    check ("not found" in response.diagnostic.toLowerAscii or
      "no such file" in response.diagnostic.toLowerAscii)
    registry.assertNotRegistered(storeRoot, key)

  test "a long-running command is materialised and its output is captured":
    let root = throwawayRoot("runs")
    let storeRoot = root / "store"
    var registry = openServiceInstanceRegistry(storeRoot,
      serviceInstanceLivenessProbe())
    let key = keyFor(root, "com.example.matlive.runs")
    let logPath = expectedLogPath(storeRoot, key)
    let response = applyServiceConverge(registry,
      request(key, "holder:runs", root,
        @["sh", "-c", "echo started; while :; do sleep 1; done"]),
      startGraceMs = TestStartGraceMs)
    registry.remember()
    checkpoint("ok=" & $response.ok & " outcome=" & response.outcome &
      "\ndiagnostic=" & response.diagnostic)
    check response.ok
    check response.outcome == outcomeWord(scoMaterialise)
    check response.pid > 0
    # The recorded pid IS the service process (the shell `exec`s it), so
    # a stop signals the right process.
    let entry = registry.lookupServiceInstance(key)
    check entry.isSome
    if entry.isSome:
      check entry.get.record.process.pid == int(response.pid)
      check serviceInstanceLivenessProbe()(
        entry.get.record.process.processIdentity) == silLive
      # Discoverable from the persisted record, not only from the reply.
      check entry.get.record.process.outputLog == logPath
    check logPath in response.diagnostic
    # `started` is written before the first `sleep`, i.e. within the
    # grace window; poll briefly anyway rather than racing the shell.
    let deadline = epochTime() + 5.0
    while epochTime() < deadline and
        not (fileExists(logPath) and "started" in readFile(logPath)):
      sleep(50)
    check fileExists(logPath)
    if fileExists(logPath):
      check "started" in readFile(logPath)
    check ServiceInstanceOutputLogName == "instance-output.log"
    check serviceInstanceOutputLogPath(storeRoot, key) == logPath
    if entry.isSome:
      check stopServiceInstanceProcess(entry.get.record.process,
        graceMs = 2000).stopped

  test "a --replace whose replacement dies is refused and leaves no record":
    let root = throwawayRoot("replace")
    let storeRoot = root / "store"
    var registry = openServiceInstanceRegistry(storeRoot,
      serviceInstanceLivenessProbe())
    let key = keyFor(root, "com.example.matlive.replace")
    let logPath = expectedLogPath(storeRoot, key)
    let holder = "holder:replace"
    let first = applyServiceConverge(registry,
      request(key, holder, root, @["sh", "-c", "while :; do sleep 1; done"]),
      startGraceMs = TestStartGraceMs)
    registry.remember()
    doAssert first.ok and first.outcome == outcomeWord(scoMaterialise),
      "fixture could not materialise the instance to replace: " &
      first.diagnostic
    let response = applyServiceConverge(registry,
      request(key, holder, root,
        @["sh", "-c", "echo replacement-boom >&2; exit 5"], replace = true),
      startGraceMs = TestStartGraceMs)
    registry.remember()
    checkpoint("ok=" & $response.ok & " outcome=" & response.outcome &
      "\ndiagnostic=" & response.diagnostic)
    # The takeover proceeded (the requester is the only holder) ...
    check response.outcome == outcomeWord(scoReplace)
    # ... and its replacement died, so it is NOT reported as running.
    check not response.ok
    check response.pid == 0
    check "exit status 5" in response.diagnostic
    check "replacement-boom" in response.diagnostic
    check logPath in response.diagnostic
    registry.assertNotRegistered(storeRoot, key)

  test "a command that daemonises itself (exit 0) is refused, and told why":
    # Exit status 0 inside the window is what a self-backgrounding command
    # looks like: the parent returns and the real server is a grandchild
    # the daemon never learns the pid of. It is still a failed
    # materialisation (§4.5), and the diagnostic must not read as a
    # success that was wrongly refused.
    let root = throwawayRoot("exit0")
    let storeRoot = root / "store"
    var registry = openServiceInstanceRegistry(storeRoot,
      serviceInstanceLivenessProbe())
    let key = keyFor(root, "com.example.matlive.exit0")
    let response = applyServiceConverge(registry,
      request(key, "holder:exit0", root,
        @["sh", "-c", "echo going-to-background; exit 0"]),
      startGraceMs = TestStartGraceMs)
    registry.remember()
    checkpoint("ok=" & $response.ok & " outcome=" & response.outcome &
      "\ndiagnostic=" & response.diagnostic)
    check not response.ok
    check response.pid == 0
    check "exit status 0" in response.diagnostic
    check "foreground" in response.diagnostic
    check "going-to-background" in response.diagnostic
    registry.assertNotRegistered(storeRoot, key)

  test "the log path and argv reach the launcher verbatim, never as shell syntax":
    # The launcher passes both positionally (`"$1"`, `"$@"`). A path or an
    # argument containing quotes, spaces, `$(...)` or `;` must arrive
    # byte-for-byte and must never be executed.
    let root = throwawayRoot("quoting")
    let canary = root / "pwned"
    let odd = "a b $(touch " & canary & ") ; `touch " & canary & "` \"q' -x"
    let logPath = root / ("log dir " & odd) / "instance-output.log"
    let start = materialiseServiceInstanceProcess(
      @["sh", "-c", "printf '<%s>\\n' \"$@\"; exit 4", "argv0", odd, "-n"],
      root, logPath, graceMs = TestStartGraceMs)
    checkpoint("exitedEarly=" & $start.exitedEarly & " exitCode=" &
      $start.exitCode)
    check start.exitedEarly
    check start.exitCode == 4
    check start.process.pid == 0
    check start.outputPath == logPath
    check fileExists(logPath)
    if fileExists(logPath):
      let text = readFile(logPath)
      check ("<" & odd & ">") in text
      check "<-n>" in text
    check not fileExists(canary)
