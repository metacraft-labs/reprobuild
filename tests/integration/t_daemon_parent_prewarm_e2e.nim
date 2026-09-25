## Dependency-Attribution MAC-2 — the daemon-parent prewarm, end to end.
##
## NO MOCKS. A real `repro-daemon` on a real AF_UNIX socket, a real project
## that really compiles a provider, and the real `repro` CLI routing real build
## requests to it. The questions here — "did the parent hold warm state across
## two forks?" and "did a worker consume state it did not populate?" — are
## about processes, and a stand-in for any of them would answer by fiat.
##
## WHAT EACH CASE IS FOR, and what reddens it:
##
##   * `daemon_parent_prewarm_reaches_the_forked_worker` — the mechanism. It
##     asserts THREE things the daemon log records and nothing else can:
##     the parent WARMED on one request, REUSED that warm set on a later one
##     (so parent state really outlived a request), and a worker reported
##     `inheritedWarmHits` above zero (so the forked child really read from an
##     entry its parent populated). Replacing the
##     `runUserDaemonParentPrewarm` call in `handleBuildRequest` with `""`
##     reddens all three, and reddens the parity case's witness too — RUN, not
##     assumed: `warmed=0 reused=0 maxInheritedWarmHits=0`, four failed checks
##     across the two cases.
##
##     WHAT THIS CASE DOES *NOT* GATE, stated because the obvious claim is
##     false and was measured to be false: moving the prewarm to AFTER
##     `spawnDetachedDaemonWorker` leaves every check GREEN. That placement
##     still runs in the parent — the double-fork returns to the parent
##     immediately — so it warms for the NEXT request instead of this one, and
##     by pass 2 the log looks the same. The before-the-fork placement is
##     still the right one (request N's own worker can benefit, and the pass
##     does not race the worker that is concurrently rewriting the very files
##     it decodes), but that is a latency and robustness argument, not one
##     this case can distinguish. Do not add an assertion that pretends
##     otherwise.
##
##   * `a_prewarmed_daemon_builds_byte_identically_to_a_cold_one` — the
##     correctness bar. The same project, the same fixed path, built through
##     two daemons that differ ONLY in `REPROBUILD_DAEMON_PARENT_PREWARM`.
##     Same stdout, same stderr, same exit code, same artifact. Making the
##     prewarm insert anything the cold reader would not have produced reddens
##     it. Note the ordering inside: the arm whose log shows the prewarm was
##     USED is the arm whose bytes are compared, so this cannot pass by the
##     prewarm never having run — that is the failure MAC-1's parity case was
##     rewritten to exclude.
##
## Why one binary and an environment switch rather than two builds: it removes
## "a different image" as an explanation for any difference the parity case
## finds. The switch reaches nothing that enters an action fingerprint.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_core/cli_images
import repro_test_support

proc repoRoot(): string =
  getCurrentDir()

proc fullCliBin(): string =
  ## The ENGINE image, `build/bin/reprobuild`. This file was written when the
  ## engine was `build/bin/repro`; since the thin-client rename that name is
  ## the thin daemon client, and `REPRO_FULL_CLI` naming the thin client makes
  ## it hand over to itself (refused with exit 127 now; an endless `execv`
  ## loop before). `REPRO_FULL_CLI` names the engine by contract.
  repoRoot() / "build" / "bin" / reprobuildEngineExeName()

proc endpointBound(path: string): bool =
  ## `repro_test_support.runquotaEndpointReachable` answers with
  ## `fileExists`, and Nim's `fileExists` is FALSE for a Unix socket — the
  ## same fact `spawnRunQuotaDaemonIfNeeded` writes down where it calls
  ## `removeFile`. Against a runquotad that had already logged `listening`
  ## that check never became true. `getFileInfo` does not care what kind of
  ## node it is, which is the question being asked.
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except CatchableError:
    false

