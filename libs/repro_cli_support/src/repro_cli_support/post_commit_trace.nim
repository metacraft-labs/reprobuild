## The managed ``post-commit`` lock writer's outcome vocabulary, and the
## reader that turns its trace into `repro health`'s ``lock-writer`` row.
##
## The writer (``runPostCommitLockCommand`` in ``repro_cli_support``) never
## fails a commit. It appends one line per run to
## ``<workspace>/.repro/build/reports/post-commit-lock.log``, shaped
## ``<ISO-8601 timestamp> <outcome> <diagnostic>``, and prints one stderr
## line when the run did not reach its designed steady state. That is loud at
## the moment of the commit and silent ever after: one workspace logged
## eighteen days of consecutive refusals while `repro health` stayed green,
## because the rows that look at the hook (``vcs-hooks``,
## ``hook-interpreter``) answer whether it is INSTALLED, never what it DID
## (reprobuild-pm ``issues/2026-10-02-nothing-checks-the-post-commit-lock-
## writers-outcome.md``).
##
## The row's contract is reprobuild-pm ``spec/CLI/health.md``, the **Lock
## writer** (``lock-writer``) bullet. Everything that decides the row's verdict
## and wording is here and takes the trace TEXT and the current time, so it can
## be tested without a workspace; the only IO is ``readPostCommitTraceTail``.
##
## Why the vocabulary moved here: the writer and this reader must agree on
## every tag. Keeping ``PostCommitOutcome`` and ``postCommitOutcomeTag`` in one
## module, with ``postCommitOutcomeKind`` an exhaustive ``case`` over the same
## enum, means a new outcome cannot be added to the writer without the compiler
## demanding that the reader classify it.

import std/[json, options, os, strutils, tables, times]

type
  PostCommitOutcome* = enum
    pcoPublished         ## Per-repo lock TOML written (RA-1: no index) AND
                         ## already present in the store's last-known
                         ## upstream. The only success tag.
    pcoWrittenPending    ## Record written to a PUBLISHABLE store but not yet
                         ## in its upstream. The designed post-commit steady
                         ## state — pre-push publishes it. Loud only when the
                         ## store carries STRANDED records (below).
    pcoWrittenLocalOnly  ## Record written, but the store is not publishable
                         ## (not its own checkout / no upstream). This record
                         ## will never leave this machine.
    pcoWrittenUnknown    ## Record written; the publication probe itself
                         ## failed. Never reported as success.
    pcoNoManifestRecord  ## The lock writer succeeded but wrote no manifest
                         ## record: this workspace routes per-repo records to
                         ## their own backends, or is public-only and carries
                         ## its lock in the in-repo ``repro.lock``. Nothing to
                         ## publish here, and nothing claimed.
    pcoNoLockDirty       ## At least one in-scope repo is dirty; strict M11
                         ## refused with exit 2 and NO lock exists.
    pcoSkippedNoWorkspace ## No ``.repo/workspace.toml`` or no resolvable
                          ## project; common in a freshly-cloned repo
                          ## that has not been initialised. A genuine
                          ## "this hook does not apply here" no-op, not a
                          ## starvation: log-only.
    pcoNoLockFailed      ## Lock writer raised (IO error, VCS query
                         ## failure, missing checkout, ...) and NO lock
                         ## exists.
    pcoSkippedMembershipRepo ## The commit landed in the MEMBERSHIP repo (the
                          ## checkout carrying ``projects/``/``repos/``), for
                          ## which Workspace-And-Develop-Mode.md §"Gate scope
                          ## when the pushed repo is the membership repo"
                          ## decides that no trigger-keyed record is due at
                          ## all: it is not a project repo, so it has no
                          ## declared name to encode as the ``<repo>``
                          ## component and belongs to no tier's partition.
                          ## Writing nothing is the SPECIFIED outcome here, so
                          ## it is a skip and not a failure — the distinction
                          ## this suite's invariant 4 reserves
                          ## ``no-lock-failed`` for. A stray undeclared
                          ## checkout keeps that tag: it has no resolvable
                          ## anchor, which does block a record somebody would
                          ## have looked for.
    pcoSkippedGitOperation ## Git is mid-rebase / mid-cherry-pick / mid-am /
                           ## mid-bisect in the repo that fired the hook. The
                           ## commit this hook saw is one of that operation's
                           ## intermediate commits, and writing a lock into a
                           ## working tree its owner has not finished with is
                           ## how a hook breaks somebody else's rebase.
    pcoInertGitStateUnknown ## The "is an operation in flight" probe could not
                            ## answer. The hook did nothing and SAID so — an
                            ## unanswerable question is not the same as "no".

  PostCommitOutcomeKind* = enum
    ## How the ``lock-writer`` row reads one outcome (CLI/health.md, the
    ## three-kind table under **Lock writer**).
    pokWrote       ## A lock record was written. Ends any refusal run.
    pokRefused     ## A record was due and the writer produced nothing.
    pokNoRecordDue ## The designed steady state for that commit: neither
                   ## starts nor ends a run.

