## Windows-Runner-Binary-Cache-Deploy — the deploy agent's TICK HISTORY.
##
## `tick_status.nim` answers "is it broken right now, and how old is that
## answer" — one record, overwritten every tick. That is exactly what an
## alert needs and exactly the wrong shape for the questions that dominate
## the troubleshooting that follows the alert:
##
##   * WHEN did this start failing?
##   * did it FLAP, or fail continuously?
##   * what was the last GOOD tick before the first bad one?
##
## In the win-ci-bare-001 incident (2026-08-19/20) the box was wedged for
## THIRTEEN HOURS. A status file would have shown the current failure
## instantly; reconstructing that thirteen-hour window — 78 ticks, all of
## them failing, none of them recorded — would still have been impossible.
##
## So every tick ALSO appends one line to
##
##     <stateDir>/deploy-agent/<safe-target>.tick-history.jsonl
##
## next to the status file it mirrors. The line is the SAME record, in the
## same schema (`TickStatusSchemaId`), rendered compactly instead of
## pretty-printed — so a reader parses the status file and any history line
## with ONE code path, and a second schema cannot drift away from the first.
##
## Three properties are load-bearing and all three are pinned by
## `t_repro_deploy_agent_records_tick_history`:
##
##   * APPEND, never overwrite. Successive ticks accumulate in tick order;
##     a failing tick is appended with its error text exactly like a good
##     one. A history that only records successes is worthless.
##   * BOUNDED. This loop ticks every ten minutes, unattended, forever. The
##     file is capped at `TickHistoryDefaultMaxEntries` records — fourteen
##     days at that interval — and the two free-text fields are truncated
##     at `TickHistoryMaxTextChars`, so the worst case is a few megabytes
##     rather than a full disk. Compaction keeps the NEWEST entries and is
##     staged through `<path>.tmp` + rename, so a crash mid-compaction
##     leaves the pre-compaction file rather than a truncated one. This
##     mirrors the daemon's `stats_store` retention shape (append, then
##     read-filter-rewrite) rather than inventing a second policy.
##   * BEST EFFORT at the `recordTickHistory` boundary, like
##     `recordTickStatus`: appending must never change the tick's exit code
##     nor mask the original error.
##
## Crash-safety of the append itself is structural rather than staged: the
## record is written with a single `write` on a handle opened in append
## mode, so the write only ever EXTENDS the file. A crash mid-write can
## leave a torn final line; it can never corrupt an earlier one. Readers
## skip lines that do not parse (`readTickHistory`), and the next append
## re-terminates a torn tail first so the new record does not get
## concatenated onto the garbage.

import std/[json, os, strutils]

import ./agent
import ./tick_status

const
  TickHistoryFileSuffix* = ".tick-history.jsonl"

  TickHistoryDefaultMaxEntries* = 2016
    ## 6 ticks/hour * 24 * 14 — a fortnight of ten-minute ticks. Long enough
    ## that "when did this start?" is answerable for an incident nobody
    ## noticed over a holiday, short enough that the file stays small.

  TickHistoryMaxTextChars* = 2048
    ## Per-field cap on `message` and `error`. Without it the entry cap is
    ## not a SIZE bound at all: an exception message is arbitrarily long
    ## (a compiler dump, a stack trace), and 2016 of them are not.
    ##
    ## Worst case with both fields at the cap: ~4.4 KB/line, ~9 MB total.
    ## Typical: ~350 B/line, ~700 KB.

  TickHistoryTruncationSuffix* = "...[truncated]"

  TickHistoryMaxEntriesEnvVar* = "REPRO_DEPLOY_AGENT_TICK_HISTORY_MAX"
    ## Operator override for the cap — a box on a one-minute timer wants a
    ## different fortnight than a box on a ten-minute one. Also the seam the
    ## rotation gate uses, so the test can bound a file at a handful of
    ## records instead of writing 2016 of them.

proc tickHistoryPath*(stateDir, target: string): string =
  ## Sibling of `tickStatusPath` and `sequenceStatePath` — same directory,
  ## same per-target filesystem-safe stem, so two targets sharing a state
  ## dir cannot interleave their histories.
  stateDir / "deploy-agent" / (safeTargetName(target) & TickHistoryFileSuffix)

proc tickHistoryPath*(cfg: AgentConfig): string =
  tickHistoryPath(cfg.stateDir, cfg.target)

proc tickHistoryMaxEntries*(): int =
  ## The effective cap. A missing, non-numeric or non-positive override is
  ## ignored in favour of the default: an operator who fat-fingers the
  ## variable gets a bounded file, not an unbounded one.
  result = TickHistoryDefaultMaxEntries
  let raw = getEnv(TickHistoryMaxEntriesEnvVar, "").strip()
  if raw.len == 0:
    return
  try:
    let parsed = parseInt(raw)
    if parsed > 0:
      result = parsed
  except ValueError:
    discard

