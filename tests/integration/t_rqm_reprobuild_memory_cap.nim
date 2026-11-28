## Reprobuild applies RunQuota's per-task memory cap to its own actions, and
## says what happened when an action reached or passed it.
##
## WHAT IS GUARDED, each with the change that makes it fail:
##
## * `test_rqm_reprobuild_reports_cap_exceeded`: a build with one action that
##   allocates past a run-size cap (`RUNQUOTA_MEMORY_CAP=<size>` in the
##   ENGINE's environment, the action placed under a test cgroup root) fails
##   that action with the report -- the action and its command id, the cap
##   and its basis, the peak, both ways to declare expected growth, and whom
##   to tell -- with the reason `memory cap exceeded`; the engine runs it
##   once (its own launch counter says 1), and nothing of it is published: a
##   second build with the cap lifted runs it again rather than serving it
##   from the cache (a third is then a cache hit, the control that the action
##   is cacheable at all). Run through the inline RunQuota session and
##   through the RunQuota helper process. Mutations: reporting the kill as an
##   ordinary failure (`noteMemoryCapOutcome` ignoring `exceeded`: the
##   reason and the report are missing); re-queuing a cap-exceeded action
##   (the counter says 2).
## * A learned cap: after a measured success of the same command id the cap
##   is the factor times that peak, and the report names the previous
##   maximum; an ADVISORY breach of it on an otherwise successful action is
##   a warning on the result and in the run report, not a failure, and the
##   action's outputs are cached. Mutation: treating a breach report as a
##   failure (`noteMemoryCapOutcome` failing every action with a report).
## * A cap that applies but is not enforced (no cgroup root) is said ONCE
##   per build, with the root's own reason, on the inline and the helper
##   path: two actions, one note in the build output. Mutations: one
##   warning line per action; the helper not given the reason.
## * An engine inside a caller's delegated scope with its own `MemoryMax`
##   (`systemd-run --user --scope -p Delegate=yes`) keeps each capped action
##   inside the scope, in `L/runquota/memory-capped/cap-...`, where its own
##   cap kills it; inline and through the helper. Mutation: the holder not
##   carried (runquota's memory-only target, or the helper's policy).
## * A helper image too old to know `--memory-cap` fails each action with
##   that named as the cause, and only when its output shows that refusal;
##   another helper failure is not blamed on the flag. Mutations: the plain
##   "did not write result"; the hint on every helper failure.
## * An invalid `RUNQUOTA_MEMORY_CAP` refuses a leased build before any
##   action runs, naming the variable; a `--no-runquota` build ignores it,
##   and its header says the cap does not apply. Mutation: refusing on the
##   bypass path too.
## * The engine reads no host file of the host's: every case names a
##   missing one (`memoryCapHostConfig`), so `/etc/runquota/runquotad.toml`
##   cannot decide an outcome.
## * Off costs nothing: with the host mode off and the variable unset, a
##   build's actions are not placed -- the explicit cgroup root it would use
##   is never created -- and the policy is inactive. Mutation: placing every
##   action in the memory-only target whatever the policy says.
## * The report's wording for each basis (learned, run size, budget,
##   advisory, cap reached), and the policy's round trip through the helper's
##   command line.
##
## TWO STAND-INS, justified at their case: a script that prints what an old
## helper prints for `--memory-cap`, and `false` from PATH for a helper that
## fails for another reason. Otherwise NO MOCKS: the real engine
## (`runBuild`), a real private `runquotad` on its own endpoint, real
## processes (this binary in its action modes), real user scopes, and real
## cgroups of a test-owned root below the user's delegated subtree. Where the
## host gives the user no delegated memory controller the host cases are
## reported SKIPPED with the reason.

# The RunQuota helper role of the image this test stands in for.
from repro_cli_support/runquota_helper_cli import runRunQuotaHelperArgs,
  selectsRunQuotaHelper
import std/[json, os, osproc, strutils, tables, tempfiles, times, unittest]

import repro_build_engine
import repro_cli_support
import repro_core
import repro_depfile
import repro_runquota
import runquota_client
import runquota_process

import repro_test_support
import repro_test_support/process_fixtures
import repro_test_support/reasoned_skip

when defined(posix):
  import std/posix

const MiB = 1024'u64 * 1024'u64

proc fixtureWrite(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)

