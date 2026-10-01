## A RunQuota daemon reprobuild starts behaves exactly as the host's
## configuration says, and ``runquota config set`` / ``reload`` reach it.
##
## THE DEFECT. Until 2026-10-01 the auto-spawn (``startAutoRunQuotaIfNeeded``)
## started ``runquotad`` with ``--cpu-milli buildMaxParallelism() * 1000``
## whenever the host file left ``cpu_milli`` unset, and with ``--pool
## compile=8 --pool fetch=2`` plus every recipe pool. A ``runquotad`` flag
## PINS its key: it overrides the host file and the daemon's own default and
## survives a reload. So on a host whose file did not set ``cpu_milli``, the
## daemon reprobuild started enforced one build's parallelism (8000 by
## default) instead of one core per logical processor, for every workspace on
## the host -- and ``runquota config set machine.cpu_milli N`` wrote the file,
## reloaded the daemon, and changed nothing. The same was true of every pool.
## (reprobuild-specs/RunQuota-Host-Configuration.md, "What the auto-spawn
## passes".)
##
## WHAT THIS RUNS. A real ``runquotad`` started with the argv the auto-spawn
## builds (``autoRunQuotaBudgetArgs`` over the host file it reads), the real
## ``runquota config`` verb, and reprobuild's own pool declaration
## (``runQuotaPoolDeclaration`` + ``declareRunQuotaPools``) over a real
## session. The only arguments added are the ones that keep the test off the
## host: a private endpoint (``--socket``, reached through ``RUNQUOTA_SOCKET``,
## which ``runquota`` honours exactly as reprobuild's own clients do), a
## private host file (``--host-config``), a scratch host identity, and no
## observation capture or pressure sampling. Nothing here talks to the host's
## daemon or reads its ``runquotad.toml``.
##
## WHY NOT ``startAutoRunQuotaIfNeeded`` ITSELF. On Windows it binds the fixed
## host-wide pipe, which the host's own daemon already serves, and it reads the
## host's real file; driving it would either adopt that daemon or reconfigure
## the host. The budget argv is the whole of what it decides about the budget,
## and that is what is started here.
##
## FALSIFIABILITY. Put ``--cpu-milli`` back into ``autoRunQuotaBudgetArgs``
## for a file without ``cpu_milli`` and the first case fails: the budget in
## force stays at the flag after ``config set machine.cpu_milli``, and the
## reload reports ``machine.cpu_milli`` pinned. Put ``--pool compile=8`` back
## and the pool case fails the same way.
##
## NO MOCKS.

import std/[cpuinfo, json, options, os, osproc, streams, strutils, unittest]

import repro_build_engine
import repro_cli_support
import repro_runquota
import repro_test_support
import runquota_client
import runquota_daemon/host_config

const GiB = 1024'u64 * 1024'u64 * 1024'u64

type
  Fixture = object
    root: string
    socket: string
    hostFile: string
    daemon: Process

