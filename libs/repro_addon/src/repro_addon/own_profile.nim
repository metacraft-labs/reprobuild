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

type
  PathProbe* = proc (path: string): tuple[present: bool; sha256: string]
    ## Whether a path is there (a link counts, unfollowed) and, for a
    ## regular file, the SHA-256 of its bytes ("" otherwise).
  RecordedDigest* = proc (path: string): string
    ## The digest the committed ledger records for a path the add-on
    ## wrote, "" when the ledger does not name it.

proc addMissingGeneration0*(own: string; candidates: openArray[OwnObject];
                            probe: PathProbe; recorded: RecordedDigest): string =
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
  for o in candidates:
    let p = probe(o.path)
    if not p.present: continue
    let want = sha256Hex(o.content)
    let rec = recorded(o.path)
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
  for o in candidates:
    let blk = renderOwnProfile(@[o], "")
    # Beside the re-assert unit, where a bootstrap by this build puts it.
    let (_, b) = blockBounds(result, UnitBlockHead & ReassertUnit & "\"\n")
    if b < 0:
      result.add(blk)
    else:
      let at = if result.continuesWith("\n", b): b + 1 else: b
      result = result[0 ..< at] & blk & result[at .. ^1]
