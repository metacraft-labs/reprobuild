## ``repro system addon verify --after-dpkg``: what the apt hook runs
## after every dpkg run (spec §7.8).
##
## The hook itself -- the ``DPkg::Post-Invoke`` line, its timeout and its
## exit-0 wrapper -- is generation 0's (``generation0.aptHookCommand``).
## This module is the verification it bounds. It reports, never refuses
## (spec §13 decision 4), and records three kinds of finding:
##
## - **a ledger object that changed**: the same comparison ``verify``
##   makes (``verify.runAddonVerify``), e.g. a package that unpacked a file
##   over a path the add-on owns;
## - **a package that now owns a ledger path**: dpkg (or ucf) lists the
##   path for a package the ledger's plan-time observation did not name --
##   a package installed or upgraded since the generation was applied
##   (the collision observer's own records, ``collision.CollisionDriver``);
## - **a changed vendor unit** behind a ``replace`` unit or a drop-in: its
##   file's digest differs from the one the current generation recorded in
##   its base identity (``base_identity.nim``).
##
## Each finding goes to stdout (apt prints it), to the journal (``logger``,
## identifier ``repro-addon-apt-hook``) and to the hook's event log
## (``generation0.AptHookLogPath``), which the next plan and the deploy
## agent's tick see as drift. A clean run records nothing but one journal
## line. Nothing here may raise past ``runAfterDpkgCli``: the hook's
## wrapper exits 0 anyway, but a verification that fails is recorded as
## ``verify-failed`` rather than as what it found.

import std/[os, posix, strutils, times]

import repro_infra/state_dir

import ./addon_apply
import ./base_identity
import ./collision
import ./generation0
import ./host_exec
import ./ledger
import ./mutations
import ./verify

type
  AfterDpkgReport* = object
    status*: string            ## ok | drift | degraded
    findings*: seq[string]     ## one line each
    notes*: seq[string]

const
  LoggerCandidates = [AptHookLoggerTool, "/bin/logger"]

proc vendorUnitFindings*(base: BaseIdentity): seq[string] =
  ## Every vendor unit whose file differs from the generation's record.
  when mutated("hook-ignores-vendor-units"):
    # FALSIFYING MUTATION: the third finding is never made.
    return @[]
  for v in base.vendorUnits:
    let now = vendorUnitDigest(vendorUnitFragment(v.unit))
    if now != v.sha256:
      result.add("vendor unit " & v.unit & " changed underneath the " &
        "add-on (" & (if v.fragment.len > 0: v.fragment else: "absent") &
        ": recorded " & v.sha256[0 ..< min(12, v.sha256.len)] & ", now " &
        now[0 ..< min(12, now.len)] & "); the add-on's drop-in or " &
        "replacement still applies -- check it")

proc runAfterDpkgVerify*(stateDir = DefaultStateDir;
                         driver: CollisionDriver = nil): AfterDpkgReport =
  ## The verification the hook runs. Read-only.
  let v = runAddonVerify(stateDir)
  result.status = v.status
  for f in v.findings: result.findings.add("changed: " & f)
  result.notes = v.notes
  if v.status == "degraded": return
  let l = readLedger(ledgerCopyPath(stateDir))
  let d = if driver != nil: driver else: detectCollisionDriver()
  for f in newOwnerFindings(l, d): result.findings.add(f)
  let current = readCurrentGenerationId(stateDir)
  if current.len > 0:
    for f in vendorUnitFindings(readGenerationBase(
        generationDir(stateDir, current))):
      result.findings.add(f)
  if result.findings.len > 0 and result.status == "ok":
    result.status = "drift"

proc renderAfterDpkg*(r: AfterDpkgReport): string =
  result = "repro-addon apt hook: " & r.status & "\n"
  for f in r.findings: result.add("  " & f & "\n")

const
  AptHookLogMaxBytes* = 1 shl 20
    ## The event log is rotated when it reaches 1 MiB: the file becomes
    ## ``apt-hook.log.1`` (replacing an older one), so the hook keeps at most
    ## about 2 MiB on the host. A finding stays reported by every run until
    ## it is resolved, so a long-unresolved one fills the log; rotation
    ## keeps the latest runs, which say the same.
  JournalTimeoutSec* = 5
    ## Upper bound on the whole journal hand-off of one run.

proc journal(priority: string; lines: openArray[string];
             tag = "repro-addon-apt-hook"; loggerExe = "") =
  ## Every line to the journal through ONE ``logger`` (util-linux /
  ## bsdutils), reading them from stdin, bounded by ``JournalTimeoutSec``
  ## in all. Best effort, never raising: the event log, written first, is
  ## the record.
  if lines.len == 0: return
  try:
    let exe = if loggerExe.len > 0: loggerExe
              else: resolveHostTool(LoggerCandidates)
    if exe.len == 0: return
    discard runHostTool([exe, "-t", tag, "-p",
                         "user." & priority], input = lines.join("\n") & "\n",
                        timeoutSec = JournalTimeoutSec)
  except CatchableError:
    discard

proc rotateEventLog*(path: string; maxBytes = AptHookLogMaxBytes) =
  ## Move ``path`` to ``path.1`` once it has reached ``maxBytes``.
  try:
    if fileExists(path) and getFileSize(path) >= maxBytes:
      moveFile(path, path & ".1")
  except CatchableError:
    discard

