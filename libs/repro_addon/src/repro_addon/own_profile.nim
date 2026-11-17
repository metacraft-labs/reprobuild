## The add-on's stored own profile (generation 0's objects, in the
## canonical text ``generation0.renderOwnProfile`` writes) as text to edit:
## a unit's inline content, a file's source, and the migration that
## re-renders the objects this build renders differently (A11 review
## findings 2 and 8). Shared by every path that rewrites generation 0
## (``agent-repin``, ``evidence-enrol``, the switch).

import std/[os, strutils]

import ./fingerprint
import ./generation0
import ./mutations

const UnitBlockHead* = "systemd.systemUnit {\n  name = \""

proc blockBounds*(own, head: string): tuple[a, b: int] =
  ## The ``[a, b)`` span of the canonical block that starts with ``head``
  ## (``renderOwnProfile``'s layout: a block ends at the first "\n}\n").
  let a = own.find(head)
  if a < 0: return (-1, -1)
  let e = own.find("\n}\n", a)
  if e < 0:
    raise newException(ValueError, "the own profile's block at byte " & $a &
      " is not terminated")
  (a, e + 3)

proc unitContentOf*(own, unit: string): string =
  let (a, b) = blockBounds(own, UnitBlockHead & unit & "\"\n")
  if a < 0: return ""
  let block0 = own[a ..< b]
  let k = block0.find("  content = \"")
  let e = block0.rfind("\"\n  enabled = ")
  if k < 0 or e < 0: return ""
  block0[k + "  content = \"".len ..< e]


proc ownObserved*(own: string): bool =
  ## Generation 0 carries the egress observer.
  (UnitBlockHead & EgressUnit & "\"\n") in own

proc replaceUnitContent*(own, unit, content: string): string =
  ## ``own`` with ``unit``'s inline content replaced (unchanged when the
  ## own profile does not carry the unit).
  let old = unitContentOf(own, unit)
  if old.len == 0: return own
  let (a, b) = blockBounds(own, UnitBlockHead & unit & "\"\n")
  let blk = own[a ..< b]
  own[0 ..< a] & blk.replace("  content = \"" & old & "\"",
                             "  content = \"" & content & "\"") & own[b .. ^1]

proc fileBlockSourceOf*(own, path: string): string =
  ## The ``sourceLocal`` of the own profile's ``fs.systemFile`` at ``path``.
  let (a, b) = blockBounds(own, "fs.systemFile {\n  path = \"" & path & "\"\n")
  if a < 0: return ""
  for l in own[a ..< b].splitLines():
    let t = l.strip()
    if t.startsWith("sourceLocal = \""): return t["sourceLocal = \"".len ..< ^1]
  ""

proc replaceFileSource*(own, path, source: string): string =
  let old = fileBlockSourceOf(own, path)
  if old.len == 0: return own
  own.replace("  sourceLocal = \"" & old & "\"", "  sourceLocal = \"" & source & "\"")

proc egressNftBinaryOf*(unit: string): string =
  ## The ``nft`` the egress observer unit runs (its ``ExecStop=`` line).
  for l in unit.splitLines():
    if l.startsWith("ExecStop=") and l.endsWith(" delete table inet repro_addon_egress"):
      return l["ExecStop=".len ..< l.len - " delete table inet repro_addon_egress".len]
  ""

proc refreshEgressUnit*(own: string): string =
  ## ``own`` with the egress observer unit naming the SHA-256 of the
  ## ``egress.nft`` the own profile installs (its files-prefix source is
  ## named by it), so a changed table restarts the unit (A11 review round
  ## 2). Unchanged when the own profile has no observer.
  result = own
  let unit = unitContentOf(own, EgressUnit)
  if unit.len == 0: return
  let source = fileBlockSourceOf(own, EgressNftPath)
  let nft = egressNftBinaryOf(unit)
  if source.len == 0 or nft.len == 0: return
  when mutated("egress-unit-ignores-table"):
    return
  let fresh = egressUnit(nft, extractFilename(source))
  if fresh != unit:
    result = replaceUnitContent(result, EgressUnit, fresh)