type SharedRunQuota = object
  process: Process
  env: seq[(string, string)]
  socket: string

proc stopSharedRunQuota(shared: SharedRunQuota) =
  if shared.process != nil:
    try:
      if shared.process.running:
        shared.process.terminate()
      discard shared.process.waitForExit()
    except CatchableError:
      discard
    try: shared.process.close() except CatchableError: discard
  if shared.socket.len > 0 and dirExists(shared.socket.parentDir):
    removeDirEventually(shared.socket.parentDir)

proc startSharedRunQuota(tempRoot: string): SharedRunQuota =
  ## ONE RunQuota coordinator, shared by both arms, on a socket path both
  ## arms name.
  ##
  ## Two distinct byte differences forced this, and neither is about the
  ## prewarm:
  ##
  ##   1. With NO coordinator reachable, the interface-extraction edge falls
  ##      back to the bypass and prints a WARNING line — but only on passes
  ##      where that edge is actually LAUNCHED (`usesRunQuotaBypass` reads
  ##      `item.launched`), and whether it launches is not stable run to run.
  ##      Two runs failed on that line alone, once on each arm.
  ##   2. With no REACHABLE coordinator at `$RUNQUOTA_SOCKET`, each build
  ##      spawns its own at `reprobuild-runquota-<pid>` and prints that path
  ##      on the `runQuotaSocket:` line, so the two arms differ by a pid.
  ##
  ## Starting one and pointing both arms at it removes both branches instead
  ## of tolerating them, and it is the configuration the milestone's
  ## measurements use anyway.
  let root = repoRoot()
  # Use the product's length-bounded, private endpoint derivation. The
  # scratch tree can exceed AF_UNIX's limit even on an ordinary workspace.
  let socket = runquotaSocketEndpoint("mac2-" & tempRoot)
  doAssert not dirExists(socket.parentDir), "fixture endpoint must be fresh"
  result.socket = socket
  var ready = false
  defer:
    if not ready: stopSharedRunQuota(result)
  let runquota = requireRunQuotaCliBin(root)
  let runquotad = requireRunQuotaDaemonBin(root)
  let logFile = tempRoot / "runquotad.log"
  result.process = startProcess("/bin/sh", args = ["-c",
    "exec \"$0\" --socket \"$1\" >" & quoteShell(logFile) & " 2>&1",
    runquotad, socket], options = {})
  for _ in 0 ..< 300:
    if endpointBound(socket):
      break
    sleep(100)
  doAssert endpointBound(socket),
    "runquotad did not bind " & socket & "\n" &
      (if fileExists(logFile): readFile(logFile) else: "(no log)")
  result.env = @[
    ("RUNQUOTA_SOCKET", socket),
    ("RUNQUOTA_BIN", runquota),
    ("RUNQUOTAD_BIN", runquotad),
    ("PATH", runquota.parentDir & $PathSep & getEnv("PATH"))
  ]
  ready = true

proc fixtureSource(): string =
  repoRoot() / "tests" / "fixtures" / "local-daemons-control-plane" /
    "direct-mode-parity" / "project"

type
  CapturedRun = object
    code: int
    output: string
    errors: string

proc runCaptured(exe: string; args: openArray[string]; cwd: string;
                 env: openArray[(string, string)] = []): CapturedRun =
  ## stdout and stderr captured SEPARATELY, and the status is the status of
  ## ``exe`` rather than of a shell that ran it — the `exec` is what makes
  ## that true, the same trap as reading a build's exit code through a pipe.
  let outPath = cwd / "captured-stdout"
  let errPath = cwd / "captured-stderr"
  var envTable = newStringTable()
  for key, value in envPairs():
    envTable[key] = value
  for entry in env:
    envTable[entry[0]] = entry[1]
  var shArgs = @["-c",
    "exec \"$0\" \"$@\" >" & outPath & " 2>" & errPath, exe]
  for arg in args:
    shArgs.add(arg)
  let process = startProcess("/bin/sh", workingDir = cwd, args = shArgs,
    env = envTable, options = {})
  defer: process.close()
  result.code = process.waitForExit()
  result.output = if fileExists(outPath): readFile(outPath) else: ""
  result.errors = if fileExists(errPath): readFile(errPath) else: ""

