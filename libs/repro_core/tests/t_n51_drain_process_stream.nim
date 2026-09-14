## N51 / M5-R5 / N50 — a child process's output must be read to the END.
##
## `streams.readAll` is not "read until EOF". Its loop breaks at the first
## read that does not fill its 1 KiB buffer, which for a PIPE means "the
## writer paused", not "the writer finished". On Windows `osproc`'s stream is
## a raw handle and one `ReadFile` per read, and `ReadFile` on a pipe returns
## as soon as ANY bytes are available — so a child that flushes a few bytes
## and then pauses ends the parent's capture there.
##
## Measured on the development host with the fixture below, before the fix:
##
##     naive readAll(): bytes=5   exit=7 sawTail=false
##     drain loop     : bytes=409 exit=7 sawTail=true
##
## Five bytes of a 409-byte diagnostic, with the exit code correct in both
## cases — so nothing about the capture looked wrong. That is M5's R5 (one
## byte of a four-line child diagnostic) and N50's truncated observer log.
##
## THE FIXTURE, and why it is shaped this way.
##
## The child writes a small chunk, FLUSHES, PAUSES, then writes the rest. The
## pause is what makes the short read reachable; the total is kept small on
## purpose. An earlier version of this fixture wrote 200 KB in one burst to
## "exceed a pipe buffer", and it did something more interesting than
## truncate: the child blocked writing into a full pipe while the parent sat
## in `waitForExit`, and the pair DEADLOCKED. That is a different bug (read
## ordering, not read completeness) and it makes a poor unit test, because a
## hung test reports nothing at all. So the fixture stays under the pipe
## buffer and tests exactly one thing.
##
## VACUITY, per assertion:
##
##   * `check captured == expected` cannot pass on a truncated capture — it
##     compares the whole byte string, not a length or a prefix. The
##     measurement above is the evidence that the untruncated form is not
##     automatic: the SAME fixture through `readAll` yields 5 bytes.
##   * A fixture that never actually paused would make the drain trivially
##     equal to `readAll`, so `shortReadWasReachable` below re-runs the same
##     fixture through plain `readAll` and REPORTS what it got. On Windows it
##     is additionally asserted to be short: if that assertion ever fails,
##     either Nim's `readAll` changed or the host was too loaded to reach the
##     first read inside the pause, and both are things a reader should be
##     told rather than have silently absorbed.
##   * `check exitCode == 7` guards against the whole thing passing because
##     the child never ran: a child that failed to spawn produces an empty
##     capture AND a different exit code.

import std/[os, osproc, streams, strutils, unittest]

import repro_core/process_streams

const
  Head = "first"
  Filler = 400
  Tail = "LAST"
  PauseMs = 900
    ## Long enough that the parent's first read lands inside the pause on any
    ## machine that is not pathologically loaded. The parent reaches its first
    ## read microseconds after `startProcess` returns.

proc expectedOutput(): string =
  Head & repeat('x', Filler) & Tail

proc fixtureChild(): tuple[exe: string; args: seq[string]] =
  ## A child that writes, flushes, pauses, then writes the rest and exits 7.
  ## Uses the host's own shell rather than a compiled helper so this test
  ## needs no build-time fixture binary.
  when defined(windows):
    let ps =
      block:
        let pwsh = findExe("pwsh")
        if pwsh.len > 0: pwsh else: findExe("powershell")
    (exe: ps, args: @["-NoProfile", "-Command",
      "[Console]::Out.Write('" & Head & "'); [Console]::Out.Flush(); " &
      "Start-Sleep -Milliseconds " & $PauseMs & "; " &
      "[Console]::Out.Write(('x' * " & $Filler & ")); " &
      "[Console]::Out.Write('" & Tail & "'); " &
      "[Console]::Out.Flush(); exit 7"])
  else:
    # `head -c N /dev/zero | tr` is available on GNU coreutils, BSD and
    # busybox alike; `seq` and brace expansion are not portable across all
    # three.
    (exe: "/bin/sh", args: @["-c",
      "printf '" & Head & "'; sleep " & $(PauseMs.float / 1000.0) & "; " &
      "head -c " & $Filler & " /dev/zero | tr '\\0' 'x'; " &
      "printf '" & Tail & "'; exit 7"])

proc captureDrained(): tuple[output: string; exitCode: int] =
  let fx = fixtureChild()
  let p = startProcess(fx.exe, args = fx.args, options = {poStdErrToStdOut})
  defer: p.close()
  result.output = drainStream(p.outputStream)
  result.exitCode = p.waitForExit()

proc captureNaive(): tuple[output: string; exitCode: int] =
  ## The pre-N51 shape, kept ONLY so this test can show that the thing it
  ## fixes was reachable on the host it just ran on.
  let fx = fixtureChild()
  let p = startProcess(fx.exe, args = fx.args, options = {poStdErrToStdOut})
  defer: p.close()
  result.output = p.outputStream.readAll()
  result.exitCode = p.waitForExit()

suite "N51 repro_core/process_streams: drainStream reads a child to EOF":

  test "a child that pauses mid-output is captured WHOLE":
    let fx = fixtureChild()
    doAssert fx.exe.len > 0, "no shell to build the fixture child from"
    let got = captureDrained()
    let want = expectedOutput()
    echo "  drained bytes=", got.output.len, " exit=", got.exitCode
    # Not a length check and not a prefix check: the whole byte string.
    check got.output == want
    # If the child never ran, `output` would be empty AND this would differ.
    check got.exitCode == 7

  test "the same fixture through plain readAll shows the short read":
    let naive = captureNaive()
    let want = expectedOutput()
    echo "  naive readAll bytes=", naive.output.len, " of ", want.len,
         " exit=", naive.exitCode, " sawTail=", naive.output.contains(Tail)
    check naive.exitCode == 7
    when defined(windows):
      # The defect is Windows-only: there `osproc` hands back a raw handle
      # stream and one `ReadFile` returns whatever is available. On POSIX the
      # stream is stdio and `fread` loops to the full count or real EOF, so
      # `readAll` is already correct and this assertion would be wrong.
      check naive.output.len < want.len
      check not naive.output.contains(Tail)
    else:
      if naive.output.len == want.len:
        echo "  NOTE (expected on POSIX): plain readAll captured everything, " &
             "because stdio's fread loops to EOF. The drain loop is a no-op " &
             "here and load-bearing on Windows."
      else:
        echo "  NOTE: plain readAll was ALSO short on this POSIX host — " &
             "worth knowing, the stdio assumption does not hold here."

  test "drainStream on a nil stream is empty, not a crash":
    ## Every call site guards `outputStream != nil` or relies on this.
    check drainStream(nil) == ""
