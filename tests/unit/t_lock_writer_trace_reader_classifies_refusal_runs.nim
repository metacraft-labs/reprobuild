## The ``lock-writer`` health row's reader, exercised on trace TEXT.
##
## Spec: reprobuild-pm ``spec/CLI/health.md``, the **Lock writer**
## (``lock-writer``) bullet — the three-kind tag table, the refusal run, the
## ok / warn / fail table and what a non-ok detail and remedy must name.
##
## No mocks: ``evaluateLockWriterTrace`` and ``summarizePostCommitTrace`` are
## pure functions of the trace text and the current time, which is the seam
## the module was cut along. The end-to-end half — the real writer producing
## the trace and the real ``repro health`` reading it — is
## ``tests/integration/t_health_fails_when_the_post_commit_lock_writer_keeps_refusing.nim``.
## The tail reader is the one IO proc and is exercised here against a real
## file over 4 MiB.

import std/[json, options, os, strutils, tempfiles, times, unittest]

when defined(posix):
  import std/posix

import repro_cli_support/post_commit_trace
import repro_test_support/reasoned_skip

const tracePath = "/ws/.repro/build/reports/post-commit-lock.log"

let now = parse("2026-10-20T12:00:00Z", "yyyy-MM-dd'T'HH:mm:ss'Z'",
  utc()).toTime()

proc line(at: string; outcome: PostCommitOutcome | string;
          diagnostic = ""): string =
  ## One trace line in the writer's format. The tag is spelled through
  ## ``postCommitOutcomeTag`` where the case means a real outcome, so the
  ## suite cannot drift from the writer's vocabulary.
  let tag =
    when outcome is PostCommitOutcome: postCommitOutcomeTag(outcome)
    else: outcome
  at & " " & tag & " " & diagnostic & "\n"

