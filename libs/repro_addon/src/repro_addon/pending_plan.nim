## The switch's write-ahead plan.
##
## A switch decides everything at plan time: what each target is now
## (the observations the collision pass made), what it will be, which
## units are running. Steps 2 to 8 then change the host, and the host's
## state stops being evidence of what it was. So the decisions are written
## down BEFORE the first change (§7.2 step 1, together with the pending
## marker), and a switch interrupted anywhere -- by a crash, a reset or a
## refusal -- can be REPLAYED from them: the same decisions, the same
## writes, each one idempotent (a write of the bytes already there is a
## no-op, a destroy of an absent object is a no-op), to completion. The
## re-assert unit replays an interrupted switch at boot; if the replay
## cannot complete, the switch's own revert takes the host back to the
## generation `current` names (spec §7.7).
##
## On disk, under ``<state dir>/addon/pending.d/``:
##
## ====================  =====================================================
## ``target-own.profile``  the add-on's own objects the switch applies
## ``target-user.profile`` the operator's profile the switch applies
## ``from-user.profile``   the stored profile when the switch began
## ``from-ledger``         the ledger copy when the switch began
## ``plan``                one line per resource: its plan-time observations
##                         and decision (``SavedPlan``), plus the options
## ====================  =====================================================
##
## Every file is written with ``writeFileNoFollow`` (temporary file,
## fsync, rename, directory fsync) before the marker that makes it
## meaningful; a ``pending.d`` without a marker is a leftover and is
## overwritten by the next switch.

import std/[os, strutils]

import ./etc_write
import ./fingerprint

type
  PendingPlanError* = object of CatchableError

  SavedPlan* = object
    ## What the collision pass observed and decided for one resource.
    address*: string
    targetPath*: string
    replaced*: string
    newDirs*: seq[string]
    preLinks*: seq[string]
    baseUnitState*: string
    baseActiveState*: string
    observation*: string
    observedSha256*: string
    reason*: string
    verdict*: string
    collision*: string
    preserved*: string
    form*: string
    sysctlBefore*: string
    accountKey*: string
    accountBefore*: string
    groupBefore*: string
    diversion*: string        ## the path's dpkg diversion at plan time
    unitClass*: string        ## where systemd loaded the unit from

  PendingPlan* = object
    targetOwnText*: string
    targetUserText*: string
    fromUserText*: string
    fromLedgerText*: string
    reconcileDrift*: bool
    adopt*: seq[string]
    activeUnits*: seq[string]
      ## Units that were active when the switch was planned: a replay
      ## treats them as running (step 2 may have stopped them), so its
      ## transitions restart rather than leave them down.
    plans*: seq[SavedPlan]

const
  PendingPlanHeader* = "# repro-addon-pending-plan v1"
  SavedPlanFields = 20

proc pendingPlanDir*(stateDir: string): string =
  stateDir / "addon" / "pending.d"

proc joinList(xs: seq[string]): string = xs.join("\n")
proc splitList(s: string): seq[string] =
  if s.len == 0: @[] else: s.split('\n')

proc renderPlanFile(p: PendingPlan): string =
  result = PendingPlanHeader & "\n"
  result.add("reconcile-drift\t" & (if p.reconcileDrift: "1" else: "0") & "\n")
  result.add("adopt\t" & escapeField(joinList(p.adopt)) & "\n")
  result.add("active-units\t" & escapeField(joinList(p.activeUnits)) & "\n")
  for s in p.plans:
    let fields = [s.address, s.targetPath, s.replaced, joinList(s.newDirs),
      joinList(s.preLinks), s.baseUnitState, s.baseActiveState,
      s.observation, s.observedSha256, s.reason, s.verdict, s.collision,
      s.preserved, s.form, s.sysctlBefore, s.accountKey, s.accountBefore,
      s.groupBefore, s.diversion, s.unitClass]
    var line = "plan"
    for f in fields:
      line.add('\t')
      line.add(escapeField(f))
    result.add(line & "\n")

