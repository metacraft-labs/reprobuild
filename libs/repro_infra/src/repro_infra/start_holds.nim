## Start holds and the live systemd reads around them, shared by the two
## switches that check units as systemd loaded them before anything starts
## them: the add-on's switch (``repro_addon/addon_apply``: the floor's
## effective-unit check, spec §10.1, and the carried-state cross-check) and
## a full ``runInfraApply`` (the carried-state cross-check, spec §11.1 and
## §13 decision 59).
##
## A hold is a runtime drop-in, ``/run/systemd/system/<unit>.d/<name>``
## (a template's directory for an instance: one hold covers every
## instance), that keeps the unit from running until it is removed:
##
## - ``hmAssert`` (``AssertPathExists=!/``): a start fails. The add-on's
##   switch starts units itself, after its check, so nothing else may.
## - ``hmCondition`` (``ConditionPathExists=!/``): a start is skipped and
##   reported done. A full apply's drivers ``enable --now`` and
##   ``restart`` units as they write them (``repro_elevation``); under this
##   hold those jobs succeed without running the unit, and the apply
##   starts what should run once its check has passed.
##
## systemd.unit(5): "Assert…= ... If an assertion setting is not met, the
## job fails"; "Condition…= ... a failing condition will not result in the
## unit being moved into a failure state".

import std/[os, posix, strutils, tables]

import ./host_exec

const HoldMutation {.strdefine: "reproAddonMutation".} = ""
  ## ``start-hold-removes-directory`` (A9's falsifying build): removing a
  ## hold deletes its whole directory. ``stale-start-holds-kept``: stale
  ## holds are not cleared.

type HoldMode* = enum
  hmAssert, hmCondition

const
  RuntimeUnitDir* = "/run/systemd/system"
  PersistentUnitDir* = "/etc/systemd/system"
  CarriedCheckHoldName* = "zz-repro-carried-check-hold.conf"
    ## The full apply's hold (``hmCondition``) for each unit the
    ## carried-state cross-check judges; in ``/etc`` for a unit the check
    ## refused, so a reboot does not start it either.

proc holdText*(mode: HoldMode; why: string): string =
  ## The drop-in of a hold: a comment saying why, and the setting.
  "# " & why.replace("\n", "\n# ") & "\n[Unit]\n" &
    (case mode
     of hmAssert: "AssertPathExists=!/"
     of hmCondition: "ConditionPathExists=!/") & "\n"

proc templateOf*(name: string): string =
  ## ``foo@.service`` for an instance ``foo@x.service``, else "".
  let at = name.find('@')
  let dot = name.rfind('.')
  if at > 0 and dot > at + 1: name[0 .. at] & name[dot .. ^1] else: ""

proc holdPath*(unit, name: string; dir = RuntimeUnitDir): string =
  ## Where the hold ``name`` for ``unit`` (its template's, for an
  ## instance) is written.
  let t = templateOf(unit)
  dir / ((if t.len > 0: t else: unit) & ".d") / name

proc writeHolds*(units: openArray[string]; name, text: string;
                 dir = RuntimeUnitDir): seq[string] =
  ## A hold for each unit; returns the files written.
  for u in units:
    let p = holdPath(u, name, dir)
    if p in result: continue
    createDir(parentDir(p))
    writeFile(p, text)
    result.add(p)

proc removeHolds*(holds: openArray[string]) =
  ## Remove each hold file, and its directory only when the hold was the
  ## last thing in it (``rmdir`` refuses a non-empty directory). A
  ## recursive removal would take every other drop-in in the directory
  ## with it (A9 review round 5, finding 5).
  for p in holds:
    if fileExists(p): removeFile(p)
    when HoldMutation == "start-hold-removes-directory":
      try: removeDir(parentDir(p), checkDir = false)
      except OSError: discard
    else:
      discard rmdir(parentDir(p).cstring)   # fails, harmlessly, when not empty

proc staleHolds*(name: string; dir = RuntimeUnitDir): seq[string] =
  ## Every hold ``name`` under ``dir``.
  if not dirExists(dir): return
  for kind, d in walkDir(dir):
    if kind != pcDir or not d.endsWith(".d"): continue
    let p = d / name
    if fileExists(p): result.add(p)

proc clearStaleHolds*(name: string; dir = RuntimeUnitDir): seq[string] =
  ## Every hold ``name`` an earlier switch left under ``dir`` -- one whose
  ## check refused, or a switch that died -- removed. Returns them.
  when HoldMutation == "stale-start-holds-kept":
    return
  result = staleHolds(name, dir)
  removeHolds(result)

# --- live systemd ------------------------------------------------------------
# Through ``host_exec`` (the distribution's systemctl by absolute path, a
# fixed environment), as the add-on runs it.

proc runSystemctlArgs*(args: openArray[string]): tuple[output: string, exitCode: int] =
  ## ``systemctl <args>``, its output and exit code; exit 127 when no
  ## systemctl is installed.
  try:
    let r = runSystemctl(args)
    (r.output, r.exitCode)
  except HostToolMissing as e:
    (e.msg, 127)

proc parseShowOutput*(text: string): Table[string, string] =
  ## ``systemctl show`` output: one ``Key=value`` per line. A property
  ## printed more than once keeps every value, one per line (the form
  ## ``ExecStart=`` and the like take).
  for line in text.splitLines():
    let eq = line.find('=')
    if eq <= 0: continue
    let k = line[0 ..< eq]
    let v = line[eq + 1 .. ^1]
    if k in result: result[k] = result[k] & "\n" & v
    else: result[k] = v

proc systemctlShow*(unit: string): Table[string, string] =
  ## The unit's properties as systemd loaded it. Raises ``OSError`` when
  ## systemctl fails.
  let r = runSystemctlArgs(["show", "--no-pager", "--", unit])
  if r.exitCode != 0:
    raise newException(OSError, "systemctl show " & unit & ": " &
      r.output.strip())
  parseShowOutput(r.output)

proc systemctlOrRaise*(args: openArray[string]) =
  let r = runSystemctlArgs(args)
  if r.exitCode != 0:
    raise newException(OSError, "systemctl " & args.join(" ") & ": " &
      r.output.strip())
