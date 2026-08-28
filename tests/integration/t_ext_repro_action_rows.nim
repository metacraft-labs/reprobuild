## M17: a REAL BUILD writes ``ext_repro_action`` rows, joined to RunQuota's
## execution spine.
##
## Gate (``reprobuild-specs/RunQuota-Observation-Store.milestones.org`` §M17):
## "A real build writes ``ext_repro_action`` rows (action id, cache outcome,
## weak/strong fingerprint, pool, output bytes, substitution) joined
## correctly to spine rows."
##
## NO MOCKS, AND NOTHING SUBSTITUTED. Every arm runs the real ``runquotad``
## binary over a real Unix-domain socket, the real ``repro`` binary building
## a real project, and reads the answer back through the real RQSP query
## interface. Nothing in this file writes a row: the rows asserted on were
## produced by a build that took leases and were read back over the wire,
## which is the only reading under which "a real build writes them" is a
## statement about the build rather than about this file.
##
## THE COMPATIBILITY-KEY ARM IS THE ONE THAT NEEDS THE SECOND BUILD.
## ``Build-Analytics-And-Optimization.md`` §"Observation Model" requires the
## action compatibility key to be COARSER than the action-cache key: "a
## source edit should not make all duration history useless". A test that
## builds the same input twice cannot see the difference -- both keys are
## unchanged and every assertion passes on an implementation that simply
## used the cache key for both. So the arm below EDITS AN INPUT between the
## two builds and requires the two keys to move differently: the strong
## fingerprint must change, and the compatibility key must not.

import std/[options, os, osproc, posix, sequtils, streams, strutils, tables,
    tempfiles, times, unittest]

import repro_test_support

import runquota_client
import runquota_core
import runquota_protocol

const
  ExtensionId = "repro_action"
  ActionOne = "m17-copy-0"
  ActionTwo = "m17-copy-1"
  Columns = ["action_id", "cache_outcome", "cache_miss_reason",
    "compatibility_key", "weak_fingerprint", "strong_fingerprint", "pool",
    "output_bytes", "substituted", "action_kind"]

proc repoRoot(): string = getCurrentDir()

proc publicReproBin(): string =
  ## SPELLED WITH THE LITERAL ``build/bin/repro``, AND THAT IS LOAD-BEARING.
  ## ``scripts/generate_test_edges.nim`` detects that substring and stamps
  ## ``requiresReproBinary`` on this test's generated edge, which is what
  ## declares the engine-built binary as a typed INPUT of the execute edge.
  ## Assembled from path components the detector cannot see, the edge carries
  ## no such input -- so an edit under ``libs/repro_*`` does not invalidate
  ## the cached result and the test reports the OLD binary's behaviour. That
  ## is the same false green as recompiling the test without rebuilding
  ## ``repro``, except the suite reaches it on its own.
  requireBinary(repoRoot() / addFileExt("build/bin/repro", ExeExt),
    "reprobuild.apps.repro")

