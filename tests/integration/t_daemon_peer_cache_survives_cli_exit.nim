## Distributed-Execution M0 Catch #3: the peer cache lives in `repro-daemon`,
## so what a build published stays servable after the CLI that ran the build
## has exited.
##
## Two REAL daemon processes (`repro daemon serve --foreground
## --peer-cache=lan://…`), each with its own endpoint, state directory and
## action-cache root, serve two checkouts of the same project at different
## roots:
##
##   1. Daemon A starts with the peer cache enabled (seed-only, TLS with its
##      own host CA, loopback CIDR) and binds its peer-cache server on the
##      interface its policy declares — loopback, as no `bind=` is given.
##      Since Distributed-Execution M7 it never binds a wildcard (FLOW-6),
##      and the memoization plane needs authenticated, attested peers.
##   2. `repro build ws-a --daemon=require` runs THROUGH daemon A (the build
##      executes in A's forked worker, which publishes the two-phase memo
##      entry and output blobs into ws-a's action-cache root and registers
##      that root with A). The CLI process EXITS.
##   3. Daemon B starts seeded with A's peer-cache endpoint.
##   4. `repro build ws-b --daemon=require` runs through daemon B. Its local
##      cache is empty; its worker performs the two-phase lookup against
##      daemon A's still-running server, restores the artifact into ws-b and
##      does not execute the action.
##
## Evidence that the bytes came from daemon A after A's CLI was gone: the
## producer CLI's `execCmd` had returned before B even started; A's own
## peer-cache status file counts the memo requests and blob fetches it
## served; B's build report says the action was not launched; the artifact
## in ws-b carries ws-a's content; B's memo store now holds A's selector.
##
## Where io-mon cannot prove detached-descendant quiescence
## (`NoTreeLifetimeGuard`: macOS; Windows too before io-mon 4d468bc), every
## monitored capture fails closed and the engine never publishes a monitored
## edge (io-mon's normative platform limitation, upstream `7c606dbb2`).
## There the action gathers its evidence from a make depfile it writes
## instead — still a real, read-back report of what it consumed — so the
## publish, the daemon-hosted serving and the remote hit are exercised on
## every OS. On Linux it stays a monitored edge,
## which also covers the `mkdir -p build` probe described below.
##
## MOCK POLICY — none: real `repro` binaries, real daemons, real sockets,
## real TLS with per-daemon host CAs pinned by each other, real project
## builds, real disk stores. Multicast is turned off
## (`multicast=0`) so concurrent suite runs on this host cannot discover
## each other's daemons; discovery is by explicit seed, which is the
## spec's unicast mode (`Peer-Cache.md` §"Discovery model").

import std/[json, os, osproc, streams, strtabs, strutils, tables, tempfiles,
            times, unittest]

import repro_test_support
import repro_test_support/descendant_guard_expectations

import ../../libs/repro_peer_cache/tests/m7_test_pki

const
  ActionId = "m0-peer-cache-artifact"
  InputText = "artifact input from the producer checkout\n"

type AssertionFailure = object of CatchableError

template ensure(cond: bool) =
  ## `require` without its `quit`: unittest's `require` exits the process on
  ## failure, which skips the `defer` that stops the processes this test
  ## started. Raising instead fails the test AND runs the cleanup.
  let ok = cond
  check ok
  if not ok:
    raise newException(AssertionFailure, "precondition failed: " & astToStr(cond))

proc repoRoot(): string =
  getCurrentDir()

proc publicReproBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)

type
  DaemonNode = object
    name: string
    root: string
    endpoint: string
    stateDir: string
    logPath: string
    cacheRoot: string
    pki: TestNode
    process: Process

proc nimString(value: string): string =
  value.escape()

proc writeProject(projectRoot: string) =
  ## A one-action project: `sh -c` copies `input.txt` into a declared
  ## output. Cacheable, so the action-cache record (and its peer-cache
  ## publication) exists.
  ##
  ## The action CREATES the directory its output goes into (`mkdir -p`), and
  ## the shell probes it first. That probe used to be recorded with the
  ## directory's post-run state, so a fresh checkout could never match the
  ## producer's selector (reprobuild-pm issue
  ## 2026-10-16-action-created-directories-recorded-as-post-run-inputs);
  ## the consumer checkout here has no `build/` until the hit restores it.
  ##
  ## Without a tree-lifetime guard (see the module doc) the action also
  ## writes a make depfile naming its input, named as its depfile, so its
  ## evidence is that report rather than a capture that always fails closed.
  createDir(projectRoot)
  writeFile(projectRoot / "input.txt", InputText)
  let script = "set -eu\nmkdir -p build\ncat input.txt > build/artifact.txt\n" &
    (if NoTreeLifetimeGuard:
       "printf 'build/artifact.txt: input.txt\\n' > build/artifact.d\n"
     else: "")
  let depfileArg =
    if NoTreeLifetimeGuard: "        depfile = \"build/artifact.d\",\n"
    else: ""
  writeFile(projectRoot / "reprobuild.nim",
    "import repro_project_dsl\n\n" &
    "package daemonPeerCacheM0:\n" &
    "  uses:\n" &
    "    \"sh >=1\"\n\n" &
    "  executable shTool:\n" &
    "    name \"sh\"\n" &
    "    cli:\n" &
    "      subcmd \"-c\":\n" &
    "        pos args, seq[string], position = 0\n\n" &
    "    build:\n" &
    "      let action = buildAction(" & nimString(ActionId) & ",\n" &
    "        daemonPeerCacheM0.executable(\"sh\").subcmd_2d_c(\n" &
    "          args = @[" & nimString(script) & ", " & nimString("sh") &
      "]),\n" &
    "        inputs = @[\"input.txt\"],\n" &
    "        outputs = @[\"build/artifact.txt\"],\n" &
    depfileArg &
    "        cacheable = true)\n" &
    "      defaultBuildAction(action)\n")

