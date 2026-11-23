## ``repro stats`` and ``repro pressure`` say whether there is a store to
## read, instead of printing an empty table that looks like "nothing was
## slow".
##
## Every JSON object either command prints carries three top-level keys:
## ``capture_enabled``, ``store_status`` (``ready`` | ``unprovisioned`` |
## ``daemon_unreachable`` | ``empty``) and, when the status is not
## ``ready``, ``remedy``. A text-mode run prints exactly one stderr line
## naming the status and the remedy when the status is not ``ready``, and
## nothing when it is.
##
## THE STATES ARE WALKED IN ONE TEST, AS TRANSITIONS. A command that always
## printed one status would satisfy any single-state check, so the same four
## invocations (``repro stats``, ``repro stats --json``, ``repro pressure``,
## ``repro pressure --json``) run against each of these, in order, and every
## state's answer is asserted exactly:
##
## 1. A scratch ``HOME`` whose ``RUNQUOTA_SOCKET`` names a directory nobody
##    created: nothing was ever set up there, so ``unprovisioned``.
## 2. A directory holding a dead socket (bound, then closed, so the file
##    stays and nothing listens): a daemon was set up and is gone, so
##    ``daemon_unreachable``.
## 3. A live ``runquotad`` started without ``--measurement capture=on`` (the
##    default): it answers and records nothing, so ``unprovisioned`` with
##    ``capture_enabled: false``. For ``repro pressure`` the switch that
##    matters is the client's ``pressure-reports`` measurement, unset here.
## 4. A live ``runquotad`` with capture on and nothing built: ``empty``, and
##    the same for pressure with ``RUNQUOTA_MEASUREMENT=pressure-reports=on``.
## 5. The same daemon after a real ``repro build`` with pressure reports on:
##    ``ready``, no ``remedy`` key and NO stderr notice -- including for a
##    view whose answer has zero rows (``rank --scope=targets``), which is a
##    ready store with nothing matching, not an empty one.
##
## NO MOCKS. The daemon is the real ``runquotad`` (``RUNQUOTAD_BIN``, PATH,
## or a built ``RUNQUOTA_SRC`` checkout -- a missing binary fails the test
## with that remedy rather than skipping it), the CLI is the shipped
## ``build/bin/repro``, the rows come from a real build that took leases,
## and the dead socket of state 2 is a real Unix socket whose listener has
## gone away. Each daemon this test starts is stopped by its own PID; no
## other process is touched.

import std/[json, net, os, osproc, strtabs, strutils, tempfiles, times,
    unittest]

import repro_test_support

proc repoRoot(): string = getCurrentDir()

proc publicReproBin(): string =
  ## SPELLED WITH THE LITERAL ``build/bin/repro`` so ``generate_test_edges``
  ## declares the engine-built binary as this test's input.
  requireBinary(repoRoot() / addFileExt("build/bin/repro", ExeExt),
    "reprobuild.apps.repro")

