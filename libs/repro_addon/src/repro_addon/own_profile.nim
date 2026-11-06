## The add-on's stored own profile (generation 0's objects, in the
## canonical text ``generation0.renderOwnProfile`` writes) as text to edit:
## a unit's inline content, a file's source, and the migration that
## re-renders the objects this build renders differently (A11 review
## findings 2 and 8). Shared by every path that rewrites generation 0
## (``agent-repin``, ``evidence-enrol``, the switch).

import std/strutils

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
  when not mutated("path-unit-not-migrated"):
    if unitContentOf(result, EvidenceShipPathUnit).len > 0:
      result = replaceUnitContent(result, EvidenceShipPathUnit,
                                  evidenceShipPathUnit())

