## Live progress for ``repro health``: where the diagnosis is, on stderr,
## while it runs.
##
## The diagnosis sweeps every participating checkout once per row, and a
## single slow probe in a single repository used to hold the whole command
## silent: a run killed by a timeout left NOTHING behind — not the row, not the
## repository, not a count — so "it hangs" could not even be narrowed to a
## check. Each row therefore announces itself when it starts, and each row
## that walks the participating checkouts announces every checkout it reaches,
## so the last line written always names where the time is going.
##
## Two renderings of the same events:
##
## * **lines** (stderr is not a terminal: a log, a pipe, ``2>&1`` into a
##   file): one line per event, written and flushed before the work it names,
##   so a killed run still says which row and which repository it was in;
## * **live** (stderr is a terminal): one status line rewritten in place and
##   erased by ``finish`` before the report is printed, so an interactive run
##   ends with exactly the report it always printed.
##
## A ``nil`` ``HealthProgress`` is silent, and every operation accepts one, so
## the gatherer needs no "is progress on?" branches.

type
  HealthProgressSink* = proc (text: string) {.closure.}
    ## Receives text exactly as it must be written: a whole line including
    ## its newline in line mode, a control sequence and status text in live
    ## mode. The sink must write it unbuffered (flush) — the point of a
    ## progress line is that it is visible BEFORE the work it names.

  HealthProgressMode* = enum
    hpmLines   ## one appended line per event
    hpmLive    ## one terminal line, rewritten in place

  HealthProgress* = ref object
    sink: HealthProgressSink
    mode: HealthProgressMode
    width: int        ## live mode: columns the status line may use
    row: string       ## the row currently running, for item events
    onScreen: bool    ## live mode: a status line is currently displayed

const ProgressPrefix* = "repro health: "
  ## Every progress line starts with this, so a reader of a combined log can
  ## tell progress from the report (which never starts with it).

proc newHealthProgress*(sink: HealthProgressSink; mode: HealthProgressMode;
                        width = 80): HealthProgress =
  ## ``width`` bounds the live status line: a line longer than the terminal
  ## wraps, and a carriage return then rewrites only its last screen row,
  ## leaving the rest behind as debris.
  HealthProgress(sink: sink, mode: mode, width: max(width, 20))

proc emit(p: HealthProgress; text: string) =
  case p.mode
  of hpmLines:
    p.sink(ProgressPrefix & text & "\n")
  of hpmLive:
    var status = ProgressPrefix & text
    # One column is kept free: a line that exactly fills the terminal makes
    # some terminals wrap the cursor onto a fresh row.
    let limit = p.width - 1
    if status.len > limit:
      status = status[0 ..< max(limit - 3, 0)] & "..."
    # CR, then CSI 0 K (erase to end of line):
    # https://invisible-island.net/xterm/ctlseqs/ctlseqs.html (EL).
    p.sink("\r\e[K" & status)
    p.onScreen = true

proc beginRow*(p: HealthProgress; row: string) =
  ## The row named ``row`` (its name in the report) starts now.
  if p.isNil: return
  p.row = row
  p.emit("checking " & row)

proc beginItem*(p: HealthProgress; item: string; index, total: int) =
  ## The current row starts on ``item`` (a checkout's workspace-relative
  ## path), the ``index``-th (1-based) of ``total``.
  if p.isNil: return
  let position = "(" & $index & "/" & $total & ")"
  if p.row.len > 0:
    p.emit(p.row & ": " & item & " " & position)
  else:
    p.emit(item & " " & position)

proc finish*(p: HealthProgress) =
  ## The diagnosis is complete. Live mode erases its status line so the
  ## report starts on a clean line; line mode has nothing to take back.
  if p.isNil: return
  if p.mode == hpmLive and p.onScreen:
    p.sink("\r\e[K")
    p.onScreen = false
  p.row = ""
