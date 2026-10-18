## Test-only subsystem control for platforms without a complete tree-lifetime
## guard. Validate the real capture's fail-closed verdict and exactly one
## platform marker before removing that marker from a separate in-memory view.
## Every other record, including any other loss, survives. Callers must keep
## using the original capture for product verdicts and raw evidence comparisons.
import std/strutils
import io_mon

proc descendantSubsystemEvidence*(dep: MonitorDepFile): MonitorDepFile =
  when defined(macosx) or defined(windows):
    doAssert dep.completeness == mcIncomplete,
      "real capture must fail closed without a complete tree-lifetime guard"
    const platform = when defined(macosx): "macos" else: "windows"
    const prefix = "detached-descendant quiescence cannot be established: " &
      platform & " backend has no complete tree-lifetime guard run="
    var records: seq[MonitorRecord]
    var limitations = 0
    for record in dep.records:
      if record.kind == mrEventLoss and record.observationKind == moEventLoss and
          record.detail.startsWith(prefix):
        let runId = record.detail[prefix.len .. ^1]
        if runId.len > 0 and runId.find({' ', '\t', '\r', '\n'}) < 0:
          inc limitations
          continue
      records.add record
    doAssert limitations == 1,
      "capture must carry exactly one explicit platform tree-lifetime limitation"
    result = depFileFromRecords(records)
  else:
    result = dep
