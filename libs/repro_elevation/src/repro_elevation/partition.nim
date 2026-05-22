## Planner partition (M81 deliverable 1).
##
## Per Elevation-And-Privileged-Operations.md "Detecting Which
## Operations Need Elevation": the planner — which already runs
## fully non-elevated and read-only — partitions an apply's
## operations into a non-privileged set (run in the non-elevated
## parent) and a privileged set (run via the broker, or in-process
## when already elevated).
##
## The partition itself is platform-pure: it consumes a sequence of
## typed `PrivilegedOperation`s plus a count of the non-privileged
## operations the rest of the apply pipeline owns, and records the
## split so `repro infra plan` can name the privileged operations
## and state up front that a single prompt is coming and why.
##
## M81 deliberately models the apply's non-privileged work as an
## opaque count rather than re-typing the home-scope operation set:
## the home-scope pipeline (M55-M80) already owns its own operation
## model, and M69 — not M81 — supplies the system-scope catalog the
## privileged set is drawn from. M81 owns only the elevation
## MECHANISM and the privileged half of the split.

import std/[strutils]

import ./operations

type
  ApplyPartition* = object
    ## The result of partitioning an apply. `privilegedOperations`
    ## is the closed, typed set the broker (or the already-elevated
    ## in-process path) executes; `nonPrivilegedOperationCount` is
    ## how many operations the non-elevated parent runs directly.
    privilegedOperations*: seq[PrivilegedOperation]
    nonPrivilegedOperationCount*: int

proc partitionApply*(allPrivilegedCandidates: openArray[PrivilegedOperation];
                     nonPrivilegedOperationCount: int): ApplyPartition =
  ## Partition an apply. Every element of `allPrivilegedCandidates`
  ## is screened through `requiresElevation`; the screen is total
  ## for the M81 fixture catalog (every fixture kind is privileged)
  ## but is kept explicit so the M69 catalog — which will add kinds
  ## whose privilege depends on a `scope` field — slots in without
  ## changing this function.
  result.nonPrivilegedOperationCount = nonPrivilegedOperationCount
  for op in allPrivilegedCandidates:
    if requiresElevation(op.kind):
      result.privilegedOperations.add(op)

proc requiresBroker*(partition: ApplyPartition; alreadyElevated: bool): bool =
  ## True when this apply must launch the one-shot broker: the
  ## privileged set is non-empty AND `repro` is not already
  ## elevated. When the privileged set is empty the apply raises
  ## ZERO prompts; when already elevated the privileged set runs
  ## in-process (the fast path) with no broker.
  partition.privilegedOperations.len > 0 and not alreadyElevated

proc hasPrivilegedWork*(partition: ApplyPartition): bool =
  partition.privilegedOperations.len > 0

proc renderPlanPrivilegeNotice*(partition: ApplyPartition;
                                alreadyElevated: bool): string =
  ## The `repro infra plan` line the spec mandates: name the
  ## privileged operations and state up front that a single prompt
  ## is coming and exactly why, so the user knows before they
  ## accept it. Returns "" when the plan has no privileged work.
  if partition.privilegedOperations.len == 0:
    return ""
  var lines: seq[string]
  let n = partition.privilegedOperations.len
  if alreadyElevated:
    lines.add("This apply has " & $n & " privileged operation" &
      (if n == 1: "" else: "s") &
      "; `repro` is already elevated, so they run in-process with " &
      "no elevation prompt:")
  else:
    lines.add("This apply will raise one elevation prompt to perform " &
      $n & " privileged operation" & (if n == 1: "" else: "s") & ":")
  for op in partition.privilegedOperations:
    lines.add("  - " & op.address & "  (" & $op.kind & ")")
  return lines.join("\n")