proc socketIsBound(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

type DaemonHandle = object
  process: Process

proc startRunQuotaDaemon(socketPath, identityFile: string): DaemonHandle =
  let process = startProcess(requireRunQuotaDaemonBin(repoRoot()),
    args = @["--socket", socketPath,
             "--host-identity-file", identityFile,
             "--ambient-sample-interval-millis", "0"],
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if socketIsBound(socketPath): break
    sleep(25)
  # The daemon prints exactly three startup lines; reading them keeps the
  # pipe from filling and wedging it on a write nobody is draining.
  for _ in 0 ..< 3:
    discard process.outputStream.readLine()
  DaemonHandle(process: process)

proc stop(handle: var DaemonHandle) =
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  if handle.process.running:
    handle.process.kill()
    discard handle.process.waitForExit(5000)
  handle.process.close()

proc nimString(value: string): string = value.escape()

proc writeCopyProject(projectRoot, packageName: string; actionCount: int;
                      inputStem = "input") =
  ## A project of PROCESS actions, not built-in ones, and the difference is
  ## the whole reason the rows exist. A built-in ``fs.copyFile`` runs in
  ## the engine's own process and takes no RunQuota lease, so it produces
  ## no execution row and there is nothing for an extension row to be
  ## joined to. Only work RunQuota admitted appears on the spine.
  createDir(projectRoot / "src")
  for i in 0 ..< actionCount:
    writeFile(projectRoot / "src" / (inputStem & "-" & $i & ".txt"),
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
    let inputRel = "src/" & inputStem & "-" & $i & ".txt"
    let outputRel = "dist/output-" & $i & ".txt"
    body.add("      discard buildAction(" &
      nimString("m17-copy-" & $i) & ",\n" &
      "        " & packageName & ".executable(\"sh\").subcmd_2d_c(\n" &
      "          args = @[" & nimString(script) & ", " & nimString("sh") &
        ", " & nimString(inputRel) & ", " & nimString(outputRel) & "]),\n" &
      "        inputs = @[" & nimString(inputRel) & "],\n" &
      "        outputs = @[" & nimString(outputRel) & "],\n" &
      "        cacheable = true)\n")
  writeFile(projectRoot / "reprobuild.nim", body)

proc runBuild(projectRoot, tempRoot, workName, socketPath: string): string =
  ## A build that goes THROUGH RUNQUOTA. ``--no-runquota`` is deliberately
  ## absent: without a lease there is no execution row, and without an
  ## execution row there is nothing for an extension row to be joined to.
  requireSuccess(shellCommand(@[
    publicReproBin(), "build", projectRoot,
    "--daemon=off",
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / workName,
    "--action-cache-root=" & tempRoot / "action-cache",
    "--progress=quiet",
    "--log=quiet",
    "--measure=none"
  ], @[("RUNQUOTA_SOCKET", socketPath)]), repoRoot())

type ActionRow = object
  values: Table[string, string]

proc readActionRows(socketPath: string): seq[ActionRow] =
  ## Read back over the WIRE, scoped and hardware-qualified by the daemon
  ## exactly as any other consumer would get them.
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var client = connectDefault()
  defer: client.close()
  let answer = client.queryStats(statsSubjectExtensionRows,
    extensionId = ExtensionId, extensionColumns = Columns)
  for entry in answer.extensionRows:
    var row = ActionRow(values: initTable[string, string]())
    for i, name in entry.columns:
      row.values[name] = entry.values[i]
    # THE JOIN, CARRIED ON THE ROW. The daemon answers an extension query
    # by joining the extension table to `executions`; an entry that came
    # back without a spine key would mean the join produced a row the
    # spine does not have.
    row.values["__execution_id"] = entry.executionId
    row.values["__host_id"] = entry.hostId
    row.values["__stats_key"] = entry.statsKey
    row.values["__profile_id"] = entry.profile.profileId
    result.add(row)

proc waitForActionRows(socketPath: string; atLeast: int): seq[ActionRow] =
  ## The observation writer drains on a 25 ms tick, so a query issued
  ## immediately after the build can legitimately see nothing yet. Polling
  ## for a MINIMUM (never for a maximum) cannot turn an absent row into a
  ## present one.
  let deadline = epochTime() + 30.0
  while epochTime() < deadline:
    result = readActionRows(socketPath)
    if result.len >= atLeast:
      return
    sleep(100)

proc rowFor(rows: seq[ActionRow]; actionId: string): ActionRow =
  for row in rows:
    if row.values.getOrDefault("action_id") == actionId:
      return row
  raise newException(ValueError, "no ext_repro_action row for " & actionId)

suite "M17 ext_repro_action rows":
  when isNixSupported:
    test "a real build writes ext_repro_action rows joined to spine rows":
      let tempRoot = createTempDir("repro-m17-ext", "")
      let previousSocket = getEnv("RUNQUOTA_SOCKET", "")
      let socketRoot = getTempDir() / ("rq-m17-" & $getCurrentProcessId())
      removeDir(socketRoot)
      createDir(socketRoot)
      let socketPath = runquotaRendezvousDir(socketRoot) / "d.sock"
      let stateDir = socketRoot / "state"
      createDir(stateDir)
      var daemon = startRunQuotaDaemon(socketPath, stateDir / "host-id")
      defer:
        daemon.stop()
        putEnv("RUNQUOTA_SOCKET", previousSocket)
        removeDir(socketRoot)
        removeDir(tempRoot)

      let projectRoot = tempRoot / "project"
      writeCopyProject(projectRoot, "m17Actions", 2)
      discard runBuild(projectRoot, tempRoot, "work-1", socketPath)

      let rows = waitForActionRows(socketPath, 2)
      # NON-VACUITY: two actions ran, so a query that found nothing would
      # fail here rather than making every assertion below pass trivially.
      check rows.len >= 2

      let first = rowFor(rows, ActionOne)
      let second = rowFor(rows, ActionTwo)

      # --- joined correctly to spine rows -------------------------------
      # Each row carries the spine key the daemon joined it by, and the
      # two actions landed on DIFFERENT executions -- a join that attached
      # every extension row to one execution would pass an existence check
      # and fail this one.
      check first.values["__execution_id"].len > 0
      check second.values["__execution_id"].len > 0
      check first.values["__execution_id"] != second.values["__execution_id"]
      check first.values["__host_id"] == second.values["__host_id"]
      # OS-6: every answer is qualified by the hardware it describes.
      check first.values["__profile_id"].len > 0

      # --- the columns the gate names -----------------------------------
      check first.values["action_id"] == ActionOne
      check first.values["action_kind"].len > 0
      # A first build of a fresh cache root cannot hit, and the row says
      # WHY it did not.
      check first.values["cache_outcome"] in ["miss", "not-cacheable"]
      check first.values["weak_fingerprint"].len == 64
      check first.values["compatibility_key"].len == 64
      # Two different actions are different work, so their compatibility
      # keys must differ; a key that collapsed every action into one would
      # pool measurements that are not comparable.
      check first.values["compatibility_key"] !=
        second.values["compatibility_key"]
      check first.values["output_bytes"].len > 0
      check parseInt(first.values["output_bytes"]) > 0
      check first.values["substituted"] == "0"

    test "a source edit changes the cache key and NOT the compatibility key":
      # THE ARM THAT MAKES THE COARSENESS REQUIREMENT ASSERTED RATHER THAN
      # DESCRIBED. §"Observation Model": "a source edit should not make all
      # duration history useless. The compatibility key must therefore be
      # coarser than the action-cache key."
      let tempRoot = createTempDir("repro-m17-compat", "")
      let previousSocket = getEnv("RUNQUOTA_SOCKET", "")
      let socketRoot = getTempDir() / ("rq-m17c-" & $getCurrentProcessId())
      removeDir(socketRoot)
      createDir(socketRoot)
      let socketPath = runquotaRendezvousDir(socketRoot) / "d.sock"
      let stateDir = socketRoot / "state"
      createDir(stateDir)
      var daemon = startRunQuotaDaemon(socketPath, stateDir / "host-id")
      defer:
        daemon.stop()
        putEnv("RUNQUOTA_SOCKET", previousSocket)
        removeDir(socketRoot)
        removeDir(tempRoot)

      let projectRoot = tempRoot / "project"
      writeCopyProject(projectRoot, "m17Compat", 1)
      discard runBuild(projectRoot, tempRoot, "work-1", socketPath)
      let before = waitForActionRows(socketPath, 1)
      check before.len >= 1
      let firstRow = rowFor(before, ActionOne)

      # EDIT THE INPUT. Not a rename, not a flag change: the one edit the
      # specification names, and the one a developer makes all day.
      writeFile(projectRoot / "src" / "input-0.txt",
        "input 0 edited for M17\n")
      # THE SAME WORK ROOT AND THE SAME ACTION-CACHE ROOT as the first
      # build. A second work root would make the rebuild a fresh cache
      # lookup with no record to compare against, and "the cache key
      # moved" would then be a statement about the scratch directory
      # rather than about the edit.
      discard runBuild(projectRoot, tempRoot, "work-1", socketPath)

      let after = waitForActionRows(socketPath, 2)
      # NON-VACUITY: the edit really did cause a SECOND execution. Without
      # this the two comparisons below could be comparing a row with
      # itself, and every implementation would pass.
      check after.len >= 2
      var rowsForAction: seq[ActionRow] = @[]
      for row in after:
        if row.values.getOrDefault("action_id") == ActionOne:
          rowsForAction.add(row)
      check rowsForAction.len == 2
      check rowsForAction[0].values["__execution_id"] !=
        rowsForAction[1].values["__execution_id"]

      let keys = rowsForAction.mapIt(it.values["compatibility_key"])
      let reasons = rowsForAction.mapIt(it.values["cache_miss_reason"])

      # THE CACHE IDENTITY MOVED, AND THE ROW SAYS WHY. The second build
      # compared against the record the first one published and rejected
      # it BY INPUT -- which is the action-cache key ceasing to match.
      # Without this the equality below would be satisfied by a build that
      # never consulted the cache at all.
      check reasons.anyIt(it.contains("input"))
      # THE COMPATIBILITY KEY DID NOT. This is the whole clause: the cost
      # history for this action survives an edit to its source.
      check keys[0] == keys[1]
      check keys[0].len == 64

      # AND A RENAME DOES NOT MOVE IT EITHER, WHICH IS THE ARM THAT
      # SEPARATES THIS KEY FROM THE CACHE'S OWN COARSE ONE. Everything
      # above is satisfied by an implementation that simply reported the
      # WEAK fingerprint: it is computed over the action's canonical text,
      # so a content edit leaves it unchanged too. A rename changes the
      # argv and therefore the weak fingerprint -- cache identity moves --
      # while the work is the same copy it was before, so the
      # compatibility key must not.
      removeFile(projectRoot / "src" / "input-0.txt")
      writeCopyProject(projectRoot, "m17Compat", 1, inputStem = "renamed")
      discard runBuild(projectRoot, tempRoot, "work-1", socketPath)
      let renamed = waitForActionRows(socketPath, 3)
      check renamed.len >= 3
      var renamedRows: seq[ActionRow] = @[]
      for row in renamed:
        if row.values.getOrDefault("action_id") == ActionOne:
          renamedRows.add(row)
      # NON-VACUITY: the rename really did force a third execution.
      check renamedRows.len == 3

      # ASSERTED AS SETS, NOT BY POSITION. The query returns rows ordered
      # by the spine key, which is an opaque id -- so "the third row" is
      # not "the third build". A first draft indexed by position and
      # passed only because the ordering happened to agree; under a
      # mutation it reddened on the wrong assertion, which is a test that
      # reports the right verdict for the wrong reason.
      var distinctKeys: seq[string] = @[]
      var distinctWeak: seq[string] = @[]
      for row in renamedRows:
        let k = row.values["compatibility_key"]
        if k notin distinctKeys: distinctKeys.add(k)
        let w = row.values["weak_fingerprint"]
        if w notin distinctWeak: distinctWeak.add(w)
      # ONE compatibility key across all three builds: the original, the
      # content edit, and the rename.
      check distinctKeys == @[keys[0]]
      # TWO cache identities: the rename moved it, the content edit did
      # not. This is what makes the line above a statement about the
      # compatibility key rather than about the rename being invisible
      # everywhere -- and it is exactly the assertion an implementation
      # reporting the weak fingerprint as the compatibility key fails.
      check distinctWeak.len == 2