when defined(posix):
  var MapAnonymous {.importc: "MAP_ANONYMOUS", header: "<sys/mman.h>".}: cint

  proc allocateAndTouch(mib: int): bool =
    ## Anonymous memory the kernel must charge: every page written.
    let size = mib * 1024 * 1024
    let base = mmap(nil, size, PROT_READ or PROT_WRITE,
      MAP_PRIVATE or MapAnonymous, -1, 0)
    if base == MAP_FAILED:
      return false
    let bytes = cast[ptr UncheckedArray[byte]](base)
    var i = 0
    while i < size:
      bytes[i] = 1
      i += 4096
    true

proc scopeBuild(inline: bool; work: string)
  ## Defined below, once the build helpers are (`scope-build` mode).

when isMainModule:
  let params = commandLineParams()
  if params.len == 6 and params[0] == "alloc-action":
    # alloc-action <MiB> <counter> <output> <depfile> <name>: count the
    # launch, write the output and the depfile FIRST (so a killed run leaves
    # an output on disk that the engine could have published), then allocate.
    let counter = open(params[2], fmAppend)
    counter.write("run\n")
    counter.close()
    # The output names the cgroup the action ran in (`0::<path>`), so a
    # test can tell where the launch placed it.
    var own = ""
    try: own = readFile("/proc/self/cgroup")
    except IOError, OSError: discard
    fixtureWrite(params[3], params[5] & "\n" & own)
    fixtureWrite(params[4], "out/" & params[5] & ".txt:\n")
    when defined(posix):
      if not allocateAndTouch(parseInt(params[1])):
        quit 3
    quit 0
  if selectsRunQuotaHelper(params):
    quit runRunQuotaHelperArgs(params)
  if params.len == 3 and params[0] == "scope-build":
    # scope-build <inline|helper> <work>: run as the ENGINE inside a
    # caller's delegated, limited scope; build one action that allocates
    # past a 64 MiB run cap and print where it ran and how it ended.
    scopeBuild(params[1] == "inline", params[2])
    quit 0

proc repoRoot(): string = getCurrentDir()

proc launches(counter: string): int =
  if not fileExists(counter): 0
  else: readFile(counter).countLines() - 1

type CapDaemon = object
  process: Process
  root: string

proc startCapDaemon(root: string): CapDaemon =
  ## A private `runquotad` with a 16 GiB budget and its own estimate store,
  ## on an endpoint of its own; the engine's session finds it through
  ## `RUNQUOTA_SOCKET`.
  let socket = runquotaSocketEndpoint("repro-memcap-" &
    $getCurrentProcessId() & "-" & root.extractFilename)
  when defined(posix):
    releaseDirAtProcessExit(socket.parentDir)
  if fileExists(socket):
    removeFile(socket)
  writeFile(root / "runquotad.toml", "schema = \"runquota.host-config.v1\"\n" &
    "[machine]\nmemory_bytes = " & $(16'u64 * 1024'u64 * MiB) &
    "\ncpu_milli = 16000\n")
  putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
  putEnv("RUNQUOTA_SOCKET", socket)
  result.root = root
  result.process = startProcess(requireRunQuotaDaemonBin(repoRoot()), args = [
    "--socket", socket, "--host-config", root / "runquotad.toml",
    "--host-identity-file", root / "host-id",
    "--estimate-db", root / "est.sqlite",
    "--no-write-stats",
    "--ambient-sample-interval-millis", "0",
    "--memory-pressure-source", "unavailable"],
    options = {poUsePath, poParentStreams})
  when defined(posix):
    terminateAtProcessExit(processID(result.process))
  for _ in 0 ..< 600:
    if isRunQuotaDaemonReachable():
      return
    sleep(50)
  raise newException(OSError, "runquotad did not start")

proc stop(daemon: var CapDaemon) =
  daemon.process.terminate()
  discard daemon.process.waitForExit(5000)
  daemon.process.close()