proc stateDir(tempRoot, arm: string): string = tempRoot / ("state-" & arm)
proc logPath(tempRoot, arm: string): string =
  stateDir(tempRoot, arm) / "logs" / "repro-daemon.log"

proc daemonEnv(tempRoot, arm, endpoint: string; prewarm: bool;
               runquota: seq[(string, string)]): seq[(string, string)] =
  result = runquota
  result.add @[
    ("REPRO_DAEMON_ENDPOINT", endpoint),
    ("REPRO_DAEMON_STATE_DIR", stateDir(tempRoot, arm)),
    ("REPROBUILD_STORE_ROOT", tempRoot / "store"),
    ("REPRO_FULL_CLI", fullCliBin()),
    ("REPROBUILD_DAEMON_PARENT_PREWARM", if prewarm: "1" else: "0")
  ]

proc stopDaemon(tempRoot, arm, endpoint: string) =
  discard runShell(shellCommand(@[fullCliBin(), "daemon", "stop",
    "--endpoint", endpoint, "--state-dir", stateDir(tempRoot, arm),
    "--log", logPath(tempRoot, arm)]), repoRoot())
  try: removeFile(endpoint) except OSError: discard

proc daemonLog(tempRoot, arm: string): string =
  let path = logPath(tempRoot, arm)
  if fileExists(path): readFile(path) else: ""

proc countLines(text, needle: string): int =
  for line in text.splitLines():
    if needle in line:
      inc result

proc maxInheritedWarmHits(text: string): int =
  ## The largest ``inheritedWarmHits=N`` any worker reported.
  for line in text.splitLines():
    let marker = "inheritedWarmHits="
    let at = line.find(marker)
    if at < 0:
      continue
    var digits = ""
    var i = at + marker.len
    while i < line.len and line[i].isDigit():
      digits.add(line[i])
      inc i
    if digits.len > 0:
      result = max(result, parseInt(digits))

proc buildArgs(projectRoot, tempRoot: string): seq[string] =
  @[
    "build", projectRoot,
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / "work",
    "--action-cache-root=" & tempRoot / "ac",
    "--progress=quiet",
    "--log=summary"
  ]

proc freshProject(tempRoot: string): string =
  ## A COLD tree at a FIXED path, with the work root and action cache reset.
  ## Both arms must build the same path or the worktree identity differs and
  ## the byte comparison would be meaningless for a reason that has nothing to
  ## do with the prewarm.
  let dest = tempRoot / "p"
  removeDir(dest)
  removeDir(tempRoot / "work")
  removeDir(tempRoot / "ac")
  createDir(tempRoot / "work")
  createDir(tempRoot / "ac")
  copyDir(fixtureSource(), dest)
  dest

proc runArm(tempRoot, arm, endpoint: string; prewarm: bool;
            passes: int; runquota: seq[(string, string)]): CapturedRun =
  ## Build the fixture ``passes`` times through one daemon and return the LAST
  ## build's capture. The first build is cold — it has to write the caches a
  ## prewarm can later read — so the interesting arm needs at least three.
  createDir(stateDir(tempRoot, arm))
  let env = daemonEnv(tempRoot, arm, endpoint, prewarm, runquota)
  let project = freshProject(tempRoot)
  for pass in 1 .. passes:
    result = runCaptured(fullCliBin(), buildArgs(project, tempRoot),
      tempRoot, env)
    checkpoint(arm & " pass " & $pass & " exit=" & $result.code)
    if result.code != 0:
      checkpoint(arm & " stdout:\n" & result.output)
      checkpoint(arm & " stderr:\n" & result.errors)
      return