proc appendEventLog*(path: string; lines: openArray[string];
                     maxBytes = AptHookLogMaxBytes) =
  ## Append ``<UTC time> <line>`` for each line, flushed and fsynced;
  ## rotate first when the log is full. Best effort.
  if lines.len == 0: return
  rotateEventLog(path, maxBytes)
  let stamp = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  var text = ""
  for l in lines:
    text.add(stamp & " " & l.replace('\n', ' ') & "\n")
  try:
    createDir(parentDir(path))
    var f: File
    if open(f, path, fmAppend):
      defer: f.close()
      f.write(text)
      f.flushFile()
      discard posix.fsync(f.getFileHandle())
  except CatchableError:
    discard

proc runAfterDpkgCli*(stateDir = DefaultStateDir;
                      logPath = AptHookLogPath): int =
  ## The hook's entry point: report, record (event log first, then the
  ## journal), exit 0.
  var r: AfterDpkgReport
  try:
    r = runAfterDpkgVerify(stateDir)
  except CatchableError as e:
    r = AfterDpkgReport(status: "degraded", findings: @[e.msg])
  stdout.write(renderAfterDpkg(r))
  if r.status == "ok":
    journal("info", ["repro-addon apt hook: ok"])
    return 0
  var lines = @[r.status & " " & $r.findings.len & " finding(s)"]
  var jl = @["repro-addon apt hook: " & r.status & ", " & $r.findings.len &
             " finding(s)"]
  for f in r.findings:
    lines.add("finding " & f)
    jl.add("repro-addon apt hook: " & f)
  appendEventLog(logPath, lines)
  journal("warning", jl)
  0

# ---------------------------------------------------------------------------
# The deploy agent's view: the hook's events since its previous tick.
# ---------------------------------------------------------------------------

proc fileIdentity(path: string): string =
  ## ``<device>:<inode>`` of ``path``, "" when absent.
  var st: Stat
  if stat(path.cstring, st) != 0: return ""
  $st.st_dev & ":" & $st.st_ino

proc readFrom(path: string; offset: int64): string =
  try:
    var f: File
    if not open(f, path, fmRead): return ""
    defer: f.close()
    let size = getFileSize(f)
    if offset >= size: return ""
    f.setFilePos(offset)
    result = newString(int(size - offset))
    let n = f.readBuffer(addr result[0], result.len)
    result.setLen(max(n, 0))
  except CatchableError:
    result = ""

const AptHookCursorName* = "apt-hook.cursor"
  ## Under the agent's state directory: how far the agent has read the
  ## hook's event log.

proc hookEventsSince*(cursorPath: string; logPath = AptHookLogPath): seq[string] =
  ## Every event line the hook appended since the cursor in ``cursorPath``
  ## (``<device>:<inode> <offset>`` of the log as last read), then moves the
  ## cursor to the end. A rotation since (the log is a new file) is
  ## followed: the rest of the rotated file, then the new one from its
  ## start. With no cursor yet, everything in the log counts -- a first
  ## tick on a host that already has drift reports it. Never raises.
  var savedId = ""
  var savedOff = 0'i64
  try:
    let parts = readFile(cursorPath).strip().splitWhitespace()
    if parts.len == 2:
      savedId = parts[0]
      savedOff = parseBiggestInt(parts[1])
  except CatchableError:
    discard
  let curId = fileIdentity(logPath)
  var text = ""
  var newOff = 0'i64      # the cursor ends where THIS read ended, so an
                          # event appended meanwhile is read next time
  if savedId.len > 0 and savedId == curId:
    let t = readFrom(logPath, savedOff)
    text = t
    newOff = savedOff + t.len
  else:
    if savedId.len > 0 and fileIdentity(logPath & ".1") == savedId:
      text = readFrom(logPath & ".1", savedOff)
    let t = readFrom(logPath, 0)
    text.add(t)
    newOff = t.len
  for l in text.splitLines():
    if l.strip().len > 0: result.add(l)
  try:
    createDir(parentDir(cursorPath))
    writeFile(cursorPath & ".tmp", curId & " " & $newOff & "\n")
    moveFile(cursorPath & ".tmp", cursorPath)
  except CatchableError:
    discard

const AgentDriftLogPath* = "/var/lib/repro/system/addon/agent-drift.log"
  ## The deploy agent's evidence record of drift (spec §7.8, §9.2): one line
  ## per event a tick reported, in the hook log's format. Kept apart from
  ## the hook's own log because the agent reads that one from a cursor.

proc recordAgentDrift*(outcome: string; sequence: uint64;
                       events: openArray[string];
                       logPath = AgentDriftLogPath; loggerExe = "") =
  ## What one agent tick reported as drift: appended to the agent's event
  ## log first (fsynced, rotated like the hook's), then sent to the journal
  ## under ``repro-addon-agent`` at priority warning. Nothing on a tick with
  ## no drift; best effort, never raising, never changing the tick.
  if events.len == 0: return
  var lines = @["agent-tick " & outcome & " sequence " & $sequence & ": " &
                $events.len & " drift event(s)"]
  for e in events: lines.add("drift " & e)
  appendEventLog(logPath, lines)
  var jl: seq[string]
  for l in lines: jl.add("repro-addon agent: " & l)
  journal("warning", jl, tag = "repro-addon-agent", loggerExe = loggerExe)