proc allocAction(app, workRoot, name, statsId: string; mib: int;
                 counter: string): BuildAction =
  let depfile = "deps/" & name & ".d"
  action(name, [app, "alloc-action", $mib, counter,
    workRoot / "out" / (name & ".txt"), workRoot / depfile, name],
    cwd = workRoot, outputs = ["out/" & name & ".txt"],
    commandStatsId = statsId, cacheable = true,
    memoryBytes = 64'u64 * MiB,
    dependencyPolicy = DependencyGatheringPolicy(
      kind: dgRecognizedFormat,
      completeness: decComplete,
      recognizedReports: @[RecognizedDependencyReportSpec(
        formatName: DependencyFormatName(MakeDepfileFormatName),
        outputs: @[ExpectedDependencyFile(logicalName: "deps",
          path: depfile, required: true)],
        completeness: decComplete)]),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc noHostFile(): string =
  ## A RunQuota host file that does not exist: the cap's mode comes from
  ## `RUNQUOTA_MEMORY_CAP` alone, whatever `/etc/runquota/runquotad.toml`
  ## on the host running the test says.
  getTempDir() / ("repro-memcap-no-host-file-" & $getCurrentProcessId() &
    ".toml")

proc buildWith(actions: seq[BuildAction]; cacheRoot: string;
               inline: bool; helper = ""; bypass = false): BuildRunResult =
  runBuild(graph(actions), BuildEngineConfig(
    cacheRoot: cacheRoot,
    runQuotaCliPath: (if helper.len > 0: helper else: getAppFilename()),
    maxParallelism: 2'u32,
    stdoutLimit: 64 * 1024,
    stderrLimit: 64 * 1024,
    inlineRunQuota: inline,
    bypassRunQuota: bypass,
    memoryCapHostConfig: noHostFile()))

proc ranIn(workRoot, name: string): string =
  ## The cgroup the action `name` ran in, from its output.
  let path = workRoot / "out" / (name & ".txt")
  if not fileExists(path): return ""
  for line in readFile(path).splitLines():
    if line.startsWith("0::"): return "/sys/fs/cgroup" & line[3 .. ^1]
  

proc resultOf(run: BuildRunResult; id: string): ActionResult =
  for item in run.results:
    if item.id == id:
      return item
  raise newException(KeyError, "no result for " & id)

proc withEnv(name, value: string) =
  if value.len == 0: delEnv(name) else: putEnv(name, value)

when defined(linux):
  proc delegatedMemoryRoot(reason: var string): string =
    ## A fresh cgroup root of this test's own, beside the user's default
    ## RunQuota root (never in it: that one is shared with every launcher the
    ## user runs), or "" with `reason` where the user has no delegated
    ## memory controller. Created by the first capped launch, removed by
    ## `removeRoot`.
    # Resolved as the engine resolves it: the agent session's scope (named
    # by RUNQUOTA_AGENT_SESSION_SCOPE) is the one limited cgroup a tree may
    # leave, so without it every case would skip inside a session.
    let default = resolveCgroupRoot("", readFile("/proc/self/cgroup"),
      int(getuid()), hostSwitchOn = true,
      agentScope = getEnv("RUNQUOTA_AGENT_SESSION_SCOPE").strip())
    if not default.usable:
      reason = default.reason
      return ""
    let root = default.path.parentDir / ("repro-memcap-test-" &
      $getCurrentProcessId() & "-" & $int64(epochTime() * 1000) & ".slice")
    let probe = probeMemory(CgroupRoot(state: crsExplicit, path: root))
    if not probe.available:
      reason = probe.problem
      return ""
    root

  proc removeRoot(root: string): string =
    ## Remove the test root and what is left below it once empty, deepest
    ## first. Kills nothing: a cgroup still populated after the wait is
    ## reported instead.
    if root.len == 0 or not dirExists(root):
      return ""
    if "/repro-memcap-test-" notin root:
      return "refusing to remove " & root
    var dirs: seq[string]
    for path in walkDirRec(root, yieldFilter = {pcDir}, followFilter = {pcDir}):
      dirs.add(path)
    for i in 0 ..< dirs.len:
      for j in i + 1 ..< dirs.len:
        if dirs[j].len > dirs[i].len: swap(dirs[i], dirs[j])
    dirs.add(root)
    proc events(dir: string): string =
      try: readFile(dir / "cgroup.events") except IOError, OSError: ""
    for dir in dirs:
      let deadline = epochTime() + 30.0
      while "populated 1" in events(dir) and epochTime() < deadline:
        sleep(50)
      if not removeEmptyCgroup(dir):
        return "cannot remove " & dir
    ""

proc field(output, key: string): string =
  for line in output.splitLines():
    if line.startsWith(key & "="):
      return line[key.len + 1 .. ^1]
  ""

proc systemdScopeProblem(): string =
  ## Why this host cannot start a delegated user scope, or "".
  if findExe("systemd-run").len == 0:
    return "no systemd-run on PATH"
  let (output, code) = execCmdEx("systemd-run --user --scope -q -- true")
  if code != 0:
    return "systemd-run --user --scope does not work here (exit " & $code &
      "): " & output.strip()
  ""

proc scopeBuild(inline: bool; work: string) =
  ## The engine's half of the scope case: one action that allocates
  ## 256 MiB under the run cap the environment sets, and what became of it.
  let run = buildWith(@[allocAction(getAppFilename(), work, "hog",
    "rqm-scope-" & (if inline: "inline" else: "helper"), 256,
    work / "launches")], work / ".repro-cache", inline)
  let hog = run.resultOf("hog")
  var own = ""
  try: own = readFile("/proc/self/cgroup").strip()
  except IOError, OSError: discard
  echo "engine_cgroup=/sys/fs/cgroup" & (if own.len > 3: own[3 .. ^1] else: "")
  echo "status=" & $hog.status
  echo "reason=" & hog.reason
  echo "applied=" & $hog.memoryCapApplied
  echo "note=" & hog.memoryCapNote
  echo "stderr=" & hog.stderr.replace("\n", " | ")

const SavedVariables = ["RUNQUOTA_SOCKET", "RUNQUOTA_ENDPOINT_SCOPE",
  "RUNQUOTA_MEMORY_CAP", "RUNQUOTA_CGROUP_ROOT", "RUNQUOTA_PARENT_LEASE",
  "RUNQUOTA_MEASUREMENT"]

suite "the memory cap on Reprobuild's actions: rules":
  test "the report says it of the action, for every basis":
    let learned = GrantMemoryCap(known: true, capBytes: 2048'u64 * MiB,
      basis: mcbLearned, previousMaxBytes: 1024'u64 * MiB,
      factorMilli: 2000'u32, budgetBytes: 16384'u64 * MiB)
    let killedBlock = FinishMemoryCap(present: true, capBytes: 2048'u64 * MiB,
      basis: mcbLearned, treePeakBytes: 2048'u64 * MiB, peakSource: mpsCgroup)
    check actionMemoryCapReport("compile foo", "cc:foo", learned, killedBlock,
      killed = true) ==
      "action compile foo exceeded its memory cap (command id cc:foo):\n" &
      "  cap 2.0 GiB = 2 × the largest successful peak, 1.0 GiB; peak " &
        "2.0 GiB; killed\n" &
      "  If this growth is expected:\n" &
      "    for one run:     RUNQUOTA_MEMORY_CAP=off   (or " &
        "RUNQUOTA_MEMORY_CAP=<size>)\n" &
      "    from now on:     runquota expect-growth cc:foo --to <size>\n" &
      "  Otherwise it is a memory regression: report it to the project " &
        "that owns\n" &
      "  this action.\n"
    # Advisory, and a cap reached without a kill: the same report, saying
    # what happened instead of "killed".
    var advisoryBlock = killedBlock
    advisoryBlock.exceededAdvisory = true
    let advisory = actionMemoryCapReport("compile foo", "cc:foo", learned,
      advisoryBlock, killed = false)
    check advisory.startsWith(
      "action compile foo exceeded its memory cap (command id cc:foo):\n")
    check "not killed (advisory)" in advisory
    var reachedBlock = killedBlock
    reachedBlock.capReached = true
    let reached = actionMemoryCapReport("compile foo", "cc:foo", learned,
      reachedBlock, killed = false)
    check reached.startsWith(
      "action compile foo reached its memory cap (command id cc:foo):\n")
    check "an allocation was refused at the cap" in reached
    # A run-size cap names the variable as its basis.
    let runSize = actionMemoryCapReport("t", "id", GrantMemoryCap(),
      FinishMemoryCap(present: true, capBytes: 64'u64 * MiB,
        basis: mcbRunSize, treePeakBytes: 64'u64 * MiB), killed = true)
    check "cap 64.0 MiB = RUNQUOTA_MEMORY_CAP for this run; peak 64.0 MiB; " &
      "killed" in runSize
    # The budget basis: not a regression, and still whom to tell.
    let budget = GrantMemoryCap(known: true, capBytes: 6656'u64 * MiB,
      basis: mcbBudget, factorMilli: 2000'u32, budgetBytes: 16384'u64 * MiB)
    let budgetText = actionMemoryCapReport("link app", "ld:app", budget,
      FinishMemoryCap(present: true, capBytes: 6656'u64 * MiB,
        basis: mcbBudget, treePeakBytes: 6656'u64 * MiB), killed = true)
    check budgetText.startsWith("action link app was stopped at the memory " &
      "free when it started (command id ld:app):\n")
    check "the host budget 16.0 GiB minus 9.5 GiB granted to other work" in
      budgetText
    check "This is not a regression." in budgetText
    check "regression: report it" notin budgetText
    check budgetText.endsWith("report it to the project\n  that owns this " &
      "action.\n")
    # No breach, no report.
    check actionMemoryCapReport("t", "id", learned, FinishMemoryCap(
      present: true, capBytes: 1, basis: mcbLearned), killed = false) == ""

  test "the policy: off is inactive, and the helper gets what the engine resolved":
    let off = memoryCapPolicy(mcmOff, "", false, CgroupRoot(state: crsOff))
    check not off.active
    check encodePolicyArg(off) == ""
    check memoryCapStateText(off).startsWith("off ")
    # With the host file's mode off there is nothing for `=off` to lift.
    check memoryCapStateText(memoryCapPolicy(mcmOff, "off", false,
      CgroupRoot(state: crsOff))) == "off"
    let root = CgroupRoot(state: crsExplicit, path: "/sys/fs/cgroup/t/r")
    let sized = memoryCapPolicy(mcmOff, "64M", false, root)
    check sized.active and sized.error.len == 0
    var back: ReproMemoryCapPolicy
    var problem = ""
    check decodePolicyArg(encodePolicyArg(sized), back, problem)
    check back.active and back.envValue == "64M" and back.hostMode == mcmOff
    check back.cgroupRoot.usable and back.cgroupRoot.path == root.path
    let nested = memoryCapPolicy(mcmKill, "", true, CgroupRoot(state: crsOff))
    check decodePolicyArg(encodePolicyArg(nested), back, problem)
    check back.nested and back.hostMode == mcmKill
    check "parent lease" in memoryCapStateText(nested)
    check not decodePolicyArg("bogus", back, problem)
    # The holder a caller's limited cgroup gives the root, and the reason
    # there is no root, survive the trip; a path with the old separator in
    # it is just a path; a path RunQuota would not accept is refused.
    let held = memoryCapPolicy(mcmAdvisory, "", false, CgroupRoot(
      state: crsExplicit, path: "/sys/fs/cgroup/a;b.scope/runquota",
      holder: "/sys/fs/cgroup/a;b.scope", holderLimit: "memory.max=1G",
      holderNote: "n"))
    check decodePolicyArg(encodePolicyArg(held), back, problem)
    check back.cgroupRoot.path == "/sys/fs/cgroup/a;b.scope/runquota"
    check back.cgroupRoot.holder == "/sys/fs/cgroup/a;b.scope"
    check back.cgroupRoot.holderLimit == "memory.max=1G"
    check back.cgroupRoot.holderNote == "n"
    # A root that is not the holder's own `runquota` child is refused.
    let strayRoot = memoryCapPolicy(mcmKill, "", false, CgroupRoot(
      state: crsExplicit, path: "/sys/fs/cgroup/elsewhere/runquota",
      holder: "/sys/fs/cgroup/a.scope", holderLimit: "memory.max=1G"))
    check not decodePolicyArg(encodePolicyArg(strayRoot), back, problem)
    check "not /sys/fs/cgroup/a.scope/runquota" in problem
    let rootless = memoryCapPolicy(mcmKill, "", false, CgroupRoot(
      state: crsOff, reason: "turned off by RUNQUOTA_CGROUP_ROOT=off"))
    check decodePolicyArg(encodePolicyArg(rootless), back, problem)
    check not back.cgroupRoot.usable
    check back.cgroupRoot.reason == "turned off by RUNQUOTA_CGROUP_ROOT=off"
    let escaping = memoryCapPolicy(mcmKill, "", false, CgroupRoot(
      state: crsExplicit, path: "/sys/fs/cgroup/../../etc"))
    check not decodePolicyArg(encodePolicyArg(escaping), back, problem)
    check problem.len > 0
    check not back.active
    check memoryCapPolicy(mcmOff, "lots", false, root).error.len > 0
    # A nested engine applies no cap to its actions.
    check not resolveActionMemoryCap(nested, GrantMemoryCap(known: true,
      capBytes: 64'u64 * MiB, basis: mcbLearned)).applies
    when defined(linux):
      check ", enforced: each capped action in a cgroup leaf of its own" in
        memoryCapStateText(sized)
      # Before any action ran with it, the header does not claim it.
      check ", will be enforced: " in memoryCapStateText(sized,
        applied = false)
      check memoryCapStateText(sized, "memory cap not enforced: x") ==
        "kill at 64M (RUNQUOTA_MEMORY_CAP=64M), memory cap not enforced: x"

when defined(linux):
  suite "the memory cap on Reprobuild's actions (Linux host)":
    var reason = ""
    let testRoot = delegatedMemoryRoot(reason)
    var prior = initTable[string, string]()
    for name in SavedVariables:
      if existsEnv(name): prior[name] = getEnv(name)
    # The engine under test is the outermost launcher of its actions: a
    # parent lease inherited from whatever runs this test would make it a
    # nested launcher, which applies no cap.
    delEnv("RUNQUOTA_PARENT_LEASE")
    delEnv("RUNQUOTA_MEASUREMENT")
    let app = getAppFilename()
    let scratch = createTempDir("repro-memcap", "")
    releaseDirAtProcessExit(scratch)
    var daemon = startCapDaemon(scratch)

    for inline in [true, false]:
      let path = if inline: "inline" else: "helper"
      test "test_rqm_reprobuild_reports_cap_exceeded (" & path & ")":
        if testRoot.len == 0:
          echo "SKIPPED: " & reason
          skip("no delegated cgroup v2 memory controller for this user: " &
            reason)
        else:
          let work = scratch / ("exceeded-" & path)
          let cache = work / ".repro-cache"
          let counter = work / "launches"
          createDir(work)
          let statsId = "rqm-exceeded-" & path
          let actions = @[allocAction(app, work, "hog", statsId, 256, counter)]
          withEnv("RUNQUOTA_CGROUP_ROOT", testRoot)
          withEnv("RUNQUOTA_MEMORY_CAP", "64M")
          let first = buildWith(actions, cache, inline)
          let hog = first.resultOf("hog")
          checkpoint "stderr: " & hog.stderr
          check first.memoryCap.active
          check hog.status == asFailed
          check hog.reason == MemoryCapExceededReason
          check ("action hog exceeded its memory cap (command id " & statsId &
            "):") in hog.stderr
          check "cap 64.0 MiB = RUNQUOTA_MEMORY_CAP for this run; peak " in
            hog.stderr
          check "; killed\n" in hog.stderr
          check "for one run:     RUNQUOTA_MEMORY_CAP=off" in hog.stderr
          check ("from now on:     runquota expect-growth " & statsId &
            " --to <size>") in hog.stderr
          check "report it to the project that owns\n  this action." in
            hog.stderr
          check hog.memoryCapNote == ""
          check first.memoryCapNotEnforced == ""
          check first.memoryCapApplied
          # It ran in a leaf of its own in the memory-only directory.
          check ranIn(work, "hog").startsWith(testRoot / "memory-capped" /
            "cap-")
          # Run once: the engine did not try it again.
          check launches(counter) == 1
          # Nothing published: with the cap lifted the action runs again
          # instead of being served from the cache, and succeeds; a third
          # build is then a cache hit (the action is cacheable at all).
          withEnv("RUNQUOTA_MEMORY_CAP", "off")
          let second = buildWith(actions, cache, inline)
          check second.resultOf("hog").status == asSucceeded
          check second.resultOf("hog").launched
          check launches(counter) == 2
          let third = buildWith(actions, cache, inline)
          check not third.resultOf("hog").launched
          check launches(counter) == 2

    test "a learned cap: an advisory breach warns, a kill names the previous maximum":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip("no delegated cgroup v2 memory controller for this user: " &
          reason)
      else:
        let work = scratch / "learned"
        let cache = work / ".repro-cache"
        let counter = work / "launches"
        createDir(work)
        let statsId = "rqm-learned"
        withEnv("RUNQUOTA_CGROUP_ROOT", testRoot)
        # A measured success: the daemon learns this command's maximum.
        withEnv("RUNQUOTA_MEMORY_CAP", "kill")
        let learnt = buildWith(@[allocAction(app, work, "small", statsId, 24,
          counter)], cache, inline = true)
        check learnt.resultOf("small").status == asSucceeded
        check learnt.resultOf("small").memoryCapWarning == ""
        # Advisory, past twice that maximum: a warning, not a failure.
        withEnv("RUNQUOTA_MEMORY_CAP", "advisory")
        let advised = buildWith(@[allocAction(app, work, "advised", statsId,
          192, counter)], cache, inline = true)
        let advisedResult = advised.resultOf("advised")
        checkpoint "warning: " & advisedResult.memoryCapWarning &
          " stderr: " & advisedResult.stderr
        check advisedResult.status == asSucceeded
        check advisedResult.reason != MemoryCapExceededReason
        check ("action advised exceeded its memory cap (command id " &
          statsId & "):") in advisedResult.memoryCapWarning
        check "× the largest successful peak, " in
          advisedResult.memoryCapWarning
        check "not killed (advisory)" in advisedResult.memoryCapWarning
        check memoryCapWarningLines(advised).len == 1
        let report = memoryCapReportJson(advised.memoryCap,
          advised.memoryCapNotEnforced, memoryCapWarningsJson(advised))
        check report["warnings"].len == 1
        check report["warnings"][0]["id"].getStr() == "advised"
        check report["mode"].getStr() == "advisory"
        # Enforced, past it: killed, and the report names the maximum.
        withEnv("RUNQUOTA_MEMORY_CAP", "kill")
        let killed = buildWith(@[allocAction(app, work, "killed", statsId,
          192, counter)], cache, inline = true)
        let killedResult = killed.resultOf("killed")
        checkpoint "stderr: " & killedResult.stderr
        check killedResult.status == asFailed
        check killedResult.reason == MemoryCapExceededReason
        check "× the largest successful peak, " in killedResult.stderr
        check "; killed\n" in killedResult.stderr

    for inline in [true, false]:
      let path = if inline: "inline" else: "helper"
      test "a cap that is not enforced is said once per build (" & path & ")":
        # Needs no cgroup root: it is about having none.
        block:
          let work = scratch / ("unenforced-" & path)
          let counter = work / "launches"
          createDir(work)
          withEnv("RUNQUOTA_CGROUP_ROOT", "off")
          withEnv("RUNQUOTA_MEMORY_CAP", "64M")
          let run = buildWith(@[
            allocAction(app, work, "one", "rqm-unenforced-1-" & path, 8,
              counter),
            allocAction(app, work, "two", "rqm-unenforced-2-" & path, 8,
              counter)],
            work / ".repro-cache", inline = inline)
          check run.resultOf("one").status == asSucceeded
          check run.resultOf("two").status == asSucceeded
          # The note names why there is no root, on the helper path too
          # (the helper gets the engine's resolution, reason included).
          let why = "memory cap not enforced: no cgroup root (turned off " &
            "by RUNQUOTA_CGROUP_ROOT=off)"
          check run.resultOf("one").memoryCapNote == why
          check run.memoryCapNotEnforced == why
          check not run.memoryCapApplied
          var notEnforcedLines = 0
          for line in memoryCapWarningLines(run):
            if "not enforced" in line: inc notEnforcedLines
          check notEnforcedLines == 1
          let header = runQuotaEnforcementHeaderLine(
            runQuotaEnforcementRecord(), run.memoryCap,
            run.memoryCapNotEnforced, run.memoryCapApplied)
          check ("their memory cap: kill at 64M (RUNQUOTA_MEMORY_CAP=64M), " &
            why) in header

    test "a helper too old for the memory cap is named as the cause":
      # THE STAND-INS, and why. A helper image older than the engine is one
      # whose parser does not know `--memory-cap`. Measured with a helper
      # built from the revision before the flag, it prints exactly
      # `Error: unknown flag '--memory-cap' for 'repro internal
      # runquota-helper'`, the usage, and exits 2, writing no result; a
      # script that prints that line and exits 2 stands in for it, since an
      # old image cannot be built inside this test. `false` (from PATH)
      # stands in for a helper that fails for any OTHER reason: it writes no
      # result and says nothing, and must not be blamed on the flag.
      # Needs no cgroup root: the engine says this before any placement.
      let falseExe = findExe("false")
      doAssert falseExe.len > 0, "test setup: no `false` on PATH"
      let shExe = findExe("sh")
      doAssert shExe.len > 0, "test setup: no `sh` on PATH"
      let work = scratch / "old-helper"
      createDir(work)
      let oldHelper = work / "old-helper.sh"
      writeFile(oldHelper, "#!" & shExe & "\n" &
        "echo \"Error: unknown flag '--memory-cap' for 'repro internal " &
        "runquota-helper'\" >&2\nexit 2\n")
      setFilePermissions(oldHelper, {fpUserRead, fpUserWrite, fpUserExec})
      withEnv("RUNQUOTA_CGROUP_ROOT", "off")
      withEnv("RUNQUOTA_MEMORY_CAP", "64M")
      let run = buildWith(@[allocAction(app, work, "old", "rqm-old", 8,
        work / "launches")], work / ".repro-cache", inline = false,
        helper = oldHelper)
      let old = run.resultOf("old")
      checkpoint "stderr: " & old.stderr
      check old.status == asFailed
      check "runquota helper did not write result" in old.stderr
      check "unknown flag '--memory-cap'" in old.stderr
      check "older than this engine refuses that option" in old.stderr
      let other = buildWith(@[allocAction(app, work, "other", "rqm-other", 8,
        work / "launches")], work / ".repro-cache-2", inline = false,
        helper = falseExe)
      let failed = other.resultOf("other")
      checkpoint "stderr: " & failed.stderr
      check failed.status == asFailed
      check "runquota helper did not write result" in failed.stderr
      check "older than this engine" notin failed.stderr

    test "an invalid RUNQUOTA_MEMORY_CAP refuses a leased build, not a bypassed one":
      # Needs no cgroup root: the refusal comes before any placement.
      let work = scratch / "invalid-variable"
      createDir(work)
      withEnv("RUNQUOTA_CGROUP_ROOT", "off")
      withEnv("RUNQUOTA_MEMORY_CAP", "bogus")
      var refusal = ""
      try:
        discard buildWith(@[allocAction(app, work, "leased", "rqm-invalid",
          8, work / "launches")], work / ".repro-cache", inline = true)
      except CatchableError as err:
        refusal = err.msg
      check "RUNQUOTA_MEMORY_CAP must be off, advisory, kill or a size" in
        refusal
      check launches(work / "launches") == 0
      # `--no-runquota`: no lease, no grant, no cap; the variable is ignored
      # and the header says the cap does not apply.
      let bypassed = buildWith(@[allocAction(app, work, "bypassed",
        "rqm-invalid-bypassed", 8, work / "launches")],
        work / ".repro-cache-bypass", inline = true, bypass = true)
      check bypassed.resultOf("bypassed").status == asSucceeded
      check bypassed.runQuotaBypassed
      let header = runQuotaEnforcementHeaderLine(runQuotaEnforcementRecord(),
        buildMemoryCapPolicyOf(bypassed), bypassed.memoryCapNotEnforced,
        bypassed.memoryCapApplied, bypassed.runQuotaBypassed)
      check "their memory cap: does not apply: this build ran its actions " &
        "without RunQuota leases" in header
      check "will be enforced" notin header

    for inline in [true, false]:
      let path = if inline: "inline" else: "helper"
      test "an engine inside a caller's limited, delegated scope caps inside it (" &
          path & ")":
        let noScope = systemdScopeProblem()
        if testRoot.len == 0 or noScope.len > 0:
          let why = if noScope.len > 0: noScope else: reason
          echo "SKIPPED: " & why
          skip("cannot run an engine in a delegated scope here: " & why)
        else:
          # The engine runs inside `systemd-run --user --scope -p
          # Delegate=yes -p MemoryMax=2G`, as a caller who capped a build on
          # purpose would start it. The cgroup root it is given lies outside
          # the scope, so RunQuota keeps the trees inside the scope
          # (`L/runquota`); the capped action goes to
          # `L/runquota/memory-capped/cap-...` and its own 64 MiB cap kills
          # it there. Mutation: the memory-only target (or, on the helper
          # path, the policy passed to the helper) dropping the holder --
          # the scope is never prepared and the action runs uncapped.
          let work = scratch / ("scope-" & path)
          createDir(work)
          withEnv("RUNQUOTA_CGROUP_ROOT", testRoot)
          withEnv("RUNQUOTA_MEMORY_CAP", "64M")
          let (output, code) = execCmdEx("systemd-run --user --scope -q " &
            "-p Delegate=yes -p MemoryMax=2G -- env -u " &
            "RUNQUOTA_AGENT_SESSION_SCOPE " & quoteShell(app) &
            " scope-build " & path & " " & quoteShell(work))
          checkpoint output
          check code == 0
          let scope = field(output, "engine_cgroup").parentDir
          check scope.endsWith(".scope")
          check field(output, "status") == "asFailed"
          check field(output, "reason") == MemoryCapExceededReason
          check field(output, "applied") == "true"
          check field(output, "note") == ""
          check ranIn(work, "hog").startsWith(scope / "runquota" /
            "memory-capped" / "cap-")

    test "off costs nothing: no cgroup is touched":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip("no delegated cgroup v2 memory controller for this user: " &
          reason)
      else:
        let work = scratch / "off"
        let counter = work / "launches"
        createDir(work)
        # A root that only a placement would create: with the cap off, the
        # build must never create it.
        let untouched = testRoot.parentDir / (testRoot.extractFilename &
          "-off.slice")
        withEnv("RUNQUOTA_CGROUP_ROOT", untouched)
        withEnv("RUNQUOTA_MEMORY_CAP", "")
        let run = buildWith(@[allocAction(app, work, "plain", "rqm-off", 8,
          counter)], work / ".repro-cache", inline = true)
        check run.resultOf("plain").status == asSucceeded
        check run.memoryCap.resolved
        check not run.memoryCap.active
        check not dirExists(untouched)
        check run.resultOf("plain").memoryCapNote == ""
        check "their memory cap: off " in runQuotaEnforcementHeaderLine(
          runQuotaEnforcementRecord(), run.memoryCap)
        if dirExists(untouched):
          discard removeEmptyCgroup(untouched)

    daemon.stop()
    for name in SavedVariables:
      if prior.hasKey(name): putEnv(name, prior[name])
      else: delEnv(name)
    if testRoot.len > 0:
      let problem = removeRoot(testRoot)
      doAssert problem.len == 0, problem
    removeDir(scratch)