proc parsePlanFile(text: string; into: var PendingPlan) =
  let lines = text.splitLines()
  if lines.len == 0 or lines[0] != PendingPlanHeader:
    raise newException(PendingPlanError, "not a repro-addon pending plan")
  for i in 1 ..< lines.len:
    if lines[i].len == 0: continue
    let f = lines[i].split('\t')
    case f[0]
    of "reconcile-drift":
      if f.len != 2: raise newException(PendingPlanError,
        "malformed pending plan line " & $(i + 1))
      into.reconcileDrift = f[1] == "1"
    of "adopt":
      if f.len != 2: raise newException(PendingPlanError,
        "malformed pending plan line " & $(i + 1))
      into.adopt = splitList(unescapeField(f[1]))
    of "active-units":
      if f.len != 2: raise newException(PendingPlanError,
        "malformed pending plan line " & $(i + 1))
      into.activeUnits = splitList(unescapeField(f[1]))
    of "plan":
      if f.len != SavedPlanFields + 1:
        raise newException(PendingPlanError, "malformed pending plan line " &
          $(i + 1) & ": " & $(f.len - 1) & " fields, expected " &
          $SavedPlanFields)
      var u: seq[string]
      for x in f[1 .. ^1]: u.add(unescapeField(x))
      into.plans.add(SavedPlan(address: u[0], targetPath: u[1],
        replaced: u[2], newDirs: splitList(u[3]), preLinks: splitList(u[4]),
        baseUnitState: u[5], baseActiveState: u[6], observation: u[7],
        observedSha256: u[8], reason: u[9], verdict: u[10], collision: u[11],
        preserved: u[12], form: u[13], sysctlBefore: u[14],
        accountKey: u[15], accountBefore: u[16], groupBefore: u[17],
        diversion: u[18], unitClass: u[19]))
    else:
      raise newException(PendingPlanError, "unknown pending plan line " &
        $(i + 1) & ": " & f[0])

proc writePendingPlan*(stateDir: string; p: PendingPlan) =
  ## Persist ``p`` durably. Called before the pending marker is written.
  let dir = pendingPlanDir(stateDir)
  createDirsNoFollow(dir, 0o700)
  writeFileNoFollow(dir / "target-own.profile", p.targetOwnText, 0o600)
  writeFileNoFollow(dir / "target-user.profile", p.targetUserText, 0o600)
  writeFileNoFollow(dir / "from-user.profile", p.fromUserText, 0o600)
  writeFileNoFollow(dir / "from-ledger", p.fromLedgerText, 0o600)
  writeFileNoFollow(dir / "plan", renderPlanFile(p), 0o600)

proc readPendingPlan*(stateDir: string): PendingPlan =
  let dir = pendingPlanDir(stateDir)
  for f in ["target-own.profile", "target-user.profile", "from-user.profile",
            "from-ledger", "plan"]:
    if not fileExists(dir / f):
      raise newException(PendingPlanError, "the pending plan is incomplete: " &
        dir / f & " is missing")
  result.targetOwnText = readFile(dir / "target-own.profile")
  result.targetUserText = readFile(dir / "target-user.profile")
  result.fromUserText = readFile(dir / "from-user.profile")
  result.fromLedgerText = readFile(dir / "from-ledger")
  parsePlanFile(readFile(dir / "plan"), result)

proc hasPendingPlan*(stateDir: string): bool =
  fileExists(pendingPlanDir(stateDir) / "plan")

proc savedPlanFor*(p: PendingPlan; address: string): tuple[found: bool;
    plan: SavedPlan] =
  for s in p.plans:
    if s.address == address: return (true, s)
  (false, SavedPlan())

proc clearPendingPlan*(stateDir: string) =
  ## After the marker is gone: the plan means nothing without it.
  let dir = pendingPlanDir(stateDir)
  for f in ["plan", "target-own.profile", "target-user.profile",
            "from-user.profile", "from-ledger"]:
    discard removeLeafNoFollow(dir / f)
  discard removeEmptyDirNoFollow(dir)
