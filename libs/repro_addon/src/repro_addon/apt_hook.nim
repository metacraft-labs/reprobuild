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

import std/[os, strutils, times]

import repro_infra/state_dir

import ./addon_apply
import ./base_identity
import ./collision
import ./generation0
import ./host_exec
import ./ledger
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

proc journal(priority, msg: string) =
  ## One journal line through ``logger`` (bsdutils, Essential); best
  ## effort and bounded, never raising.
  try:
    let exe = resolveHostTool(LoggerCandidates)
    if exe.len == 0: return
    discard runHostTool([exe, "-t", "repro-addon-apt-hook", "-p",
                         "user." & priority, "--", msg], timeoutSec = 5)
  except CatchableError:
    discard

proc appendEventLog*(path: string; lines: openArray[string]) =
  ## Append ``<UTC time> <line>`` for each line; best effort.
  if lines.len == 0: return
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
  except CatchableError:
    discard

proc runAfterDpkgCli*(stateDir = DefaultStateDir;
                      logPath = AptHookLogPath): int =
  ## The hook's entry point: report, record, exit 0.
  var r: AfterDpkgReport
  try:
    r = runAfterDpkgVerify(stateDir)
  except CatchableError as e:
    r = AfterDpkgReport(status: "degraded", findings: @[e.msg])
  stdout.write(renderAfterDpkg(r))
  if r.status == "ok":
    journal("info", "repro-addon apt hook: ok")
    return 0
  var lines = @[r.status & " " & $r.findings.len & " finding(s)"]
  journal("warning", "repro-addon apt hook: " & r.status & ", " &
          $r.findings.len & " finding(s)")
  for f in r.findings:
    lines.add("finding " & f)
    journal("warning", "repro-addon apt hook: " & f)
  appendEventLog(logPath, lines)
  0
