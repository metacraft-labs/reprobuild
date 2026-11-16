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

var ONoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
var ODirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
proc cRename(a, b: cstring): cint {.importc: "rename", header: "<stdio.h>".}
  ## ``start-hold-removes-directory`` (A9's falsifying build): removing a
  ## hold deletes its whole directory. ``stale-start-holds-kept``: stale
  ## holds are not cleared. ``hold-written-unchecked``: a hold is written
  ## with ``writeFile``, whose failures on a full file system go unseen.

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

proc writeHoldFile*(path, text: string) =
  ## ``text`` at ``path``, every step checked (A9 review round 14, finding
  ## 1): a temporary file in the same directory is opened, written in full,
  ## ``fsync``-ed and closed, each result checked, renamed over ``path``,
  ## the directory ``fsync``-ed, and the file read back and compared. Nim's
  ## ``writeFile`` buffers in stdio and discards ``fclose``'s result, so on
  ## a full file system it leaves an empty file and raises nothing
  ## (write(2), fsync(2), close(2): "a failure to close ... may be the only
  ## indication of a ... write error"). Raises ``OSError`` on any failure,
  ## leaving no temporary file.
  when HoldMutation == "hold-written-unchecked":
    # Falsifying build: round 13's plain writeFile.
    writeFile(path, text)
    return
  let dir = parentDir(path)
  let tmp = dir / ("." & extractFilename(path) & ".tmp")
  discard unlink(tmp.cstring)
  let fd = posix.open(tmp.cstring, O_WRONLY or O_CREAT or O_EXCL or ONoFollow or O_CLOEXEC, 0o644)
  if fd < 0: raiseOSError(osLastError(), "create " & tmp)
  var ok = false
  try:
    var off = 0
    while off < text.len:
      let n = posix.write(fd, unsafeAddr text[off], text.len - off)
      if n <= 0: raiseOSError(osLastError(), "write " & tmp)
      off += n
    if fsync(fd) != 0: raiseOSError(osLastError(), "fsync " & tmp)
    let c = posix.close(fd)
    if c != 0: raiseOSError(osLastError(), "close " & tmp)
    if cRename(tmp.cstring, path.cstring) != 0:
      raiseOSError(osLastError(), "rename " & tmp & " -> " & path)
    ok = true
  finally:
    if not ok:
      discard posix.close(fd)       # harmless EBADF when already closed
      discard unlink(tmp.cstring)
  let dfd = posix.open(dir.cstring, O_RDONLY or ODirectory or O_CLOEXEC)
  if dfd < 0: raiseOSError(osLastError(), "open " & dir)
  let synced = fsync(dfd)
  let err = osLastError()
  discard posix.close(dfd)
  if synced != 0: raiseOSError(err, "fsync " & dir)
  var back = ""
  try: back = readFile(path)
  except IOError as e: raise newException(OSError, "read back " & path & ": " & e.msg)
  if back != text:
    raise newException(OSError, path & " does not hold what was written (" &
      $back.len & " of " & $text.len & " bytes)")

proc removeDurably*(path: string) =
  ## Remove ``path`` and ``fsync`` its directory, so the removal of an
  ## emptied record survives a crash (A13 review round 12): a record
  ## removed only in the page cache comes back after a power loss and names
  ## units already dealt with. Nothing when ``path`` does not exist; raises
  ## ``OSError`` when the directory cannot be synced.
  if not fileExists(path): return
  removeFile(path)
  let dir = parentDir(path)
  let dfd = posix.open(dir.cstring, O_RDONLY or ODirectory or O_CLOEXEC)
  if dfd < 0: raiseOSError(osLastError(), "open " & dir)
  let synced = fsync(dfd)
  let err = osLastError()
  discard posix.close(dfd)
  if synced != 0: raiseOSError(err, "fsync " & dir)

proc writeHolds*(units: openArray[string]; name, text: string;
                 dir = RuntimeUnitDir): seq[string] =
  ## A hold for each unit, each written by ``writeHoldFile``; returns the
  ## files written. Raises ``OSError`` on the first that cannot be.
  for u in units:
    let p = holdPath(u, name, dir)
    if p in result: continue
    createDir(parentDir(p))
    writeHoldFile(p, text)
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

proc heldUnitOf*(hold: string): string =
  ## The unit a hold file is for: ``<dir>/<unit>.d/<name>`` names ``<unit>``
  ## (a template's for every instance it covers).
  let d = extractFilename(parentDir(hold))
  if d.endsWith(".d"): d[0 ..< d.len - 2] else: ""

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
