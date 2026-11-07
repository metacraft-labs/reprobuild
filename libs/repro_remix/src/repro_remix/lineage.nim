## Remix lineage: the DAG from each release to its parents.
##
## Normative source: `reprobuild-pm/spec/Remix-Protocol.md` §"Lineage"
## and Invariant I-11. Because a `ReleaseId` hashes its parents, a cycle
## would need a hash collision; the walk still refuses a revisited node on
## the current path and bounds depth, so hostile input is a refusal and
## never a hang. A parent the resolver cannot supply makes the lineage
## *incomplete*: displayable, never plannable.

import std/[hashes, sets]

import ./types
import ./identity

type
  ParentResolver* = proc (id: ReleaseId): (bool, seq[Digest32])
    ## Returns `(true, parents)` for a release the caller holds, or
    ## `(false, @[])` for one it cannot fetch.

  Lineage* = object
    root*: ReleaseId
    ancestors*: seq[ReleaseId]
      ## Every ancestor exactly once, in deterministic order: by first
      ## discovery in a depth-first walk that visits parents in their
      ## canonical (ascending) order.
    missing*: seq[ReleaseId]
      ## Ancestors the resolver could not supply.

proc hash(id: ReleaseId): Hash = hash(Digest32(id))

proc walkLineage*(root: ReleaseId; resolve: ParentResolver;
                  maxDepth = MaxLineageDepth): Lineage =
  ## Collect the ancestors of `root`. Refuses `rrLineageCycle` if a node
  ## reappears on its own path and `rrLineageTooDeep` past `maxDepth`.
  result.root = root
  var seen = initHashSet[ReleaseId]()
  var onPath = initHashSet[ReleaseId]()
  seen.incl root

  proc visit(id: ReleaseId; depth: int; res: var Lineage) =
    if depth > maxDepth:
      refuse(rrLineageTooDeep, "lineage deeper than " & $maxDepth)
    let (found, parents) = resolve(id)
    if not found:
      res.missing.add id
      return
    onPath.incl id
    for p in parents:
      let pid = ReleaseId(p)
      if pid in onPath:
        refuse(rrLineageCycle, "release " & $pid & " is its own ancestor")
      if pid in seen:
        continue
      seen.incl pid
      res.ancestors.add pid
      visit(pid, depth + 1, res)
    onPath.excl id

  visit(root, 0, result)

proc isComplete*(l: Lineage): bool =
  ## Planning requires every ancestor to be present (spec §"Lineage").
  l.missing.len == 0

proc requireComplete*(l: Lineage) =
  if not l.isComplete:
    refuse(rrIncompleteLineage, $l.missing.len & " ancestor(s) unavailable")

proc isAncestor*(l: Lineage; candidate: ReleaseId): bool =
  ## Used by composition's `lineage` conflict class: composing a release
  ## with one of its own ancestors double-applies the ancestor.
  for a in l.ancestors:
    if a == candidate:
      return true
  false
