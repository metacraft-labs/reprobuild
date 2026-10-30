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
  if result.findings.len > 0:
    result.status = "drift"

proc renderVerify*(r: VerifyReport): string =
  result = "repro-addon verify: " & r.status & "\n"
  for f in r.findings:
    result.add("  " & f & "\n")
