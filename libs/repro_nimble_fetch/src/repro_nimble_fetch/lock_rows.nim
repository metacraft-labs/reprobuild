## The Nimble rows of a lock: what to fetch and what it must be
## (NPC-AREQ19).
##
## A Nimble package is a `LockedDep` named `nimble:<canonical name>`, with VCS
## coordinates (the origin, with any `?subdir=`, and the peeled commit) and
## the integrity `blake3:<tree>`. Nothing else is needed to fetch and verify
## it: no mirror, path or time is in the row. The fetch may additionally be
## told the canonical archive's `archive_sha256` and size, from the version
## record of the index the lock pins; they speed a refusal up but decide
## nothing the tree digest does not.

import std/[algorithm, strutils]

import blake3
from repro_domain_types/nimble_index/types import toHexLower

import repro_lock
import repro_multihash

import repro_nimble_generator/source_set
import ./mirror

const
  NimbleNamespace* = "nimble:"
  LockClosureDomain* = "reprobuild.nimble-lock-closure.v1"

type
  NimbleLockRow* = object
    name*: string      ## the canonical name, without `nimble:`
    origin*: string    ## the origin URL, `?subdir=` removed
    subdir*: string
    commit*: string    ## lower-case, full width
    tree*: string      ## 64 lower-case hex
    archiveSha256*: string ## "" when the index record was not consulted
    size*: int64           ## -1 when unknown

  LockRowError* = object of ValueError

proc rowError(msg: string) {.noreturn.} =
  raise newException(LockRowError, msg)

proc isNimbleDep*(d: LockedDep): bool =
  d.name.startsWith(NimbleNamespace)

proc nimbleRowOf*(d: LockedDep): NimbleLockRow =
  ## The row of one `nimble:` dependency. Raises `LockRowError` for a row a
  ## fetch could not verify.
  if not d.isNimbleDep:
    rowError(d.name & " is not a nimble: dependency")
  result.name = d.name[NimbleNamespace.len .. ^1]
  if result.name.len == 0:
    rowError("a nimble: dependency without a name")
  if d.coordinates.kind != ckVcs:
    rowError(d.name & " has " & $d.coordinates.kind & " coordinates; a " &
      "Nimble package is pinned by its origin and commit")
  let (u, sub) = splitOriginUrl(d.coordinates.url)
  result.origin = u
  result.subdir = sub
  result.commit = d.coordinates.revision.toLowerAscii()
  if not (result.commit.len in [40, 64] and
          result.commit.allCharsInSet({'0'..'9', 'a'..'f'})):
    rowError(d.name & " pins " & d.coordinates.revision.escape() &
      ", not a full-width commit id")
  var mh: Multihash
  try:
    mh = parseMultihash(d.integrity)
  except MultihashError as e:
    rowError(d.name & ": " & e.msg)
  if mh.alg != "blake3" or not isTreeHex(mh.digest):
    rowError(d.name & " records integrity " & d.integrity.escape() &
      "; a Nimble package's is blake3:<tree digest>")
  result.tree = mh.digest
  result.size = -1

proc nimbleRowsOf*(ld: LockedDependencies): seq[NimbleLockRow] =
  ## Every `nimble:` row of a lock, sorted by name.
  for d in ld.deps:
    if d.isNimbleDep: result.add nimbleRowOf(d)
  result.sort(proc (a, b: NimbleLockRow): int = cmp(a.name, b.name))

proc lockedDepOf*(r: NimbleLockRow): LockedDep =
  ## The `LockedDep` a row is (what a lock writer records).
  LockedDep(name: NimbleNamespace & r.name,
    coordinates: Coordinates(kind: ckVcs,
      url: r.origin & (if r.subdir.len > 0: "?subdir=" & r.subdir else: ""),
      revision: r.commit),
    integrity: "blake3:" & r.tree)

proc originUrl*(r: NimbleLockRow): string =
  r.origin & (if r.subdir.len > 0: "?subdir=" & r.subdir else: "")

proc lockClosureKey*(rows: seq[NimbleLockRow]): string =
  ## The key of a lock's Nimble acquisition closure: BLAKE3 over the rows'
  ## identities (name, origin, subdir, commit, tree), sorted, under a domain.
  ## What a lockfile-keyed closure index is keyed by. Only the Nimble rows
  ## enter it, so an unrelated change elsewhere in the lock does not
  ## invalidate a closure index.
  var lines: seq[string]
  for r in rows:
    lines.add [r.name, r.origin, r.subdir, r.commit, r.tree].join("\0")
  lines.sort()
  toHexLower(blake3.digest(LockClosureDomain & "\0" & lines.join("\n")))