proc postCommitOutcomeTag*(outcome: PostCommitOutcome): string =
  ## The trace and report spelling of ``outcome``. The ONLY place these
  ## strings are written down; ``parsePostCommitOutcomeTag`` inverts it.
  case outcome
  of pcoPublished: "published"
  of pcoWrittenPending: "written-pending-publish"
  of pcoWrittenLocalOnly: "written-local-only"
  of pcoWrittenUnknown: "written-publication-unknown"
  of pcoNoManifestRecord: "no-manifest-record"
  of pcoNoLockDirty: "no-lock-dirty-siblings"
  of pcoSkippedNoWorkspace: "skipped-no-workspace"
  of pcoNoLockFailed: "no-lock-failed"
  of pcoSkippedMembershipRepo: "skipped-membership-repo"
  of pcoSkippedGitOperation: "skipped-git-operation-in-progress"
  of pcoInertGitStateUnknown: "inert-git-state-unknown"

proc postCommitOutcomeKind*(outcome: PostCommitOutcome): PostCommitOutcomeKind =
  ## CLI/health.md's classification. Exhaustive on purpose (no ``else``): an
  ## outcome added to the writer does not compile until it is placed here.
  ##
  ## ``no-manifest-record`` is NO RECORD DUE, not a refusal: the writer
  ## succeeded and the record lives elsewhere — routed per repo, or, in a
  ## public-only workspace, in the in-repo ``repro.lock``. Public-only is the
  ## default when no team route is declared, so classing it as a refusal made
  ## every such workspace ``fail`` after its second ordinary commit (measured
  ## end to end; the integration suite keeps that case).
  case outcome
  of pcoPublished, pcoWrittenPending, pcoWrittenLocalOnly, pcoWrittenUnknown:
    pokWrote
  of pcoNoLockDirty, pcoNoLockFailed:
    pokRefused
  of pcoNoManifestRecord, pcoSkippedMembershipRepo, pcoSkippedNoWorkspace,
     pcoSkippedGitOperation, pcoInertGitStateUnknown:
    pokNoRecordDue

proc parsePostCommitOutcomeTag*(tag: string): Option[PostCommitOutcome] =
  ## The outcome whose tag is exactly ``tag``, or none. Derived from
  ## ``postCommitOutcomeTag`` rather than from a second table of literals, so
  ## the two cannot disagree. Tags a retired writer used (``ok``,
  ## ``skipped-dirty``, ``failed``) are not outcomes and answer none.
  for outcome in PostCommitOutcome:
    if postCommitOutcomeTag(outcome) == tag:
      return some(outcome)
  none(PostCommitOutcome)

# ---- reading the trace ------------------------------------------------------

const
  PostCommitTraceTailBytes* = 4 * 1024 * 1024
    ## How much of the trace the row reads (CLI/health.md: "the last 4 MiB").
    ## The trace is append-only and never rotated, so reading it whole would
    ## make the doctor's cost grow with the workspace's age. A refusal run
    ## that does not fit in 4 MiB has long since earned its ``fail``.
  PostCommitTraceTimestampFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    ## What ``isoTimestampNow`` writes. A line whose first field does not
    ## parse with it is malformed and ignored, like the spec says.