proc newNode(base, name: string): DaemonNode =
  result.name = name
  result.root = base / name
  result.endpoint = daemonSocketEndpoint("repro-m0-pc-" & name & "-" &
    $getCurrentProcessId())
  result.stateDir = result.root / "state"
  result.logPath = result.stateDir / "logs" / "repro-daemon.log"
  result.cacheRoot = result.root / "action-cache"
  createDir(result.stateDir)
  createDir(result.cacheRoot)
  result.pki = newTestNode(base, name)

proc nodeEnv(node: DaemonNode): seq[(string, string)] =
  result = @[
    ("REPRO_DAEMON_ENDPOINT", node.endpoint),
    ("REPRO_DAEMON_STATE_DIR", node.stateDir),
    ("REPROBUILD_ACTION_CACHE_ROOT", node.cacheRoot),
    ("REPROBUILD_STORE_ROOT", node.root / "store"),
    ("REPRO_PORTABLE_CACHE", "1"),
    # `?tls=1` reads the host CA and anchors from here.
    ("XDG_STATE_HOME", node.pki.xdgState)
  ]
  # The recipe compile needs a Nim compiler; reprobuild does not fall back
  # to PATH on its own (Distribution-And-Packaging M5 rule 2), so name the
  # dev shell's one explicitly, as the other provider-compiling
  # integration tests do.
  if getEnv("REPRO_NIM_COMPILER").len == 0 and findExe("nim").len > 0:
    result.add(("REPRO_NIM_COMPILER", findExe("nim")))

proc daemonLog(node: DaemonNode): string =
  if fileExists(node.logPath): readFile(node.logPath)
  else: "(no daemon log at " & node.logPath & ")"

proc readKeyValues(path: string): Table[string, string] =
  result = initTable[string, string]()
  if not fileExists(path):
    return
  for line in readFile(path).splitLines():
    let eq = line.find('=')
    if eq > 0:
      result[line[0 ..< eq]] = line[eq + 1 .. ^1]

proc status(node: DaemonNode): Table[string, string] =
  readKeyValues(node.stateDir / "peer-cache.status")

proc statusInt(node: DaemonNode; key: string): int =
  try: parseInt(node.status().getOrDefault(key, "0")) except ValueError: 0

proc peerCachePort(node: DaemonNode): int =
  let path = node.stateDir / "peer-cache-endpoint"
  if not fileExists(path):
    return 0
  let text = readFile(path).strip()
  let colon = text.rfind(':')
  if colon < 0:
    return 0
  try: parseInt(text[colon + 1 .. ^1]) except ValueError: 0

proc startDaemon(node: var DaemonNode; peerCacheSpec: string) =
  try: removeFile(node.endpoint) except OSError: discard
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  for (key, value) in nodeEnv(node):
    env[key] = value
  node.process = startProcess(publicReproBin(),
    args = @["daemon", "serve", "--foreground",
             "--endpoint", node.endpoint,
             "--state-dir", node.stateDir,
             "--log", node.logPath,
             "--peer-cache", peerCacheSpec],
    workingDir = repoRoot(), env = env,
    options = {poUsePath, poStdErrToStdOut})
  let deadline = epochTime() + 90.0
  while epochTime() < deadline:
    if node.peerCachePort() > 0:
      return
    if not node.process.running:
      break
    sleep(50)
  checkpoint(node.name & " daemon log:\n" & node.daemonLog())
  raise newException(IOError, "daemon " & node.name &
    " did not start its peer cache")

proc stopDaemon(node: var DaemonNode) =
  if node.process.isNil:
    return
  discard runShell(shellCommand(@[publicReproBin(), "daemon", "stop",
    "--endpoint", node.endpoint, "--state-dir", node.stateDir,
    "--log", node.logPath], nodeEnv(node)), repoRoot())
  let deadline = epochTime() + 20.0
  while node.process.running and epochTime() < deadline:
    sleep(50)
  if node.process.running:
    node.process.terminate()
  discard node.process.waitForExit()
  node.process.close()
  node.process = nil
  try: removeFile(node.endpoint) except OSError: discard

