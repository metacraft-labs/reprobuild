## ``repro system addon verify``: compare every ledger object with what is
## on the host. It only reads and reports.
##
## Its two report-only callers must never be able to fail what invoked
## them: the boot-time ``repro-addon-reassert.service`` (``--boot``) and
## the apt ``DPkg::Post-Invoke`` hook (``--after-dpkg``). In those modes it
## always exits 0 and its findings go to stdout (the journal, for the
## unit). Run by an operator without a mode flag, it exits 1 on drift.

import std/[os, posix, strutils]

import ./mutations

import ./addon_apply
import ./ledger
import ./record_dir

type
  VerifyReport* = object
    status*: string            ## ok | drift | degraded
    findings*: seq[string]
    notes*: seq[string]
      ## Informational, never drift: units the add-on shadows with
      ## ``collision = replace`` (spec §4.3 asks ``verify`` to report them
      ## after each package upgrade, because the package's unit may have
      ## changed underneath the add-on's copy).

proc runAddonVerify*(stateDir = DefaultStateDir;
                     logDir = AddonLogDir): VerifyReport =
  ## ``degraded`` when the ledger itself cannot be read; ``drift`` when any
  ## object differs from its entry; ``ok`` otherwise. ``logDir`` is the
  ## records directory's place, another only in a test.
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
  # §13 decision 178 (amended in A11 round 19): the directory of the
  # uninstall records is root's, writable by no group or other, not a link,
  # and the very directory bootstrap made (its identity, recorded in the
  # state) -- checked on a descriptor, as uninstall uses it. Anything there
  # that is not a directory is drift. Absence is drift once bootstrap has
  # recorded the directory's identity; on a host bootstrapped before that,
  # with nothing recorded, it is a note (its first use makes and records
  # it).
  when not mutated("verify-skips-log-dir"):
    let idFile = recordsDirIdentityPath(stateDir)
    bindRecordsDir(logDir, idFile, ledgerCopyPath(stateDir))
    defer: unbindRecordsDir(logDir)
    # Present at all counts: an empty or malformed identity file is not
    # "nothing recorded" (A11 round 20).
    let recorded = recordedIdentity(logDir).len > 0 or
      fileExists(idFile) or symlinkExists(idFile)
    var st: Stat
    if lstat(logDir.cstring, st) != 0:
      if recorded:
        result.findings.add(logDir & " is gone, though bootstrap made " &
          "it (its identity is recorded in " & idFile & "); inspect " &
          "/var/log, then remove " & idFile & " to let the next use make " &
          "and record it again")
      else:
        result.notes.add(logDir & " is absent; the add-on makes it " &
          "root's 0700 at its first use and records its identity")
    elif not S_ISDIR(st.st_mode):
      result.findings.add(logDir & " is not a directory (a link or " &
        "another kind of file); the add-on did not put it there: inspect " &
        "it and remove it")
    else:
      # The checked open refuses -- drift -- a directory whose identity
      # differs from the recorded one, an unusable identity record, and a
      # file system with no birth time (§13 decision 178, amended
      # 2026-11-16). On a host bootstrapped before the identity was
      # recorded, it records it now, and says so.
      let why = checkedDirRefusal(logDir)
      if why.len > 0:
        result.findings.add(logDir & ": " & why)
      elif recordedAtFirstUse(logDir) and
           not mutated("verify-first-use-silent"):
        result.notes.add(logDir & "'s identity was not recorded (a " &
          "host bootstrapped before the add-on recorded it); it is " &
          "recorded now, in " & idFile & " (" &
          recordedIdentity(logDir) & "): check that " & logDir &
          " is the directory bootstrap made")
  if result.findings.len > 0:
    result.status = "drift"

proc renderVerify*(r: VerifyReport): string =
  result = "repro-addon verify: " & r.status & "\n"
  for f in r.findings:
    result.add("  " & f & "\n")
  for n in r.notes:
    result.add("  note: " & n & "\n")
