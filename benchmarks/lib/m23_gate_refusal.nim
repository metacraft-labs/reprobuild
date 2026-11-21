## The production benchmark gate's refusal text.
##
## A workload that does not settle every action in its accepted statuses
## stops the gate. The refusal is then the only record of the failed run, so
## it carries everything the engine said about each refused action: the cache
## decision, why the lookup missed, why no record was published, the
## dependency policy, the evidence counts and the monitoring diagnostics.
##
## A warm workload's measured build is decided by its warm-up: the measured
## build of an edge whose publication was withheld says only that no record
## was found. The warm-up's result for the same action is therefore reported
## beside it, so "never published" and "published and then missed" read
## differently.
##
## This module only reports. Which statuses a workload accepts is the
## caller's decision and is not widened here.

import std/[strutils, tables]

import repro_build_engine

const RefusalDetailLimit* = 8
  ## How many refused actions are rendered in full. Every refused action is
  ## still counted and named; the bound keeps a graph-wide refusal readable
  ## when the same cause stops every edge.

proc orNone(value: string): string =
  if value.len == 0: "<none>" else: value

proc statusList(statuses: set[ActionStatus]): string =
  var names: seq[string] = @[]
  for status in statuses:
    names.add($status)
  "{" & names.join(", ") & "}"

proc evidenceSummary(item: ActionResult): string =
  "declared-inputs:" & $item.declaredInputCount() &
    ",declared-outputs:" & $item.declaredOutputCount() &
    ",depfile:" & $item.depfileInputCount() &
    ",monitor-reads:" & $item.monitorReadCount() &
    ",monitor-writes:" & $item.monitorWriteCount() &
    ",monitor-probes:" & $item.monitorProbeCount() &
    ",diagnostics:" & $item.evidenceDiagnosticCount() &
    (if item.evidencePathsElided(): ",elided" else: "")

proc actionAttribution*(item: ActionResult): string =
  ## One action's result, every field that says why it settled as it did.
  ## An empty field is rendered as `<none>` so that "the engine had nothing
  ## to say" is distinguishable from "the field was not reported".
  result = "status=" & $item.status &
    " exit=" & $item.exitCode &
    " launched=" & $item.launched &
    " cache=" & $item.cacheDecision &
    " reason=" & item.reason.orNone &
    " policy=" & $item.dependencyPolicyKind &
    " cache-miss=" & item.cacheMissReason.orNone &
    " cache-publish-skipped=" & item.cachePublishSkipReason.orNone &
    " evidence=" & item.evidenceSummary()
  if item.blockedBy.len > 0:
    result.add(" blocked-by=" & item.blockedBy)
  if item.missingOutputs.len > 0:
    result.add(" missing-outputs=" & item.missingOutputs.join(","))
  let diagnostics =
    if item.evidence.diagnostics.len == 0: "<none>"
    else: item.evidence.diagnostics.join(" | ")
  result.add(" diagnostics=" & diagnostics)
  result.add(" stderr=" & item.stderr.strip().orNone)

proc gateRefusal*(workload: string; run: BuildRunResult;
                  accepted: set[ActionStatus];
                  warmup = BuildRunResult()): string =
  ## The refusal for `run`, or "" when every action settled in `accepted`.
  ## `warmup` is the build that prepared a warm workload; leave it empty for
  ## a workload that has none.
  var refused: seq[int] = @[]
  for index, item in run.results:
    if item.status notin accepted:
      refused.add(index)
  if refused.len == 0:
    return ""
  var warmupById = initTable[string, int]()
  for index, item in warmup.results:
    warmupById[item.id] = index
  result = workload & " workload refused " & $refused.len & " of " &
    $run.results.len & " actions; accepted statuses " & statusList(accepted)
  for position, index in refused:
    let item = run.results[index]
    if position >= RefusalDetailLimit:
      continue
    result.add("\n" & item.id & " " & item.actionAttribution())
    if warmup.results.len == 0:
      result.add("\n  warm-up: none")
    elif item.id in warmupById:
      result.add("\n  warm-up: " &
        warmup.results[warmupById[item.id]].actionAttribution())
    else:
      result.add("\n  warm-up: no result for this action")
  if refused.len > RefusalDetailLimit:
    var rest: seq[string] = @[]
    for index in refused[RefusalDetailLimit .. ^1]:
      rest.add(run.results[index].id & "=" & $run.results[index].status)
    result.add("\nalso refused: " & rest.join(", "))

proc requireAll*(workload: string; run: BuildRunResult;
                 accepted: set[ActionStatus];
                 warmup = BuildRunResult()) =
  ## Stop the gate with `gateRefusal` unless every action is accepted.
  let refusal = gateRefusal(workload, run, accepted, warmup)
  if refusal.len > 0:
    raise newException(ValueError, refusal)