type
  LockWriterRefusalReason* = object
    ## One distinct refusal reason in the run: outcome tag plus diagnostic,
    ## compared with the timestamp removed.
    outcome*: string
    diagnostic*: string
    count*: int          ## How many lines of the run carry it.
    newestAt*: string    ## Timestamp of its newest line.
    oldestAt*: string    ## Timestamp of its oldest line.

  LockWriterTraceSummary* = object
    ## What the trace says, before any wording. Timestamps are kept as the
    ## trace spelled them; "" means "there was none".
    tailOnly*: bool
      ## The text was the last ``PostCommitTraceTailBytes`` of a longer file,
      ## so "none written" and "the run started at" are bounded by the window.
    outcomeLines*: int
    newestOutcome*: string
    newestOutcomeAt*: string
    newestWrittenAt*: string
    runLength*: int       ## Refused lines after the newest wrote line.
    runStartedAt*: string ## Oldest line of the run.
    runNewestAt*: string  ## Newest line of the run.
    reasons*: seq[LockWriterRefusalReason]
      ## Every distinct reason in the run, NEWEST FIRST (by its newest line).

  LockWriterVerdict* = enum
    lwvOk = "ok"
    lwvWarn = "warn"
    lwvFail = "fail"

  LockWriterRow* = object
    ## The row, rendered. ``remedy`` is "" for ``ok``. ``data`` is what
    ## ``--json`` carries beside the detail.
    verdict*: LockWriterVerdict
    detail*: string
    remedy*: string
    data*: JsonNode

proc parseTraceTimestamp(field: string): Option[Time] =
  try:
    some(parse(field, PostCommitTraceTimestampFormat, utc()).toTime())
  except CatchableError:
    none(Time)

proc summarizePostCommitTrace*(text: string;
                               tailOnly = false): LockWriterTraceSummary =
  ## Classify every line of ``text`` (the trace, or its tail) per
  ## CLI/health.md. Pure.
  ##
  ## A line is ``<timestamp> <outcome> <diagnostic>``. A line whose second
  ## field is not an outcome tag (the ``evidence`` lines, a retired writer's
  ## tag) is ignored, and so is one whose timestamp does not parse — that
  ## includes the continuation of any diagnostic that ever carried a newline.
  result.tailOnly = tailOnly
  # The run is rebuilt from scratch at every wrote line, so after the loop it
  # holds exactly the refused lines after the newest one.
  var run: seq[tuple[at, tag, diagnostic: string]]
  for raw in text.splitLines():
    let line = raw.strip(leading = false, trailing = true)
    let fields = line.split(' ', maxsplit = 2)
    if fields.len < 2 or parseTraceTimestamp(fields[0]).isNone:
      continue
    let outcome = parsePostCommitOutcomeTag(fields[1])
    if outcome.isNone:
      continue
    let at = fields[0]
    let tag = fields[1]
    let diagnostic = if fields.len > 2: fields[2] else: ""
    inc result.outcomeLines
    result.newestOutcome = tag
    result.newestOutcomeAt = at
    case postCommitOutcomeKind(outcome.get)
    of pokWrote:
      result.newestWrittenAt = at
      run.setLen(0)
    of pokRefused:
      run.add((at: at, tag: tag, diagnostic: diagnostic))
    of pokNoRecordDue:
      discard
  result.runLength = run.len
  if run.len > 0:
    result.runStartedAt = run[0].at
    result.runNewestAt = run[^1].at
  # Newest first, so the reason a reader is most likely already looking at
  # comes first — and every OLDER one is still listed after it, which is the
  # whole point: the reason on the last line can hide another that still
  # stands.
  #
  # Keyed on tag + the FIRST line of the diagnostic (CLI/health.md). That is
  # all a line carries here: a diagnostic the writer wrote with an embedded
  # newline (``no-lock-failed``'s IO errors append "Additional info: <path>")
  # leaves its continuation on lines the loop above already discarded.
  var index = initTable[string, int]()
  for i in countdown(run.high, 0):
    let key = run[i].tag & "\0" & run[i].diagnostic
    if key in index:
      let at = index[key]
      inc result.reasons[at].count
      result.reasons[at].oldestAt = run[i].at
    else:
      index[key] = result.reasons.len
      result.reasons.add(LockWriterRefusalReason(outcome: run[i].tag,
        diagnostic: run[i].diagnostic, count: 1, newestAt: run[i].at,
        oldestAt: run[i].at))

proc lockWriterVerdict*(summary: LockWriterTraceSummary): LockWriterVerdict =
  ## CLI/health.md: an empty run is ``ok``, a run of one ``warn``, and a run of
  ## two or more ``fail`` — the refusal repeated, so the operator has committed
  ## through it at least once.
  if summary.runLength >= 2: lwvFail
  elif summary.runLength == 1: lwvWarn
  else: lwvOk