suite "lock-writer trace reader":

  test "every outcome tag round-trips and is classified":
    for outcome in PostCommitOutcome:
      check parsePostCommitOutcomeTag(postCommitOutcomeTag(outcome)) ==
        some(outcome)
    # Retired spellings are not outcomes.
    for retired in ["ok", "skipped-dirty", "failed", "evidence"]:
      check parsePostCommitOutcomeTag(retired).isNone
    # The spec's table, row by row.
    for o in [pcoPublished, pcoWrittenPending, pcoWrittenLocalOnly,
              pcoWrittenUnknown]:
      check postCommitOutcomeKind(o) == pokWrote
    for o in [pcoNoLockDirty, pcoNoLockFailed]:
      check postCommitOutcomeKind(o) == pokRefused
    for o in [pcoNoManifestRecord, pcoSkippedMembershipRepo,
              pcoSkippedNoWorkspace,
              pcoSkippedGitOperation, pcoInertGitStateUnknown]:
      check postCommitOutcomeKind(o) == pokNoRecordDue

  test "an absent or outcome-free trace is ok":
    let absent = evaluateLockWriterTrace("", now, tracePath,
      tracePresent = false)
    check absent.verdict == lwvOk
    check "no post-commit run recorded" in absent.detail
    check absent.remedy == ""
    let noise = evaluateLockWriterTrace(
      "2026-10-19T10:00:00Z evidence refreshed lib-a\ngarbage\n", now,
      tracePath)
    check noise.verdict == lwvOk
    check "no post-commit run recorded" in noise.detail
    check noise.data["outcomeLines"].getInt() == 0

  test "an empty run is ok and names the newest outcome and written record":
    let row = evaluateLockWriterTrace(
      line("2026-10-19T09:00:00Z", pcoNoLockDirty, "NO lock: lib-b") &
      line("2026-10-20T09:00:00Z", pcoWrittenLocalOnly, "wrote /x.toml"),
      now, tracePath)
    check row.verdict == lwvOk
    check "written-local-only" in row.detail
    check "3h 0m ago" in row.detail
    check row.data["runLength"].getInt() == 0
    check row.data["newestWrittenAt"].getStr() == "2026-10-20T09:00:00Z"

  test "a run of one is warn":
    let row = evaluateLockWriterTrace(
      line("2026-10-19T09:00:00Z", pcoPublished, "published") &
      line("2026-10-20T11:00:00Z", pcoNoLockFailed, "NO lock: boom"),
      now, tracePath)
    check row.verdict == lwvWarn
    check row.data["runLength"].getInt() == 1
    check "no-lock-failed" in row.remedy
    check "workspace lock" in row.remedy
    check tracePath in row.remedy

  test "a run of two or more is fail and lists every reason newest first":
    # The masking shape: the newest line names a reason that accounts for one
    # run; the reason that accounts for most of them is older.
    let trace =
      line("2026-10-01T09:00:00Z", pcoWrittenPending, "wrote /x.toml") &
      line("2026-10-02T09:00:00Z", pcoNoLockDirty, "NO lock: lib-b, lib-c") &
      line("2026-10-03T09:00:00Z", pcoNoLockDirty, "NO lock: lib-b, lib-c") &
      line("2026-10-04T09:00:00Z", pcoNoLockDirty, "NO lock: lib-b, lib-c") &
      line("2026-10-19T09:00:00Z", pcoNoLockFailed, "NO lock: no checkout")
    let row = evaluateLockWriterTrace(trace, now, tracePath)
    check row.verdict == lwvFail
    check row.data["runLength"].getInt() == 4
    check row.data["runStartedAt"].getStr() == "2026-10-02T09:00:00Z"
    check row.data["runNewestAt"].getStr() == "2026-10-19T09:00:00Z"
    let reasons = row.data["reasons"]
    check reasons.len == 2
    check reasons[0]["outcome"].getStr() == "no-lock-failed"
    check reasons[0]["count"].getInt() == 1
    check reasons[1]["outcome"].getStr() == "no-lock-dirty-siblings"
    check reasons[1]["count"].getInt() == 3
    check reasons[1]["diagnostic"].getStr() == "NO lock: lib-b, lib-c"
    check reasons[1]["oldestAt"].getStr() == "2026-10-02T09:00:00Z"
    check reasons[1]["newestAt"].getStr() == "2026-10-04T09:00:00Z"
    check "4 consecutive runs" in row.detail
    check "18d 3h ago" in row.detail          # run start
    check "2026-10-01T09:00:00Z" in row.detail # newest written record
    check row.detail.find("no-lock-failed") <
      row.detail.find("no-lock-dirty-siblings")
    # The remedy points at the NEWEST reason.
    check "NO lock: no checkout" in row.remedy

  test "a trace with no written record says so":
    let row = evaluateLockWriterTrace(
      line("2026-10-19T09:00:00Z", pcoNoLockFailed, "NO lock: no checkout") &
      line("2026-10-19T10:00:00Z", pcoNoLockFailed, "NO lock: no checkout"),
      now, tracePath)
    check row.verdict == lwvFail
    check "no lock record ever written" in row.detail
    check row.data["newestWrittenAt"].kind == JNull
    check row.data["reasons"].len == 1
    check row.data["reasons"][0]["count"].getInt() == 2

  test "no-record-due lines neither start nor end a run":
    let trace =
      line("2026-10-01T09:00:00Z", pcoWrittenLocalOnly, "wrote") &
      line("2026-10-01T10:00:00Z", pcoSkippedMembershipRepo, "membership") &
      line("2026-10-01T11:00:00Z", pcoSkippedGitOperation, "rebase") &
      line("2026-10-02T09:00:00Z", pcoNoLockDirty, "NO lock: lib-b") &
      line("2026-10-02T10:00:00Z", pcoSkippedMembershipRepo, "membership") &
      line("2026-10-02T11:00:00Z", pcoInertGitStateUnknown, "unknown") &
      line("2026-10-03T09:00:00Z", pcoNoLockDirty, "NO lock: lib-b")
    let summary = summarizePostCommitTrace(trace)
    check summary.runLength == 2
    check summary.runStartedAt == "2026-10-02T09:00:00Z"
    check summary.newestOutcome == "no-lock-dirty-siblings"
    check summary.reasons.len == 1
    # And a skip after a write starts nothing.
    let quiet = summarizePostCommitTrace(
      line("2026-10-01T09:00:00Z", pcoPublished, "published") &
      line("2026-10-01T10:00:00Z", pcoSkippedMembershipRepo, "membership"))
    check quiet.runLength == 0
    check lockWriterVerdict(quiet) == lwvOk

  test "malformed and non-outcome lines are ignored":
    let trace =
      line("2026-10-02T09:00:00Z", pcoNoLockDirty, "NO lock: lib-b") &
      "2026-10-02T09:01:00Z evidence refreshed lib-a\n" &
      "continuation of a diagnostic that had a newline\n" &
      "yesterday no-lock-failed bad timestamp\n" &
      "2026-10-02T09:02:00Z ok wrote /retired.toml\n" &
      line("2026-10-03T09:00:00Z", pcoNoLockDirty, "NO lock: lib-b")
    let summary = summarizePostCommitTrace(trace)
    check summary.outcomeLines == 2
    check summary.runLength == 2
    check summary.reasons.len == 1

  test "the tail reader reads only the last 4 MiB and drops the cut line":
    let dir = createTempDir("lock-writer-tail-", "")
    defer: removeDir(dir)
    let path = dir / "post-commit-lock.log"
    # A written record far back, then more than 4 MiB of refusals: the window
    # cannot see the write, so the row must not claim "none ever written".
    var body = line("2026-01-01T00:00:00Z", pcoPublished, "published")
    let refusal = line("2026-10-02T09:00:00Z", pcoNoLockDirty,
      "NO lock: " & repeat('x', 200))
    while body.len <= PostCommitTraceTailBytes + 4096:
      body.add(refusal)
    writeFile(path, body)
    let tail = readPostCommitTraceTail(path)
    check tail.present
    check tail.tailOnly
    check tail.text.len < PostCommitTraceTailBytes
    check tail.text.startsWith("2026-10-02T09:00:00Z ")
    let row = evaluateLockWriterTrace(tail.text, now, path,
      tailOnly = tail.tailOnly)
    check row.verdict == lwvFail
    check "in the last 4 MiB of the trace" in row.detail
    check "ever written" notin row.detail
    check "at or before" in row.detail
    check row.data["tailOnly"].getBool()
    check not readPostCommitTraceTail(dir / "absent.log").present

  test "a line that starts exactly at the window boundary is kept whole":
    # The window's first byte begins a complete line (the byte before it is a
    # newline). That line is the only written record in the window, so a
    # reader that drops "the first line" unconditionally would lose it and
    # report a run that the trace does not show.
    let dir = createTempDir("lock-writer-boundary-", "")
    defer: removeDir(dir)
    let path = dir / "post-commit-lock.log"
    let wrote = line("2026-10-02T08:00:00Z", pcoPublished, "published")
    let refusal = line("2026-10-02T09:00:00Z", pcoNoLockDirty,
      "NO lock: " & repeat('x', 200))
    var window = wrote
    while window.len + 2 * refusal.len <= PostCommitTraceTailBytes:
      window.add(refusal)
    # Pad the last refusal so the window is EXACTLY the tail size.
    let padding = PostCommitTraceTailBytes - window.len - refusal.len
    window.add(line("2026-10-02T09:00:00Z", pcoNoLockDirty,
      "NO lock: " & repeat('x', 200 + padding)))
    doAssert window.len == PostCommitTraceTailBytes
    let refusalsInWindow = window.count('\n') - 1
    # Before the window: one complete refusal, ending in the newline that is
    # the look-behind byte.
    writeFile(path, refusal & window)
    let tail = readPostCommitTraceTail(path)
    check tail.present
    check tail.tailOnly
    check tail.text.len == PostCommitTraceTailBytes
    check tail.text.startsWith(wrote)
    let summary = summarizePostCommitTrace(tail.text, tail.tailOnly)
    check summary.newestWrittenAt == "2026-10-02T08:00:00Z"
    check summary.runLength == refusalsInWindow

    # And one byte later the same line IS cut, so it must go.
    writeFile(path, refusal & "x" & window)
    let cut = readPostCommitTraceTail(path)
    check cut.tailOnly
    check not cut.text.startsWith("2026-10-02T08:00:00Z")
    check summarizePostCommitTrace(cut.text, true).newestWrittenAt == ""

  test "no-manifest-record is no record due, not a refusal":
    # A public-only workspace logs this on every ordinary commit (the in-repo
    # repro.lock is its record). Counting it as a refusal turned such a
    # workspace `fail` after its second commit; the amended spec moved it.
    let trace =
      line("2026-10-19T09:00:00Z", pcoNoManifestRecord, "no manifest record") &
      line("2026-10-19T10:00:00Z", pcoNoManifestRecord, "no manifest record")
    let row = evaluateLockWriterTrace(trace, now, tracePath)
    check row.verdict == lwvOk
    check row.data["runLength"].getInt() == 0
    check "no-manifest-record" in row.detail
    # Nor does it END a run: refusals on either side of it still add up.
    let around = summarizePostCommitTrace(
      line("2026-10-19T09:00:00Z", pcoNoLockDirty, "NO lock: lib-b") &
      line("2026-10-19T10:00:00Z", pcoNoManifestRecord, "no manifest record") &
      line("2026-10-19T11:00:00Z", pcoNoLockDirty, "NO lock: lib-b"))
    check around.runLength == 2

  test "reasons are keyed on the first line of the diagnostic":
    # The writer's IO-error diagnostics carry an embedded newline; the
    # continuation is not part of the reason and must not split one reason
    # into several.
    let trace =
      line("2026-10-19T09:00:00Z", pcoNoLockFailed,
        "NO lock written: Permission denied\nAdditional info: /a/locks/") &
      line("2026-10-19T10:00:00Z", pcoNoLockFailed,
        "NO lock written: Permission denied\nAdditional info: /b/locks/")
    let summary = summarizePostCommitTrace(trace)
    check summary.runLength == 2
    check summary.reasons.len == 1
    check summary.reasons[0].diagnostic == "NO lock written: Permission denied"
    check summary.reasons[0].count == 2

  test "an unreadable trace is warn, naming the path and the error":
    let pure = evaluateLockWriterTrace("", now, tracePath,
      readError = "Permission denied")
    check pure.verdict == lwvWarn
    check tracePath in pure.detail
    check "Permission denied" in pure.detail
    check pure.remedy.len > 0
    check pure.data["readError"].getStr() == "Permission denied"

    # And the real reader on a real unreadable file. Root bypasses POSIX
    # read permission, so this half cannot observe the state as root and is
    # skipped there; the pure half above still runs.
    let isRoot =
      when defined(posix): geteuid() == 0
      else: true
    if isRoot or defined(windows):
      skip("running as root or on Windows: removing the read bits " &
        "does not make the file unreadable there, so the real-file half " &
        "cannot observe the state (the pure half above still ran)")
    else:
      let dir = createTempDir("lock-writer-unreadable-", "")
      defer: removeDir(dir)
      let path = dir / "post-commit-lock.log"
      writeFile(path,
        line("2026-10-19T09:00:00Z", pcoNoLockDirty, "NO lock: lib-b"))
      setFilePermissions(path, {})
      defer: setFilePermissions(path, {fpUserRead, fpUserWrite})
      let tail = readPostCommitTraceTail(path)
      check tail.present
      check tail.error.len > 0
      check tail.text == ""
      let row = evaluateLockWriterTrace(tail.text, now, path,
        tracePresent = tail.present, readError = tail.error)
      check row.verdict == lwvWarn
      check path in row.detail
      check tail.error in row.detail

  test "a directory where the trace should be is present and unreadable":
    # Unlike the mode-000 case above, this state does not depend on POSIX
    # permission bits, so it runs as root and on Windows too.
    let dir = createTempDir("lock-writer-dir-", "")
    defer: removeDir(dir)
    let asDir = dir / "post-commit-lock.log"
    createDir(asDir)
    let dirRead = readPostCommitTraceTail(asDir)
    check dirRead.present
    check "directory" in dirRead.error
    let row = evaluateLockWriterTrace(dirRead.text, now, asDir,
      tracePresent = dirRead.present, readError = dirRead.error)
    check row.verdict == lwvWarn