when isNixSupported:
  import std/posix

  proc socketIsBound(path: string): bool =
    var info: Stat
    lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

  type DaemonHandle = object
    process: Process
    log: string

  proc startRunQuotaDaemon(socketPath, identityFile, log: string;
                           capture: bool): DaemonHandle =
    ## ``runquotad`` on this test's own socket. Its output goes to ``log``
    ## (``exec`` keeps the PID the daemon's own), so a chatty daemon cannot
    ## block on a pipe nobody drains.
    var args = @[requireRunQuotaDaemonBin(repoRoot()),
      "--socket", socketPath,
      "--host-identity-file", identityFile,
      "--ambient-sample-interval-millis", "0"]
    if capture:
      args.add(["--measurement", "capture=on"])
    let process = startProcess("/bin/sh",
      args = @["-c", "exec \"$@\" >" & quoteShell(log) & " 2>&1", "sh"] & args)
    for _ in 0 ..< 400:
      if socketIsBound(socketPath) or not process.running:
        break
      sleep(25)
    # THE SOCKET IS BOUND BEFORE CAPTURE IS ARMED. ``runquotad`` prints
    # its listening line first and opens the observation store after it,
    # and a stats query in between is answered ``captureEnabled: false``.
    # A daemon asked to capture is ready only once it says so.
    if capture:
      for _ in 0 ..< 400:
        let output = (try: readFile(log) except IOError: "")
        if output.contains("capture enabled") or not process.running:
          break
        sleep(25)
    let armed = not capture or
      (try: readFile(log) except IOError: "").contains("capture enabled")
    if not socketIsBound(socketPath) or not armed:
      let output = (try: readFile(log) except IOError: "")
      if process.running:
        process.terminate()
        discard process.waitForExit(5000)
      process.close()
      raise newException(OSError, "runquotad did not bind " & socketPath &
        (if capture: " with capture enabled" else: "") & ": " & output)
    DaemonHandle(process: process, log: log)

  proc stop(handle: var DaemonHandle) =
    if handle.process.isNil:
      return
    if handle.process.running:
      handle.process.terminate()
      discard handle.process.waitForExit(5000)
    if handle.process.running:
      handle.process.kill()
      discard handle.process.waitForExit(5000)
    handle.process.close()
    handle.process = nil

  proc makeDeadSocket(path: string) =
    ## A Unix socket file with no listener: bind, then close without
    ## unlinking, which is what a daemon killed before it could clean up
    ## leaves behind.
    var sock = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
    sock.bindUnix(path)
    sock.close()
    doAssert socketIsBound(path)

  proc stateDir(root, name: string): string =
    ## A state directory of the daemon's own. ``runquotad`` keeps its
    ## observation store beside its host identity file, so two daemons
    ## given one directory would share one store.
    result = root / ("state-" & name)
    createDir(result)

  proc nimString(value: string): string = value.escape()

  proc writeCopyProject(projectRoot, packageName: string; actionCount: int) =
    ## PROCESS actions, so each one takes a RunQuota lease and leaves an
    ## execution row; a built-in copy runs in the engine and leaves none.
    createDir(projectRoot / "src")
    for i in 0 ..< actionCount:
      writeFile(projectRoot / "src" / ("input-" & $i & ".txt"),
        "input " & $i & "\n")
    let script =
      "set -eu\n" &
      "src=$1\n" &
      "out=$2\n" &
      "mkdir -p \"$(dirname \"$out\")\"\n" &
      "cat \"$src\" > \"$out\"\n"
    var body = "import repro_project_dsl\n\n" &
      "package " & packageName & ":\n" &
      "  uses:\n" &
      "    \"sh >=1\"\n\n" &
      "  executable shTool:\n" &
      "    name \"sh\"\n" &
      "    cli:\n" &
      "      subcmd \"-c\":\n" &
      "        pos args, seq[string], position = 0\n\n" &
      "    build:\n"
    for i in 0 ..< actionCount:
      let inputRel = "src/input-" & $i & ".txt"
      let outputRel = "dist/output-" & $i & ".txt"
      body.add("      discard buildAction(" &
        nimString("store-state-copy-" & $i) & ",\n" &
        "        " & packageName & ".executable(\"sh\").subcmd_2d_c(\n" &
        "          args = @[" & nimString(script) & ", " & nimString("sh") &
          ", " & nimString(inputRel) & ", " & nimString(outputRel) & "]),\n" &
        "        inputs = @[" & nimString(inputRel) & "],\n" &
        "        outputs = @[" & nimString(outputRel) & "],\n" &
        "        cacheable = true)\n")
    writeFile(projectRoot / "reprobuild.nim", body)

  type Scenario = object
    ## The environment one state's commands run in: the inherited one with
    ## ``HOME`` replaced and the RunQuota variables set or REMOVED.
    home: string
    socket: string
    pressureReports: bool

  proc envFor(scenario: Scenario): StringTableRef =
    result = newStringTable(modeCaseSensitive)
    for name, value in envPairs():
      result[name] = value
    result["HOME"] = scenario.home
    result["RUNQUOTA_SOCKET"] = scenario.socket
    # ``RUNQUOTA_ENDPOINT_SCOPE`` IS CARRIED, NOT REMOVED. The endpoint is
    # the test's own: ``runquotaRendezvousDir`` selected the ``private``
    # scope in this process before the daemons were started with this
    # environment, and every ``repro`` child talks to those daemons, so it
    # must judge the endpoint under the same policy. Removing the variable
    # put the children on the host scope, which on a host with a
    # ``runquota`` account refuses the test's own directory -- the daemons
    # bound and the clients reported ``daemon_unreachable``. The two
    # variables below are removed so an enclosing run's measurement and
    # session do not leak in; a state that wants pressure reports sets
    # ``RUNQUOTA_MEASUREMENT`` itself, and no state uses a session.
    for name in ["RUNQUOTA_MEASUREMENT", "RUNQUOTA_SESSION"]:
      if result.hasKey(name):
        result.del(name)
    if scenario.pressureReports:
      result["RUNQUOTA_MEASUREMENT"] = "pressure-reports=on"

  proc repro(scenario: Scenario; args: openArray[string];
             timeoutMs = 120_000): CmdSplitResult =
    ## ``timeoutMs`` bounds a hang; a query answers in well under a second.
    result = runProgramSplit(publicReproBin(), args, repoRoot(),
      envFor(scenario), timeoutMs = timeoutMs)
    checkpoint("repro " & args.join(" ") & " -> exit " & $result.code &
      "\nstdout:\n" & result.stdout & "\nstderr:\n" & result.stderr)

  proc noticeLines(stderrText, command: string): seq[string] =
    for line in stderrText.splitLines:
      if line.startsWith(command & ": store_status="):
        result.add(line)

  proc nonEmptyLines(text: string): seq[string] =
    for line in text.splitLines:
      if line.strip.len > 0:
        result.add(line)

  proc checkStatusKeys(node: JsonNode; captureEnabled: bool; status: string;
                       remedyParts: openArray[string]) =
    ## The three keys, exactly. ``remedy`` is required (and must name each
    ## of ``remedyParts``) for every status but ``ready``, and absent for
    ## ``ready``.
    check node.kind == JObject
    check node.hasKey("capture_enabled")
    # ``{}`` yields nil for a missing key; test before reading ``kind``.
    check not node{"capture_enabled"}.isNil and
      node{"capture_enabled"}.kind == JBool
    check node{"capture_enabled"}.getBool(not captureEnabled) == captureEnabled
    check node.hasKey("store_status")
    check node{"store_status"}.getStr() == status
    if status == "ready":
      check not node.hasKey("remedy")
    else:
      check node{"remedy"}.getStr().len > 0
      for part in remedyParts:
        check node{"remedy"}.getStr().contains(part)

  proc checkStats(scenario: Scenario; projectRoot: string;
                  captureEnabled: bool; status, windowState: string;
                  remedyParts: openArray[string]) =
    ## ``repro stats`` and ``repro stats --json`` (the overview), plus the
    ## ``status`` view and a ``rank`` view, in one state.
    let asJson = repro(scenario, ["stats", "--json",
      "--project-root=" & projectRoot])
    check asJson.code == 0
    let node = parseJson(asJson.stdout.strip())
    checkStatusKeys(node, captureEnabled, status, remedyParts)
    check node{"schemaId"}.getStr() == "reprobuild.stats.overview.v1"
    check node{"window"}{"state"}.getStr() == windowState
    # JSON mode carries the status in the object; no notice on stderr.
    check noticeLines(asJson.stderr, "repro stats").len == 0

    for view in [@["status"],
                 @["rank", "--scope=actions", "--by=cache-miss-count"]]:
      let other = repro(scenario, @["stats"] & view &
        @["--project-root=" & projectRoot, "--format=json"])
      check other.code == 0
      let otherNode = parseJson(other.stdout.strip())
      checkStatusKeys(otherNode, captureEnabled, status, remedyParts)
      # BACKWARD COMPATIBLE: the window every view already carried is
      # still there, under its old keys.
      check otherNode{"window"}{"state"}.getStr() == windowState

    let asText = repro(scenario, ["stats", "--project-root=" & projectRoot])
    check asText.code == 0
    # Stdout is the text overview, unchanged: no status keys leak into it.
    check asText.stdout.contains("Stats source: ")
    check not asText.stdout.contains("store_status")
    let notices = noticeLines(asText.stderr, "repro stats")
    if status == "ready":
      check notices.len == 0
      check nonEmptyLines(asText.stderr).len == 0
    else:
      # EXACTLY ONE LINE, and it is the whole of stderr.
      check notices.len == 1
      check nonEmptyLines(asText.stderr).len == 1
      if notices.len == 1:
        check notices[0].contains("capture_enabled=" & $captureEnabled)
        check notices[0].contains("; remedy: " & node{"remedy"}.getStr())

  proc checkPressure(scenario: Scenario; exitCode: int; captureEnabled: bool;
                     status: string; remedyParts: openArray[string]) =
    let asJson = repro(scenario, ["pressure", "--json"])
    check asJson.code == exitCode
    # STRUCTURED OUTPUT ON EVERY EXIT, including the non-zero one.
    let node = parseJson(asJson.stdout.strip())
    checkStatusKeys(node, captureEnabled, status, remedyParts)
    if exitCode == 0:
      # The daemon's own answer is still all there.
      check node.hasKey("host")
      check node.hasKey("long_wait_millis")
    else:
      check node{"error"}.getStr().len > 0
    check noticeLines(asJson.stderr, "repro pressure").len == 0

    let asText = repro(scenario, ["pressure"])
    check asText.code == exitCode
    let notices = noticeLines(asText.stderr, "repro pressure")
    if exitCode == 0:
      check asText.stdout.contains("long-wait threshold:")
    else:
      check asText.stdout.strip().len == 0
    check not asText.stdout.contains("store_status")
    if status == "ready":
      check notices.len == 0
      check nonEmptyLines(asText.stderr).len == 0
    else:
      check notices.len == 1
      check nonEmptyLines(asText.stderr).len == 1
      if notices.len == 1:
        check notices[0].contains("capture_enabled=" & $captureEnabled)
        check notices[0].contains("; remedy: " & node{"remedy"}.getStr())

  proc waitUntil(timeoutSeconds: float; predicate: proc (): bool): bool =
    ## Polls for a state that only ever moves one way (rows and reports are
    ## never withdrawn), so a later read cannot undo an earlier pass.
    let deadline = epochTime() + timeoutSeconds
    while epochTime() < deadline:
      if predicate():
        return true
      sleep(200)
    false