proc migrateOwnProfile*(own: string): string =
  ## Generation 0's own objects re-rendered by this build where a fix
  ## changed them, from what they were rendered from (A11 review findings 2
  ## and 8): the fetch unit through its one renderer, with the inputs its
  ## installed bytes name and the egress observer when generation 0 has it;
  ## the evidence shipping path unit (``DirectoryNotEmpty=``, the drill's
  ## D1). Idempotent: an own profile this build rendered is returned as is.
  result = own
  let fetch = unitContentOf(own, AgentFetchUnit)
  if fetch.len > 0:
    let exe = fetchUnitExe(fetch)
    if exe.len > 0:
      result = replaceUnitContent(result, AgentFetchUnit,
        agentFetchUnit(exe, fetchUnitInputsOf(fetch), ownObserved(own)))
  result = refreshEgressUnit(result)
  # The shipping unit's start timeout (A11 review round 2): only its
  # ``TimeoutStartSec=`` line, which this build renders from one constant.
  let ship = unitContentOf(result, EvidenceShipUnit)
  if ship.len > 0:
    var lines = ship.split('\n')
    for l in lines.mitems:
      if l.startsWith("TimeoutStartSec="):
        l = "TimeoutStartSec=" & $EvidenceShipTimeoutStartSec
    let fixed = lines.join("\n")
    if fixed != ship:
      result = replaceUnitContent(result, EvidenceShipUnit, fixed)
  when not mutated("path-unit-not-migrated"):
    if unitContentOf(result, EvidenceShipPathUnit).len > 0:
      result = replaceUnitContent(result, EvidenceShipPathUnit,
                                  evidenceShipPathUnit())
  # The boot-hold unit as this build renders it (A9 review round 16,
  # finding 10: the hardened script), on a host that has it.
  if unitContentOf(result, BootHoldUnit).len > 0:
    result = replaceUnitContent(result, BootHoldUnit, bootHoldUnit())


proc reassertExeOf*(reassertUnitText: string): string

proc missingGeneration0Objects*(own: string): seq[OwnObject] =
  ## Generation 0's objects this build installs that ``own`` lacks (§13
  ## decision 159): the boot-hold unit, which an engine before it never
  ## wrote, rendered exactly as a bootstrap by this build renders it. Empty
  ## for an own profile without a re-assert unit (not one generation 0
  ## wrote).
  if unitContentOf(own, ReassertUnit).len == 0: return
  if (UnitBlockHead & BootHoldUnit & "\"\n") notin own:
    result.add(OwnObject(kind: ookUnit, unit: BootHoldUnit,
      path: unitPath(BootHoldUnit), content: bootHoldUnit(), enabled: true))
  # §13 decision 157: the boot-confirm unit, on the re-assert unit's engine
  # (``repointReassert`` moves both).
  if (UnitBlockHead & BootConfirmUnit & "\"\n") notin own:
    let exe = reassertExeOf(unitContentOf(own, ReassertUnit))
    if exe.len > 0:
      result.add(OwnObject(kind: ookUnit, unit: BootConfirmUnit,
        path: unitPath(BootConfirmUnit), content: bootConfirmUnit(exe),
        enabled: true))

type
  PathProbe* = proc (path: string): tuple[present: bool; sha256: string]
    ## Whether a path is there (a link counts, unfollowed) and, for a
    ## regular file, the SHA-256 of its bytes ("" otherwise).
  RecordedDigest* = proc (path: string): string
    ## The digest the committed ledger records for a path the add-on
    ## wrote, "" when the ledger does not name it.

proc engineExeIn*(unitText: string): string

