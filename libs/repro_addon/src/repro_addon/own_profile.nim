## The add-on's stored own profile (generation 0's objects, in the
## canonical text ``generation0.renderOwnProfile`` writes) as text to edit:
## a unit's inline content, a file's source, and the migration that
## re-renders the objects this build renders differently (A11 review
## findings 2 and 8). Shared by every path that rewrites generation 0
## (``agent-repin``, ``evidence-enrol``, the switch).

import std/[os, strutils]

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