proc truncatedForHistory*(text: string;
                          limit = TickHistoryMaxTextChars): string =
  ## Bound one free-text field, marking the cut so a reader can tell a
  ## short message from a shortened one.
  if text.len <= limit:
    return text
  text[0 ..< limit] & TickHistoryTruncationSuffix

proc boundedForHistory*(rec: TickStatusRecord): TickStatusRecord =
  ## The record as it goes into the history: identical except that the two
  ## unbounded fields are capped. The STATUS file deliberately keeps the
  ## full text — it is one record, so it cannot grow without limit, and it
  ## is the copy an operator reads first.
  result = rec
  result.message = truncatedForHistory(rec.message)
  result.error = truncatedForHistory(rec.error)

proc renderTickHistoryLine*(rec: TickStatusRecord): string =
  ## One JSONL line. Compact — `$` on a `JsonNode` escapes newlines inside
  ## strings, so a record whose error text spans lines still occupies
  ## exactly one line and cannot forge a record boundary.
  $rec.toJsonNode() & "\n"

proc readTickHistory*(path: string): seq[JsonNode] =
  ## Every parseable record, oldest first. Unparseable lines are SKIPPED
  ## rather than fatal — a torn tail from a crash mid-append must not cost
  ## a reader the 2015 good records in front of it. Mirrors the daemon
  ## stats store's `readJsonLines`.
  if not fileExists(path):
    return
  for line in readFile(path).splitLines:
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue
    try:
      result.add(parseJson(trimmed))
    except JsonParsingError:
      discard

proc endsWithNewline(path: string): bool =
  ## True when the file is absent, empty, or already terminated. A `false`
  ## means a previous append was cut short by a crash or a full disk.
  if not fileExists(path):
    return true
  var f: File
  if not open(f, path, fmRead):
    return true
  defer: f.close()
  let size = f.getFileSize()
  if size <= 0:
    return true
  f.setFilePos(size - 1)
  var last: char
  if f.readBuffer(addr last, 1) != 1:
    return true
  last == '\n'

proc trimTickHistory*(path: string; maxEntries: int) =
  ## Compact to the NEWEST `maxEntries` records. Raises on failure.
  ##
  ## The rewrite is staged at `<path>.tmp` in the same directory and
  ## renamed over the log — one atomic replace, exactly as `writeTickStatus`
  ## does and for the same reason: a crash partway through compaction must
  ## leave the previous, longer file intact rather than a half-written one.
  ## Deliberately NO truncate-in-place, which would put every record at
  ## risk to save the newest ones.
  if maxEntries <= 0 or not fileExists(path):
    return
  var lines: seq[string] = @[]
  for line in readFile(path).splitLines:
    let trimmed = line.strip()
    if trimmed.len > 0:
      lines.add(trimmed)
  if lines.len <= maxEntries:
    return
  let tmp = path & ".tmp"
  writeFile(tmp, lines[lines.len - maxEntries .. ^1].join("\n") & "\n")
  moveFile(tmp, path)

proc appendTickHistory*(path: string; rec: TickStatusRecord;
                        maxEntries: int) =
  ## Append `rec` and enforce the cap. Raises on failure —
  ## `recordTickHistory` is the best-effort wrapper the tick path uses.
  let dir = parentDir(path)
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)
  # Re-terminate a torn tail BEFORE appending, so this record does not end
  # up glued to the fragment a crashed predecessor left behind. The
  # fragment stays (unparseable, skipped by readers); this record does not
  # join it.
  let terminator = if endsWithNewline(path): "" else: "\n"
  block appendOne:
    # `fmAppend` maps to `fopen(.., "ab")` in Nim — binary, so the bytes
    # written are the bytes rendered, on Windows as on POSIX, and every
    # write lands at end-of-file.
    var f = open(path, fmAppend)
    defer: f.close()
    f.write(terminator & renderTickHistoryLine(rec))
  trimTickHistory(path, maxEntries)

proc recordTickHistory*(stateDir, target: string; rec: TickStatusRecord) =
  ## BEST EFFORT. Never raises, never changes the caller's exit code.
  ##
  ## Same contract and same rationale as `recordTickStatus`: a full disk or
  ## a read-only state dir must not convert a diagnosable tick failure into
  ## a different, less informative one. The failure is announced on stderr,
  ## which Task Scheduler discards — a courtesy for the interactive case
  ## and nothing more.
  try:
    appendTickHistory(tickHistoryPath(stateDir, target),
      boundedForHistory(rec), tickHistoryMaxEntries())
  except CatchableError as e:
    try:
      stderr.writeLine("repro deploy-agent: could not append the tick " &
        "history record at " & tickHistoryPath(stateDir, target) & ": " & e.msg)
    except CatchableError:
      discard