proc buildThroughDaemon(node: DaemonNode; projectRoot: string): CmdResult =
  runShell(shellCommand(@[
    publicReproBin(), "build", projectRoot,
    "--daemon=require",
    "--tool-provisioning=path",
    "--action-cache-root=" & node.cacheRoot,
    "--progress=quiet",
    "--log=summary",
    "--write-report"
  ], nodeEnv(node)), repoRoot())

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()

proc actionReport(output: string): JsonNode =
  let reportPath = valueAfter(output, "buildReport:")
  if reportPath.len == 0 or not fileExists(reportPath):
    return nil
  for action in parseFile(reportPath){"actions"}.getElems():
    if action{"id"}.getStr() == ActionId:
      return action
  nil

proc memoEntries(cacheRoot: string): seq[string] =
  let base = cacheRoot / "peer-memo" / "v1"
  if not dirExists(base):
    return @[]
  for path in walkDirRec(base):
    if path.endsWith(".rpme"):
      result.add(path.extractFilename)

suite "Distributed-Execution M0: daemon-hosted peer cache":

  test "t_daemon_peer_cache_survives_cli_exit":
    let base = createTempDir("repro-m0-daemon-pc-", "")
    var nodeA = newNode(base, "a")
    var nodeB = newNode(base, "b")
    let wsA = base / "ws-a"
    let wsB = base / "ws-b"
    writeProject(wsA)
    writeProject(wsB)
    mutualTrust([nodeA.pki, nodeB.pki])
    defer:
      stopDaemon(nodeB)
      stopDaemon(nodeA)
      removeDir(base)

    # 1. Daemon A, peer cache on, no seeds.
    startDaemon(nodeA, "lan://127.0.0.0/8?multicast=0&tls=1")
    let portA = nodeA.peerCachePort()
    check portA > 0
    # The declared interface — loopback — and never a wildcard.
    check readFile(nodeA.stateDir / "peer-cache-endpoint").startsWith(
      "127.0.0.1:")

    # 2. The producer build runs through daemon A, then its CLI exits.
    let producer = buildThroughDaemon(nodeA, wsA)
    checkpoint("producer build:\n" & producer.output)
    if producer.code != 0:
      checkpoint("daemon A log:\n" & nodeA.daemonLog())
    ensure producer.code == 0
    check readFile(wsA / "build" / "artifact.txt") == InputText
    let producerAction = actionReport(producer.output)
    ensure not producerAction.isNil
    check producerAction{"launched"}.getBool()
    # The worker published into ws-a's action-cache root.
    let publishedA = memoEntries(nodeA.cacheRoot)
    check publishedA.len >= 1
    # The producer CLI has exited (runShell waited for it); daemon A has not.
    check nodeA.process.running

    # 3. Daemon B, seeded with A.
    startDaemon(nodeB,
      "lan://127.0.0.0/8?multicast=0&tls=1&seeds=127.0.0.1:" & $portA)
    let connectDeadline = epochTime() + 30.0
    while nodeB.statusInt("peers_connected") < 1 and
        epochTime() < connectDeadline:
      sleep(50)
    check nodeB.statusInt("peers_connected") >= 1
    let servedBefore = nodeA.statusInt("memo_requests_served")
    let fetchedBefore = nodeA.statusInt("fetch_hits_served")

    # 4. The consumer build through daemon B is served by daemon A.
    let consumer = buildThroughDaemon(nodeB, wsB)
    checkpoint("consumer build:\n" & consumer.output)
    if consumer.code != 0:
      checkpoint("daemon B log:\n" & nodeB.daemonLog())
    ensure consumer.code == 0
    check readFile(wsB / "build" / "artifact.txt") == InputText
    let consumerAction = actionReport(consumer.output)
    ensure not consumerAction.isNil
    check not consumerAction{"launched"}.getBool()
    check consumerAction{"cacheDecision"}.getStr() in ["hit", "cdHit"]
    check consumer.output.contains("hits=1")

    # Daemon A — not any CLI — answered the two-phase lookup.
    var servedAfter = nodeA.statusInt("memo_requests_served")
    var fetchedAfter = nodeA.statusInt("fetch_hits_served")
    let statusDeadline = epochTime() + 10.0
    while (servedAfter < servedBefore + 2 or fetchedAfter < fetchedBefore + 2) and
        epochTime() < statusDeadline:
      sleep(50)
      servedAfter = nodeA.statusInt("memo_requests_served")
      fetchedAfter = nodeA.statusInt("fetch_hits_served")
    checkpoint("daemon A status: " & $nodeA.status())
    check servedAfter >= servedBefore + 2   # selectors + memo entry
    check fetchedAfter >= fetchedBefore + 2 # PathSet blob + artifact blob
    # B keeps serving what it fetched: A's selector is now in B's store too.
    for entry in publishedA:
      check entry in memoEntries(nodeB.cacheRoot)
    check nodeA.process.running
    check nodeB.process.running
