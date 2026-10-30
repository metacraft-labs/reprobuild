## ``repro system addon verify``: compare every ledger object with what is
## on the host. It only reads and reports.
##
## Its two report-only callers must never be able to fail what invoked
## them: the boot-time ``repro-addon-reassert.service`` (``--boot``) and
## the apt ``DPkg::Post-Invoke`` hook (``--after-dpkg``). In those modes it
## always exits 0 and its findings go to stdout (the journal, for the
## unit). Run by an operator without a mode flag, it exits 1 on drift.

import std/[os, strutils]

import ./addon_apply
import ./ledger

type
  VerifyReport* = object
    status*: string            ## ok | drift | degraded
    findings*: seq[string]
    notes*: seq[string]
      ## Informational, never drift: units the add-on shadows with
      ## ``collision = replace`` (spec §4.3 asks ``verify`` to report them
      ## after each package upgrade, because the package's unit may have
      ## changed underneath the add-on's copy).

proc runAddonVerify*(stateDir = DefaultStateDir): VerifyReport =
  ## ``degraded`` when the ledger itself cannot be read; ``drift`` when any
  ## object differs from its entry; ``ok`` otherwise.
  if not fileExists(ledgerCopyPath(stateDir)):
    return VerifyReport(status: "degraded",
      findings: @["no add-on ledger at " & ledgerCopyPath(stateDir)])
  var l: Ledger
  try:
    l = readLedger(ledgerCopyPath(stateDir))
  except CatchableError as e:
    return VerifyReport(status: "degraded", findings: @[e.msg])
  result.status = "ok"
  for e in l.entries:
    let d = try: observeDrift(e) except CatchableError as ex: ex.msg
    if d.len > 0:
      result.findings.add($e.class & " " & e.path & ": " & d)
    if e.class == lcUnit and e.collision == "replace":
      result.notes.add(e.unit & ": the add-on's /etc unit shadows the " &
        "package's (" & e.observation & "); check it after every upgrade " &
        "of that package")
  if result.findings.len > 0:
    result.status = "drift"

proc renderVerify*(r: VerifyReport): string =
  result = "repro-addon verify: " & r.status & "\n"
  for f in r.findings:
    result.add("  " & f & "\n")
  for n in r.notes:
    result.add("  note: " & n & "\n")