proc formatTraceAge*(at: string; now: Time): string =
  ## "3d 4h ago" for a trace timestamp. Coarse on purpose: the row answers
  ## "how long has this been going on", not "at which second".
  let parsed = parseTraceTimestamp(at)
  if parsed.isNone:
    return "at " & at
  let secs = max(0'i64, (now - parsed.get).inSeconds)
  let days = secs div 86_400
  let hours = (secs mod 86_400) div 3_600
  let minutes = (secs mod 3_600) div 60
  if days > 0: $days & "d " & $hours & "h ago"
  elif hours > 0: $hours & "h " & $minutes & "m ago"
  elif minutes > 0: $minutes & "m ago"
  else: $secs & "s ago"

proc describeReason(reason: LockWriterRefusalReason): string =
  # The diagnostic is quoted because it carries its own commas (a list of
  # dirty siblings), and reasons are themselves joined with "; ".
  reason.outcome & " (" & $reason.count &
    (if reason.count == 1: " run" else: " runs") & "): \"" &
    reason.diagnostic & "\""

proc lockWriterDataJson*(summary: LockWriterTraceSummary;
                         tracePath: string): JsonNode =
  ## The ``--json`` payload: run length, the timestamps, and the full reason
  ## list. A timestamp the trace does not have is ``null``, never "".
  proc tsOrNull(value: string): JsonNode =
    if value.len > 0: %value else: newJNull()
  result = %*{
    "tracePath": tracePath,
    "tailOnly": summary.tailOnly,
    "outcomeLines": summary.outcomeLines,
    "newestOutcome": tsOrNull(summary.newestOutcome),
    "newestOutcomeAt": tsOrNull(summary.newestOutcomeAt),
    "newestWrittenAt": tsOrNull(summary.newestWrittenAt),
    "runLength": summary.runLength,
    "runStartedAt": tsOrNull(summary.runStartedAt),
    "runNewestAt": tsOrNull(summary.runNewestAt),
  }
  var reasons = newJArray()
  for reason in summary.reasons:
    reasons.add(%*{
      "outcome": reason.outcome,
      "diagnostic": reason.diagnostic,
      "count": reason.count,
      "newestAt": reason.newestAt,
      "oldestAt": reason.oldestAt,
    })
  result["reasons"] = reasons

proc evaluateLockWriterTrace*(text: string; now: Time; tracePath: string;
                              tracePresent = true; tailOnly = false;
                              reproCommand = "repro";
                              readError = ""): LockWriterRow =
  ## The whole ``lock-writer`` row from the trace's text. Pure: ``now`` is a
  ## parameter so ages are reproducible, and the caller does the reading.
  ##
  ## ``reproCommand`` is how the remedy spells `repro` (health renders remedies
  ## with the running binary's own path, so they are copy-pasteable without
  ## depending on PATH). ``readError`` non-empty means the trace exists and
  ## could not be read; ``text`` is then ignored.
  if readError.len > 0:
    # CLI/health.md: "trace present but unreadable" is ``warn``, naming the
    # path and the error. Not ``ok``: an unjudgeable outcome is not the same
    # answer as "nothing ran", and the eighteen-day incident is exactly what
    # an ``ok`` here could hide again.
    result.verdict = lwvWarn
    result.detail = "the post-commit trace " & tracePath & " exists but " &
      "cannot be read (" & readError & "), so the lock writer's outcome " &
      "cannot be judged"
    result.remedy = "restore read access to " & tracePath & " (check its " &
      "owner and mode), then re-run `" & reproCommand & " health`"
    result.data = %*{"tracePath": tracePath, "readError": readError}
    return
  let summary = summarizePostCommitTrace(text, tailOnly)
  result.verdict = lockWriterVerdict(summary)
  result.data = lockWriterDataJson(summary, tracePath)
  let window = if summary.tailOnly: " in the last 4 MiB of the trace" else: ""
  let newestWritten =
    if summary.newestWrittenAt.len > 0:
      "newest lock record written " &
        formatTraceAge(summary.newestWrittenAt, now) & " (" &
        summary.newestWrittenAt & ")"
    elif summary.tailOnly:
      "no lock record written" & window
    else:
      "the trace shows no lock record ever written"
  if summary.outcomeLines == 0:
    # No run recorded. Whether the hook is installed at all is the
    # ``vcs-hooks`` row's question; answering it here too would make two rows
    # disagree about the same file.
    result.detail = "no post-commit run recorded" &
      (if tracePresent: " in " & tracePath else: " (no trace at " &
        tracePath & ")")
    return
  if result.verdict == lwvOk:
    result.detail = "newest post-commit outcome " & summary.newestOutcome &
      " " & formatTraceAge(summary.newestOutcomeAt, now) & "; " &
      newestWritten
    return
  var reasons: seq[string]
  for reason in summary.reasons:
    reasons.add(describeReason(reason))
  let started =
    # With no wrote line inside the window the run may be older than the
    # window itself, so its true start is unknown: say "at or before".
    (if summary.tailOnly and summary.newestWrittenAt.len == 0:
       "started at or before "
     else: "started ") &
    summary.runStartedAt & " (" & formatTraceAge(summary.runStartedAt, now) &
    ")"
  result.detail = "the post-commit lock writer refused on the last " &
    $summary.runLength &
    (if summary.runLength == 1: " run" else: " consecutive runs") &
    " and wrote no lock record; the run " & started & "; " & newestWritten &
    ". " & $summary.reasons.len & " distinct refusal reason(s), newest " &
    "first: " & reasons.join("; ")
  let newest = summary.reasons[0]
  result.remedy = "fix the newest refusal (" & newest.outcome & ": " &
    newest.diagnostic & "), then run `" & reproCommand & " workspace lock` " &
    "to confirm the writer succeeds; every run is in " & tracePath

type
  PostCommitTraceRead* = object
    ## What reading the trace found. ``present`` with a non-empty ``error``
    ## is the "exists but cannot be read" state CLI/health.md reports as
    ## ``warn``: it is not the same answer as "nothing ran", so it must not
    ## collapse into the absent case.
    present*: bool
    error*: string
    text*: string
    tailOnly*: bool

proc readPostCommitTraceTail*(path: string): PostCommitTraceRead =
  ## The last ``PostCommitTraceTailBytes`` of the trace at ``path``. A trace
  ## longer than that loses the line the window cuts, which would otherwise
  ## be read as malformed (harmless) or, worse, as a valid line cut mid-
  ## diagnostic. A line that STARTS exactly at the window's first byte is
  ## whole and is kept: the reader also reads the one byte before the window,
  ## so it can tell "cut" from "begins here". Dropping it unconditionally
  ## would discard a complete line, and when that line is the only written
  ## record in the window the row would misreport the run. Never raises.
  ##
  ## Absent means nothing exists at ``path`` (``symlinkExists`` too, so a
  ## dangling link counts as present and unreadable rather than as no trace).
  ## Anything that exists and cannot be opened or read carries the OS error.
  if not fileExists(path) and not symlinkExists(path) and not dirExists(path):
    return PostCommitTraceRead(present: false)
  result.present = true
  if dirExists(path):
    # Nim's ``open`` refuses a directory without setting errno, so the OS
    # message would read "Success". Name the actual problem.
    result.error = "is a directory, not a file"
    return
  var f: File
  if not open(f, path, fmRead):
    result.error = osErrorMsg(osLastError())
    return
  defer: f.close()
  try:
    let size = f.getFileSize()
    if size <= PostCommitTraceTailBytes:
      result.text = f.readAll()
      return
    # One byte of look-behind: the window proper is ``text[1 .. ^1]``, and
    # everything up to and including the first newline is dropped. When
    # ``text[0]`` is itself a newline the window starts on a line boundary
    # and only that look-behind byte goes.
    f.setFilePos(size - PostCommitTraceTailBytes - 1)
    var text = newString(PostCommitTraceTailBytes + 1)
    let got = f.readBuffer(addr text[0], PostCommitTraceTailBytes + 1)
    text.setLen(got)
    let firstBreak = text.find('\n')
    result.text = if firstBreak >= 0: text[firstBreak + 1 .. ^1] else: ""
    result.tailOnly = true
  except CatchableError as err:
    # A directory at the path opens on POSIX and fails here, as does an IO
    # error mid-read. Either way nothing read is trustworthy.
    result.text = ""
    result.tailOnly = false
    result.error = err.msg