suite "repro stats and repro pressure report the store state":
  when isNixSupported:
    test "unprovisioned, unreachable, capture-off, empty and ready are told apart":
      # A HOST WITH A ``runquota`` ACCOUNT AND GROUP, EMULATED. That is
      # where the host endpoint scope demands another account's uid and
      # mode ``0750``, and refuses a directory the test user owns; on a
      # host without the account it degrades to the invoking uid and
      # accepts it, so a client on the wrong scope goes unnoticed there.
      # Emulating the account (a uid that is not ours) and the group (our
      # own gid, so the group check itself can pass) makes every host the
      # one where the scope matters. Any inherited scope is dropped first,
      # so ``runquotaRendezvousDir`` selects ``private`` for this test's
      # own endpoint, the daemons inherit it, and ``envFor`` hands it to
      # every ``repro`` child.
      const endpointKeys = ["RUNQUOTA_ENDPOINT_SCOPE",
        "RUNQUOTA_ENDPOINT_OWNER_UID", "RUNQUOTA_ENDPOINT_GROUP"]
      var savedEndpointEnv: seq[(string, bool, string)] = @[]
      for key in endpointKeys:
        savedEndpointEnv.add((key, existsEnv(key), getEnv(key)))
      defer:
        for (key, had, value) in savedEndpointEnv:
          if had: putEnv(key, value)
          else: delEnv(key)
      delEnv("RUNQUOTA_ENDPOINT_SCOPE")
      putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", $(int64(getuid()) + 1))
      putEnv("RUNQUOTA_ENDPOINT_GROUP", $getgid())
      let tempRoot = createTempDir("repro-store-state", "")
      let socketRoot = getTempDir() / ("rq-sst-" & $getCurrentProcessId())
      createDir(socketRoot)
      let rendezvous = runquotaRendezvousDir(socketRoot)
      check getEnv("RUNQUOTA_ENDPOINT_SCOPE") == "private"
      let home = tempRoot / "home"
      createDir(home)
      let projectRoot = tempRoot / "project"
      writeCopyProject(projectRoot, "storeState", 2)
      var noCapture, capture: DaemonHandle
      defer:
        noCapture.stop()
        capture.stop()
        removeDir(socketRoot)
        removeDir(tempRoot)

      # --- (1) NOTHING WAS EVER SET UP --------------------------------
      let neverProvisioned = socketRoot / "never-provisioned" /
        "runquotad.sock"
      check not dirExists(parentDir(neverProvisioned))
      let unprovisioned = Scenario(home: home, socket: neverProvisioned)
      checkStats(unprovisioned, projectRoot, false, "unprovisioned",
        "unavailable", ["runquotad --socket", neverProvisioned,
        "capture=on"])
      checkPressure(unprovisioned, 1, false, "unprovisioned",
        ["runquotad --socket", neverProvisioned])

      # --- (2) A DAEMON WAS THERE AND IS GONE -------------------------
      let deadSocket = rendezvous / "dead.sock"
      makeDeadSocket(deadSocket)
      let dead = Scenario(home: home, socket: deadSocket)
      checkStats(dead, projectRoot, false, "daemon_unreachable",
        "unavailable", ["runquotad --socket", deadSocket])
      checkPressure(dead, 1, false, "daemon_unreachable",
        ["runquotad --socket", deadSocket])

      # --- (3) A LIVE DAEMON THAT RECORDS NOTHING ---------------------
      let noCaptureSocket = rendezvous / "nocap.sock"
      noCapture = startRunQuotaDaemon(noCaptureSocket,
        stateDir(socketRoot, "nocap") / "host-id", tempRoot / "runquotad-nocap.log",
        capture = false)
      let captureOff = Scenario(home: home, socket: noCaptureSocket)
      checkStats(captureOff, projectRoot, false, "unprovisioned",
        "capture-disabled", ["capture=on"])
      # Answered, so exit 0 -- but nothing from this environment reports.
      checkPressure(captureOff, 0, false, "unprovisioned",
        ["RUNQUOTA_MEASUREMENT=pressure-reports=on"])
      noCapture.stop()

      # --- (4) RECORDING, NOTHING RECORDED YET ------------------------
      let captureSocket = rendezvous / "cap.sock"
      capture = startRunQuotaDaemon(captureSocket,
        stateDir(socketRoot, "cap") / "host-id", tempRoot / "runquotad-cap.log",
        capture = true)
      let live = Scenario(home: home, socket: captureSocket,
        pressureReports: true)
      checkStats(live, projectRoot, true, "empty", "empty",
        ["repro build"])
      checkPressure(live, 0, true, "empty", ["pressure-reports=on"])

      # --- (5) A REAL BUILD -------------------------------------------
      let build = repro(live, ["build", projectRoot,
        "--daemon=off",
        "--tool-provisioning=path",
        "--work-root=" & tempRoot / "work",
        "--action-cache-root=" & tempRoot / "action-cache",
        "--progress=quiet",
        "--log=quiet",
        "--measure=none"], timeoutMs = 900_000)
      # A COLD BUILD: a fresh HOME and action cache compile the project's
      # provider first, which on a loaded host has taken over two minutes.
      check build.code == 0
      # The observation writer drains on a tick and the last pressure
      # report is sent as the build closes, so wait for both to land.
      check waitUntil(30.0, proc (): bool =
        let r = repro(live, ["stats", "--json",
          "--project-root=" & projectRoot])
        r.code == 0 and
          parseJson(r.stdout.strip()){"store_status"}.getStr() == "ready")
      check waitUntil(30.0, proc (): bool =
        let r = repro(live, ["pressure", "--json"])
        r.code == 0 and
          parseJson(r.stdout.strip()){"store_status"}.getStr() == "ready")
      checkStats(live, projectRoot, true, "ready", "complete", [])
      checkPressure(live, 0, true, "ready", [])

      # READY WITH ZERO MATCHING ROWS IS NOT EMPTY. The store holds rows;
      # this view has none to show (the spine has no target dimension).
      # The status describes the store, so it stays ``ready`` and text mode
      # prints no notice.
      let targets = repro(live, ["stats", "rank", "--scope=targets",
        "--by=build-time", "--project-root=" & projectRoot, "--json"])
      check targets.code == 0
      let targetsNode = parseJson(targets.stdout.strip())
      check targetsNode{"rows"}.len == 0
      checkStatusKeys(targetsNode, true, "ready", [])
      let targetsText = repro(live, ["stats", "rank", "--scope=targets",
        "--by=build-time", "--project-root=" & projectRoot])
      check targetsText.code == 0
      check noticeLines(targetsText.stderr, "repro stats").len == 0