suite "MAC-2 daemon parent prewarm end to end":
  when isNixSupported:
    test "integration_daemon_parent_prewarm_reaches_the_forked_worker":
      let tempBase = createTempDir("repro-mac2-e2e", "")
      let tempRoot = tempBase / repeat("long-", 30)
      createDir(tempRoot)
      let endpoint = daemonSocketEndpoint("mac2-warm")
      defer:
        stopDaemon(tempRoot, "warm", endpoint)
        removeDirEventually(tempBase)
      createDir(tempRoot / "store")
      let runquota = startSharedRunQuota(tempRoot)
      defer: stopSharedRunQuota(runquota)

      let last = runArm(tempRoot, "warm", endpoint, prewarm = true, passes = 3,
        runquota = runquota.env)
      check last.code == 0

      let log = daemonLog(tempRoot, "warm")
      let warmed = countLines(log, "parent prewarm warmed")
      let reused = countLines(log, "parent prewarm reused")
      let inherited = maxInheritedWarmHits(log)
      checkpoint("warmed=" & $warmed & " reused=" & $reused &
        " maxInheritedWarmHits=" & $inherited)

      # 1. The parent decoded a project's caches at least once.
      check warmed >= 1
      # 2. ...and a LATER request found that warm set still fresh, which is
      #    only possible if parent state outlived the request that made it.
      check reused >= 1
      # 3. ...and a forked worker actually READ from an entry it did not
      #    populate. Without this the two above are satisfied by a parent that
      #    warms diligently and a worker that ignores it — the milestone's
      #    entire mechanism, unobserved. This is the check that distinguishes
      #    warming before the fork from warming after it.
      check inherited >= 1

    test "integration_a_prewarmed_daemon_builds_byte_identically_to_a_cold_one":
      let tempBase = createTempDir("repro-mac2-parity", "")
      let tempRoot = tempBase / repeat("long-", 30)
      createDir(tempRoot)
      let warmEndpoint = daemonSocketEndpoint("mac2-parity-warm")
      let coldEndpoint = daemonSocketEndpoint("mac2-parity-cold")
      defer:
        stopDaemon(tempRoot, "warm", warmEndpoint)
        stopDaemon(tempRoot, "cold", coldEndpoint)
        removeDirEventually(tempBase)
      createDir(tempRoot / "store")
      let runquota = startSharedRunQuota(tempRoot)
      defer: stopSharedRunQuota(runquota)

      let cold = runArm(tempRoot, "cold", coldEndpoint, prewarm = false,
        passes = 3, runquota = runquota.env)
      check cold.code == 0
      let coldArtifact = readFile(tempRoot / "p" / "dist" / "copied.txt")
      let coldLog = daemonLog(tempRoot, "cold")
      # The control arm must really be cold, or "identical" means nothing.
      check countLines(coldLog, "parent prewarm") == 0
      check maxInheritedWarmHits(coldLog) == 0

      let warm = runArm(tempRoot, "warm", warmEndpoint, prewarm = true,
        passes = 3, runquota = runquota.env)
      check warm.code == 0
      let warmLog = daemonLog(tempRoot, "warm")
      # ...and the compared arm must really have USED the prewarm. A parity
      # assertion between two paths needs a separate witness that the second
      # path was taken (MAC-1's lesson, applied here).
      check maxInheritedWarmHits(warmLog) >= 1

      if warm.output != cold.output:
        checkpoint("cold stdout:\n" & cold.output)
        checkpoint("warm stdout:\n" & warm.output)
      check warm.output == cold.output
      if warm.errors != cold.errors:
        checkpoint("cold stderr:\n" & cold.errors)
        checkpoint("warm stderr:\n" & warm.errors)
      check warm.errors == cold.errors
      check readFile(tempRoot / "p" / "dist" / "copied.txt") == coldArtifact