proc startAutoSpawnedShape(repoRoot, tag, hostText: string): Fixture =
  result.root = getTempDir() / ("repro-rq-autospawn-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(result.root)
  createDir(result.root)
  result.hostFile = result.root / "runquotad.toml"
  writeFile(result.hostFile,
    "schema = \"runquota.host-config.v1\"\n" & hostText)
  result.socket = runquotaSocketEndpoint("repro-rq-autospawn-" & tag & "-" &
    $getCurrentProcessId())
  if fileExists(result.socket):
    removeFile(result.socket)
  # The production budget argv, over the file this daemon will read.
  let budget = autoRunQuotaBudgetArgs(readHostConfig(result.hostFile))
  var args = @["--socket", result.socket, "--host-config", result.hostFile,
    "--host-identity-file", result.root / "host-id",
    "--no-write-stats", "--ambient-sample-interval-millis", "0",
    "--memory-pressure-source", "unavailable"]
  args.add(budget.args)
  putEnv("RUNQUOTA_SOCKET", result.socket)
  result.daemon = startProcess(requireRunQuotaDaemonBin(repoRoot),
    args = args, options = {poUsePath, poParentStreams})
  for _ in 0 ..< 400:
    if isRunQuotaDaemonReachable():
      return
    sleep(25)
  raise newException(OSError, "runquotad did not become reachable at " &
    result.socket)

proc stop(fixture: var Fixture) =
  if fixture.daemon != nil:
    if fixture.daemon.running:
      fixture.daemon.terminate()
      discard fixture.daemon.waitForExit(5000)
    fixture.daemon.close()
    fixture.daemon = nil
  delEnv("RUNQUOTA_SOCKET")
  removeDir(fixture.root)

proc topology(): JsonNode =
  var client = runquota_client.connectDefault()
  defer: client.close()
  parseJson(client.inspectionJson("topology"))

proc localMachine(): JsonNode =
  for machine in topology()["machines"]:
    if machine["id"].getStr == "local":
      return machine
  raise newException(KeyError, "no local machine in topology")

proc poolInForce(name: string): Option[tuple[units: int; source: string]] =
  for pool in topology()["pools"]:
    if pool["name"].getStr == name:
      return some((units: pool["units"].getInt,
        source: pool{"source"}.getStr))
  none(tuple[units: int; source: string])

proc pinnedKeys(): seq[string] =
  for key in topology()["host_config"]["pinned_by_flags"]:
    result.add(key.getStr)

proc runquotaCli(repoRoot: string; args: varargs[string]):
    tuple[output: string; code: int] =
  var argv: seq[string] = @[]
  for arg in args:
    argv.add(arg)
  # An argv, not a command string: nothing here goes through a shell.
  var process = startProcess(requireRunQuotaCliBin(repoRoot), args = argv,
    options = {poStdErrToStdOut})
  let output = process.outputStream.readAll()
  let code = process.waitForExit()
  process.close()
  checkpoint("runquota " & argv.join(" ") & " -> " & $code & "\n" & output)
  (output: output, code: code)

suite "a runquotad reprobuild starts follows the host configuration":
  let repoRoot = getCurrentDir()
  let defaultCpu = max(1, countProcessors()) * 1000

  test "no cpu_milli in the host file: config set + reload changes the CPU budget":
    var fixture = startAutoSpawnedShape(repoRoot, "cpu", "")
    defer: fixture.stop()
    # The daemon's own default -- one core per logical processor -- and not
    # the build's parallelism.
    check localMachine()["cpu_milli"].getInt == defaultCpu
    check pinnedKeys().len == 0
    let set = runquotaCli(repoRoot, "config", "set", "machine.cpu_milli",
      "3000", "--file", fixture.hostFile)
    check set.code == 0
    check "runquotad reloaded its host configuration" in set.output
    check "cpu_milli = 3000" in set.output
    check "pinned" notin set.output
    check localMachine()["cpu_milli"].getInt == 3000
    # And back: unset returns the key to the daemon's default.
    let unset = runquotaCli(repoRoot, "config", "unset", "machine.cpu_milli",
      "--file", fixture.hostFile)
    check unset.code == 0
    check localMachine()["cpu_milli"].getInt == defaultCpu

  test "no memory_bytes in the host file: config set + reload changes the memory budget":
    var fixture = startAutoSpawnedShape(repoRoot, "memory", "")
    defer: fixture.stop()
    let set = runquotaCli(repoRoot, "config", "set", "machine.memory_bytes",
      "5GiB", "--file", fixture.hostFile)
    check set.code == 0
    check localMachine()["memory_bytes"].getBiggestInt ==
      int64(5'u64 * GiB)

  test "the build's pools are declared, under the host file, and leave with it":
    var fixture = startAutoSpawnedShape(repoRoot, "pools", "")
    defer: fixture.stop()
    # No pool exists until a build declares one: the daemon was started with
    # no --pool flag, exactly as the installed service is.
    check poolInForce("compile").isNone
    let declaration = runQuotaPoolDeclaration(
      [pool("rq-test.serial", 1'u32)],
      [BuildAction(id: "cc", pool: "compile", poolUnits: 1'u32),
       BuildAction(id: "t", pool: "rq-test.serial", poolUnits: 1'u32)],
      12'u32)
    var session = openRunQuotaSession("reprobuild test", "0.1.0")
    let declared = declareRunQuotaPools(session, declaration)
    check declared.supported
    check declared.pools.len == 2
    check poolInForce("compile") == some((units: 8, source: "declared"))
    check poolInForce("rq-test.serial") == some((units: 1, source: "declared"))
    # The operator's file wins, by reload, and pins nothing ...
    let set = runquotaCli(repoRoot, "config", "set", "pools.compile", "4",
      "--file", fixture.hostFile)
    check set.code == 0
    check "pinned" notin set.output
    check poolInForce("compile") == some((units: 4, source: "host-file"))
    # ... and unset gives the pool back to what the build declared.
    let unset = runquotaCli(repoRoot, "config", "unset", "pools.compile",
      "--file", fixture.hostFile)
    check unset.code == 0
    check poolInForce("compile") == some((units: 8, source: "declared"))
    session.close()
    check poolInForce("compile").isNone
    check poolInForce("rq-test.serial").isNone

  test "the memory override is the one flag, and the daemon reports it pinned":
    let key = "REPROBUILD_RUNQUOTA_MEMORY_BYTES"
    putEnv(key, $(3'u64 * GiB))
    defer: delEnv(key)
    var fixture = startAutoSpawnedShape(repoRoot, "override", "")
    defer: fixture.stop()
    check localMachine()["memory_bytes"].getBiggestInt ==
      int64(3'u64 * GiB)
    check pinnedKeys() == @["machine.memory_bytes"]
    let set = runquotaCli(repoRoot, "config", "set", "machine.memory_bytes",
      "5GiB", "--file", fixture.hostFile)
    check set.code == 0
    check "pinned by runquotad flags" in set.output
    check localMachine()["memory_bytes"].getBiggestInt ==
      int64(3'u64 * GiB)
    # A command that finds this daemon already running cannot apply another
    # figure, and says so instead of being silently ignored.
    putEnv(key, $(7'u64 * GiB))
    let ignored = autoRunQuotaMemoryOverrideNotApplied(
      runQuotaDaemonMemoryBudget())
    check ignored.len == 1
    check $(3'u64 * GiB) in ignored[0]