proc addMissingGeneration0*(own: string; candidates: openArray[OwnObject];
                            probe: PathProbe; recorded: RecordedDigest;
                            known: openArray[string] = []): string =
  ## ``own`` with each of ``candidates`` (``missingGeneration0Objects``)
  ## added, so the switch installs it like every generation-0 object, with
  ## its ledger entry and fingerprint (§13 decision 159, the upgrade path). It only adds: an
  ## object already in ``own`` is never passed, and the switch's plan
  ## leaves every other object as it was. Every candidate's path is
  ## checked before any is added, so a refusal adds nothing: a path that
  ## is there is accepted only when the committed ledger records it and
  ## its bytes are exactly the object's -- anything else is not the
  ## add-on's to write over (§4.3), and raises ``ValueError`` naming it.
  ## Idempotent: an own profile carrying the objects has no candidates.
  ## A unit that runs the add-on binary may be there as rendered for
  ## another engine ``known`` lists (the ledger's add-on binary prefixes):
  ## a rollback to a generation from before the unit existed, on a host a
  ## later engine already gave it (A9 review round 17, finding 1).
  for o in candidates:
    let p = probe(o.path)
    if not p.present: continue
    var want = sha256Hex(o.content)
    let rec = recorded(o.path)
    let exe = engineExeIn(o.content)
    if exe.len > 0 and p.sha256 != want and rec == p.sha256:
      for k in known:
        if sha256Hex(o.content.replace(exe, k)) == p.sha256:
          want = p.sha256
          break
    if p.sha256 != want or rec != want:
      raise newException(ValueError, o.path & " is there and is not " &
        "generation 0's " & o.unit & " (" &
        (if p.sha256.len == 0: "not a regular file"
         elif rec.len == 0: "the ledger does not record it"
         else: "its bytes differ from the object") &
        "); generation 0 is not upgraded over it. Remove it, or move it " &
        "aside, and apply again")
  result = own
  when mutated("gen0-not-upgraded"):
    # FALSIFYING MUTATION: a host bootstrapped by an earlier engine never
    # gets the objects this build added to generation 0.
    return
  # Beside the re-assert unit, in order, where a bootstrap by this build
  # puts them.
  var blks = ""
  for o in candidates: blks.add(renderOwnProfile(@[o], ""))
  if blks.len == 0: return
  let (_, b) = blockBounds(result, UnitBlockHead & ReassertUnit & "\"\n")
  if b < 0:
    result.add(blks)
  else:
    let at = if result.continuesWith("\n", b): b + 1 else: b
    result = result[0 ..< at] & blks & result[at .. ^1]

proc reassertExeOf*(reassertUnitText: string): string =
  ## The add-on binary the re-assert unit runs (its ``ExecStart=`` shell
  ## tests it with ``[ -x <exe> ]``), "" when the text names none.
  const Probe = "ExecStart=/bin/sh -c 'if [ -x "
  for l in reassertUnitText.splitLines():
    if l.startsWith(Probe):
      let rest = l[Probe.len .. ^1]
      let e = rest.find(" ]")
      if e > 0: return rest[0 ..< e]
  ""

const RepointedUnits* = [ReassertUnit, BootConfirmUnit, AgentApplyUnit,
                         AgentFetchUnit]
  ## The generation-0 units whose engine an apply re-points (§13 decision
  ## 164, and the owner's decision of 2026-11-16 that extends it to the
  ## agent's two units): each runs the add-on binary on a path a later
  ## engine's holds and recovery depend on. The secrets, evidence,
  ## store-verify and egress-check units, the apt hook and the profile.d
  ## script keep the engine that bootstrapped the host (a residual).

proc engineExeIn*(unitText: string): string =
  ## The add-on binary a generation-0 unit's text runs: the first
  ## ``<store>/prefixes/.../bin/repro`` in it, "" when it names none.
  let a = unitText.find(StoreRoot & "/prefixes/")
  if a < 0: return ""
  let b = unitText.find("/bin/repro", a)
  if b < 0: return ""
  unitText[a ..< b + "/bin/repro".len]

