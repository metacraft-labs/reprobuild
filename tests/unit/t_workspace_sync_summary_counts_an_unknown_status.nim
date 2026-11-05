## ``repro workspace sync`` — the digest counts an execution status it does
## not recognise as unknown, never as up-to-date.
##
## WHY THIS TEST EXISTS
##
## ``summarize`` folds each repo row into the end-of-run digest by switching
## on ``executionStatus``. Its fallback arm counted any status it did not know
## under ``noop``, which the digest renders as *up-to-date* and ``--json``
## serialises as ``noop``. A status added later, or one reaching the digest
## from a path the switch was not updated for, was therefore reported to the
## operator as "nothing needed doing": the most reassuring bucket available,
## for the one row whose outcome nobody knows.
##
## The same ordering hazard applied to the ``force_reset`` and
## ``force_push_rebase`` overrides, which run before the switch and exclude
## only the known failure statuses: an unrecognised status on one of those
## rows was counted as a completed overwrite or rebase.
##
## No status the executor produces today reaches the fallback, so the rows
## here are constructed. Everything downstream of them is the real code:
## ``summarize``, the ``--json`` document and the rendered digest line.
##
## The counts are asserted on both sides. ``unknown == 1`` alone would pass
## against an implementation that also kept counting the row as ``noop``;
## the accompanying zeros say it moved rather than multiplied.

import std/[json, strutils, unittest]

import repro_cli_support

proc row(status: string; action = "noop"): WorkspaceSyncRepoEntry =
  WorkspaceSyncRepoEntry(name: "dep", path: "deps/dep", action: action,
    executionStatus: status)

proc reportOf(rows: openArray[WorkspaceSyncRepoEntry]): WorkspaceSyncReport =
  WorkspaceSyncReport(project: "fixture", workspaceRoot: "/ws",
    repos: @rows)

proc digest(report: WorkspaceSyncReport): string =
  let lines = renderSyncSummaryLines(report)
  check lines.len == 1
  lines[0]

suite "workspace sync summary: unrecognised execution status":
  test "an unknown status is counted as unknown, not up-to-date":
    let report = reportOf([row("status_from_the_future")])
    let s = report.summarize()
    check s.total == 1
    check s.unknown == 1
    check s.noop == 0
    check s.succeeded == 0

    let json = report.toJsonNode()["summary"]
    check json["unknown"].getInt() == 1
    check json["noop"].getInt() == 0

    let line = digest(report)
    checkpoint(line)
    check "UNKNOWN STATUS 1" in line
    check "up-to-date 0" in line

  test "an unknown status on a force_reset row is not a completed overwrite":
    let s = reportOf([row("status_from_the_future", "force_reset")]).summarize()
    check s.unknown == 1
    check s.forceReset == 0
    check s.noop == 0

  test "an unknown status on a force_push_rebase row is not a rebase":
    let s = reportOf(
      [row("status_from_the_future", "force_push_rebase")]).summarize()
    check s.unknown == 1
    check s.rebased == 0
    check s.noop == 0

  test "every status the executor produces keeps its own bucket":
    let report = reportOf([
      row("succeeded", "fast_forward"), row("cloned", "clone"),
      row("skipped"), row("clone_failed", "clone"),
      row("declared_branch_missing", "clone"), row("refused"),
      row("failed", "fast_forward"), row("noop"),
      row("succeeded", "force_reset"), row("succeeded", "force_push_rebase")])
    let s = report.summarize()
    check s.total == 10
    check s.succeeded == 1
    check s.cloned == 1
    check s.skipped == 1
    check s.cloneFailed == 2
    check s.refused == 1
    check s.failed == 1
    check s.noop == 1
    check s.forceReset == 1
    check s.rebased == 1
    check s.unknown == 0

    check report.toJsonNode()["summary"]["unknown"].getInt() == 0
    let line = digest(report)
    checkpoint(line)
    check "UNKNOWN" notin line
