import std/[json, strutils]

import repro_monitor_depfile/types
import repro_monitor_depfile/reader

proc recordKindName(record: MonitorRecord): string =
  case record.kind
  of mrProcessStart: "process-start"
  of mrProcessExec: "process-exec"
  of mrProcessSpawn: "process-spawn"
  of mrFileOpen: "file-open"
  of mrFileRead: "file-read"
  of mrPathProbe: "path-probe"
  of mrFileWrite: "file-write"
  of mrEventLoss: "event-loss"
  of mrDirectoryEnumerate: "directory-enumerate"

proc observationKindName(record: MonitorRecord): string =
  case record.observationKind
  of moProcessStart: "process-start"
  of moExecute: "execute"
  of moFileOpen: "file-open"
  of moFileRead: "file-read"
  of moPathProbe: "path-probe"
  of moFileWrite: "file-write"
  of moEventLoss: "event-loss"
  of moDirectoryEnumerate: "directory-enumerate"

proc itemKindName(kind: FsSnoopStreamItemKind): string =
  case kind
  of fsiChildStdout: "child-stdout"
  of fsiChildStderr: "child-stderr"
  of fsiProcessStarted: "process-started"
  of fsiProcessExited: "process-exited"
  of fsiObservation: "observation"
  of fsiEventLoss: "event-loss"
  of fsiDiagnostic: "diagnostic"
  of fsiSummary: "summary"

proc summaryJson(summary: MonitorSummary): JsonNode =
  result = newJObject()
  result["recordCount"] = %int(summary.recordCount)
  result["processCount"] = %int(summary.processCount)
  result["observationCount"] = %int(summary.observationCount)
  result["eventLossCount"] = %int(summary.eventLossCount)

proc recordJson*(record: MonitorRecord): JsonNode =
  result = newJObject()
  result["seq"] = %int(record.seq)
  result["recordKind"] = %recordKindName(record)
  result["observationKind"] = %observationKindName(record)
  result["osPid"] = %int(record.osPid)
  result["parentOsPid"] = %int(record.parentOsPid)
  result["threadId"] = %int(record.threadId)
  result["childOsPid"] = %int(record.childOsPid)
  result["result"] = %int(record.result)
  result["flags"] = %int(record.flags)
  result["probeResult"] = %($record.probeResult)
  result["path"] = %record.path
  result["detail"] = %record.detail

proc streamItemJson*(item: FsSnoopStreamItem): JsonNode =
  result = newJObject()
  result["kind"] = %itemKindName(item.kind)
  case item.kind
  of fsiSummary:
    result["summary"] = summaryJson(item.summary)
  of fsiDiagnostic:
    result["message"] = %item.diagnostic
  else:
    result["record"] = recordJson(item.record)

proc renderMonitorRecordText*(record: MonitorRecord): string =
  var parts = @[
    "#" & $record.seq,
    recordKindName(record),
    "pid=" & $record.osPid,
    "tid=" & $record.threadId
  ]
  if record.childOsPid != 0:
    parts.add("child=" & $record.childOsPid)
  if record.path.len > 0:
    parts.add("path=" & record.path)
  if record.probeResult != prUnknown:
    parts.add("probe=" & $record.probeResult)
  if record.result != 0:
    parts.add("result=" & $record.result)
  if record.detail.len > 0:
    parts.add("detail=" & record.detail)
  parts.join(" ")

proc renderMonitorStreamItemText*(item: FsSnoopStreamItem): string =
  case item.kind
  of fsiSummary:
    "summary records=" & $item.summary.recordCount &
      " processes=" & $item.summary.processCount &
      " observations=" & $item.summary.observationCount &
      " eventLoss=" & $item.summary.eventLossCount
  of fsiDiagnostic:
    "diagnostic " & item.diagnostic
  else:
    itemKindName(item.kind) & " " & renderMonitorRecordText(item.record)

proc renderMonitorStreamItemJsonl*(item: FsSnoopStreamItem): string =
  $streamItemJson(item)

proc renderMonitorDepFileText*(dep: MonitorDepFile): string =
  var lines: seq[string] = @[
    "RMDF version=" & $dep.version &
      " records=" & $dep.summary.recordCount &
      " completeness=" & $dep.completeness
  ]
  for record in dep.records:
    lines.add(renderMonitorRecordText(record))
  lines.add("summary records=" & $dep.summary.recordCount &
    " processes=" & $dep.summary.processCount &
    " observations=" & $dep.summary.observationCount &
    " eventLoss=" & $dep.summary.eventLossCount)
  lines.join("\n")

proc renderMonitorDepFileJson*(dep: MonitorDepFile): string =
  var root = newJObject()
  root["format"] = %"RMDF"
  root["version"] = %int(dep.version)
  root["producerVersion"] = %dep.producerVersion
  root["backendFamily"] = %($dep.backendFamily)
  root["completeness"] = %($dep.completeness)
  root["summary"] = summaryJson(dep.summary)
  var records = newJArray()
  for record in dep.records:
    records.add(recordJson(record))
  root["records"] = records
  $root

proc renderMonitorDepFile*(path, format: string): string =
  let dep = readMonitorDepFile(path)
  case format
  of "text":
    renderMonitorDepFileText(dep)
  of "json":
    renderMonitorDepFileJson(dep)
  else:
    raise newException(ValueError, "unsupported inspect format: " & format)