type
  RepointOutcome* = object
    own*: string        ## the own profile with the units re-rendered
    changed*: bool      ## some unit's text differs from ``own``'s
    exe*: string        ## the engine the units run after the re-point;
                        ## "" when no re-pointed unit is installed
    onDisk*: string     ## the engine the installed units ran before

proc repointStoredTexts*(storedOnHost, target: string): seq[string] =
  ## The texts besides the target's (``repointEngine``'s ``stored``) a unit
  ## on disk may have been rendered from: the own profile as stored on the
  ## host (``storedOnHost``, what the committed generation wrote) and this
  ## build's migration of it (``migrateOwnProfile``). Never the target
  ## alone: an apply whose target is a new own profile (`agent-repin`,
  ## `evidence-enrol`) re-renders the very units it is about to re-point,
  ## so the target says nothing about the bytes on disk (A9 review round
  ## 19, B1). Empty when the host stores none (a test's own root).
  when mutated("repoint-stored-from-target"):
    # FALSIFYING MUTATION: round 18's choice -- the target stands in for
    # the stored text whenever there is one, so a re-pin or an enrol of
    # an agent host is refused.
    if target.len > 0: return @[target, migrateOwnProfile(target)]
  if storedOnHost.len == 0: return
  result.add(storedOnHost)
  let migrated = migrateOwnProfile(storedOnHost)
  if migrated != storedOnHost: result.add(migrated)

proc repointEngine*(own, engineExe: string; known: openArray[string];
                    probe: PathProbe; recorded: RecordedDigest;
                    stored: openArray[string] = []): RepointOutcome =
  ## ``own`` with each of ``RepointedUnits`` it carries rendered for the
  ## newest engine (§13 decision 164 as amended by A9 review round 17,
  ## finding 1): a host an earlier engine bootstrapped runs the boot
  ## re-assertion, the boot confirm and the agent's ticks with that engine,
  ## which knows none of the holds later engines write.
  ##
  ## ``own`` is the target generation's own profile; on a revert or a
  ## rollback it names an older engine than the units on disk. ``stored``
  ## holds the other texts the units on disk may have been rendered from:
  ## the own profile as stored on the host and this build's migration of it
  ## (``repointStoredTexts``; A9 review rounds 18 and 19, B1). A unit on
  ## disk is accepted when the committed ledger records exactly its bytes
  ## and they are the unit's text in ``own`` or in one of ``stored``, with
  ## that text's engine replaced by one of the engines ``known`` lists (the
  ## binary prefixes the committed ledger records, oldest first), by
  ## ``engineExe``, or left as it is -- the known fingerprint set, and
  ## nothing wider. Anything else is refused (``ValueError``) before any
  ## unit is changed, never written over.
  ##
  ## The engine the units run afterwards is ``engineExe`` -- the static
  ## add-on image of the running engine, "" when there is none (§13
  ## decision 174) -- unless that would point them backwards: an engine
  ## the ledger records before the one on disk is older, and the units keep
  ## the one on disk. A revert or a rollback therefore keeps the newest
  ## re-pointed engine. Idempotent; a unit not installed is left as ``own``
  ## has it (an image being assembled, a test's own root).
  result.own = own
  var found: seq[tuple[unit, cur, ownExe, disk: string]]
  # Units of ``own`` no file is installed for yet (generation 0's upgrade
  # path adds them in this switch): rendered for the engine the others run,
  # with nothing on disk to check.
  var absentUnits: seq[tuple[unit, cur, ownExe: string]]
  for u in RepointedUnits:
    let cur = unitContentOf(own, u)
    if cur.len == 0: continue
    let ownExe = engineExeIn(cur)
    if ownExe.len == 0: continue
    let path = unitPath(u)
    let p = probe(path)
    if not p.present:
      absentUnits.add((u, cur, ownExe))
      continue
    let rec = recorded(path)
    var disk = ""
    # The bytes on disk are those of the target's text, or of the own
    # profile as stored -- written by the engine that rendered it, perhaps
    # with another renderer than this build's -- or of this build's
    # migration of it (A9 review rounds 18 and 19, B1: a fetch unit an
    # engine with another fetch renderer wrote, and an apply whose target
    # is a new own profile, as `agent-repin` and `evidence-enrol` pass).
    var renderings = @[(cur, ownExe)]
    when not mutated("repoint-migrated-only"):
      for st in stored:
        let storedCur = unitContentOf(st, u)
        if storedCur.len == 0: continue
        var dup = false
        for (t, _) in renderings:
          if t == storedCur: dup = true
        if dup: continue
        let storedExe = engineExeIn(storedCur)
        if storedExe.len > 0: renderings.add((storedCur, storedExe))
    if p.sha256.len > 0 and rec == p.sha256:
      block search:
        for (text, textExe) in renderings:
          for x in @known & @[engineExe, ownExe, textExe]:
            if x.len > 0 and sha256Hex(text.replace(textExe, x)) == p.sha256:
              disk = x
              break search
    if disk.len == 0:
      raise newException(ValueError, path & " is not a " & u & " the " &
        "add-on installed (" &
        (if p.sha256.len == 0: "not a regular file"
         elif rec != p.sha256: "the ledger does not record its bytes"
         else: "its bytes are no rendering of the generation's unit for an " &
               "engine the ledger records") &
        "); it is not re-pointed. Restore it, or re-bootstrap")
    found.add((u, cur, ownExe, disk))
  if found.len == 0:
    # Nothing installed to keep: an image being assembled or a test's own
    # root keeps the own profile's engine; a host where only the units
    # this switch adds are missing gets the applying engine's image.
    if engineExe.len == 0 or absentUnits.len == 0: return
    when mutated("reassert-not-repointed"):
      return
    result.exe = engineExe
    for a in absentUnits:
      let want = a.cur.replace(a.ownExe, engineExe)
      if want != a.cur:
        result.own = replaceUnitContent(result.own, a.unit, want)
        result.changed = true
    return
  # The newest engine on disk, by the order the ledger recorded them in.
  let order = @known
  proc age(x: string): int =
    for i, k in order:
      if k == x: return i
    high(int)        # not recorded yet: newer than everything recorded
  var newestOnDisk = found[0].disk
  for f in found:
    if age(f.disk) > age(newestOnDisk) or
        (age(f.disk) == age(newestOnDisk) and f.disk == engineExe):
      newestOnDisk = f.disk
  result.onDisk = newestOnDisk
  result.exe =
    if engineExe.len > 0 and age(engineExe) >= age(newestOnDisk): engineExe
    else: newestOnDisk
  when mutated("repoint-backwards"):
    # FALSIFYING MUTATION: a revert or a rollback -- a target generation
    # that names another engine than the one on disk -- installs the engine
    # it names, older than the one on disk. A forward re-point (the units
    # still run what the own profile names) is left as it is.
    if found[0].ownExe != newestOnDisk:
      result.exe = found[0].ownExe
  when mutated("reassert-not-repointed"):
    # FALSIFYING MUTATION: the units keep the engine their own profile
    # names (the bootstrap engine on a host an earlier one bootstrapped).
    return
  for f in found:
    let want = f.cur.replace(f.ownExe, result.exe)
    if want != f.cur:
      result.own = replaceUnitContent(result.own, f.unit, want)
      result.changed = true
  # A unit this switch adds (the boot-confirm unit on a host an engine
  # before it bootstrapped) runs the same engine as the installed ones.
  for a in absentUnits:
    let want = a.cur.replace(a.ownExe, result.exe)
    if want != a.cur:
      result.own = replaceUnitContent(result.own, a.unit, want)
      result.changed = true
