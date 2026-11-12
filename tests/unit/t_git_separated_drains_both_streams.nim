## ``repro_core/git_separated``: the drain every stdout-only git reader goes
## through keeps the two streams apart, completely and byte for byte, without
## a shell and without hanging on a full pipe.
##
## The properties:
##
##   1. A child that writes far more than a pipe buffer to BOTH streams, in
##      alternation, finishes and both streams arrive whole. Reading stdout to
##      EOF before stderr would hang here: the child blocks on the full,
##      unread stderr pipe and never closes stdout.
##   2. stdout is captured byte for byte: no newline is appended and ``\r\n``
##      is kept (a note blob or a NUL-delimited listing must be git's bytes).
##   3. The exit status is the child's; ``input`` reaches its stdin.
##   4. ``maxStdoutBytes`` stops an endless stdout: the child is killed and
##      the run reported truncated, not buffered whole.
##   5. No shell interprets the argv: an argument full of shell syntax
##      reaches the program verbatim.
##   6. A program that cannot be started is a failed ``gitRunSeparated`` run
##      (code -1, the reason in ``diagnostic``), never an exception.
##   7. Against real git: a failure's message, which git writes to stderr,
##      is in ``diagnostic`` and NOT in ``output``.
##   8. The run ends when the CHILD exits, not when every holder of its pipes
##      lets go: a background process it leaves holding both pipes (git's
##      detached automatic maintenance) does not hold the reader, and what
##      the child wrote before exiting is still returned.
##
## THE STAND-IN CHILDREN, AND WHY THEY ARE JUSTIFIED. Properties 1-5 and 8 drive
## ``/bin/sh -c '<script>'`` rather than git, because the drain is
## program-agnostic and git cannot be made to write a chosen number of bytes
## to each stream, a chosen byte sequence without a trailing newline, or an
## endless stdout. ``/bin/sh`` here is the PROGRAM under test's child, started
## with a structured argv by the drain itself -- which is also what property
## 5 checks. Property 7 uses the real git. These cases need ``/bin/sh``, so
## they run on POSIX hosts only; the Windows drain is the PeekNamedPipe loop
## the Windows CI lanes exercise through every git reader.
##
## Hermetic: a temp directory only.

import std/[monotimes, os, strutils, tempfiles, times, unittest]

import repro_core/git_separated
import repro_test_support/reasoned_skip

const Sh = "/bin/sh"

proc sh(script: string; input = ""; maxStdoutBytes = -1): SeparatedRun =
  runSeparated(Sh, ["-c", script], nil, input = input,
    maxStdoutBytes = maxStdoutBytes)

suite "git_separated drains stdout and stderr apart":

  test "both streams arrive whole when each overflows a pipe buffer":
    when defined(windows):
      skip("the stand-in child is a /bin/sh script")
    else:
      # 200 rounds of 4 KiB to each stream: 800 KiB per stream, far beyond
      # a 64 KiB pipe buffer, alternating so neither can be read first.
      let run = sh("i=0; line=$(printf '%4095s' '' | tr ' ' o); " &
        "while [ $i -lt 200 ]; do echo \"$line\"; echo \"$line\" >&2; " &
        "i=$((i+1)); done")
      check run.code == 0
      check not run.truncated
      check run.stdoutText.len == 200 * 4096
      check run.stderrText.len == 200 * 4096
      check run.stdoutText.count('o') == 200 * 4095

  test "stdout is captured byte for byte":
    when defined(windows):
      skip("the stand-in child is a /bin/sh script")
    else:
      let run = sh("printf 'a\\r\\nb\\0c'; printf 'warn' >&2")
      check run.code == 0
      check run.stdoutText == "a\r\nb\0c"
      check run.stderrText == "warn"

  test "the exit status is the child's and input reaches its stdin":
    when defined(windows):
      skip("the stand-in child is a /bin/sh script")
    else:
      let run = sh("cat; echo oops >&2; exit 3", input = "one\ntwo\n")
      check run.code == 3
      check run.stdoutText == "one\ntwo\n"
      check run.stderrText == "oops\n"

  test "an endless stdout is cut off at maxStdoutBytes":
    when defined(windows):
      skip("the stand-in child is a /bin/sh script")
    else:
      let run = sh("while :; do echo yyyyyyyyyyyyyyy; done",
        maxStdoutBytes = 100_000)
      check run.truncated
      check run.code == -1
      check run.stdoutText.len > 100_000

  test "no shell interprets the argv":
    when defined(windows):
      skip("the stand-in child is a /bin/sh script")
    else:
      let scratch = createTempDir("repro-gitsep-argv-", "")
      defer: removeDir(scratch)
      let canary = scratch / "canary"
      let hostile = "$(touch " & canary & "); `touch " & canary & "` *"
      # `printf %s "$0"` prints sh's $0, which is the first argument after
      # the script: the hostile string, delivered as one argv entry.
      let run = runSeparated(Sh, ["-c", "printf %s \"$0\"", hostile], nil)
      check run.code == 0
      check run.stdoutText == hostile
      check not fileExists(canary)

  test "a program that cannot be started is a failed run, not an exception":
    let scratch = createTempDir("repro-gitsep-missing-", "")
    defer: removeDir(scratch)
    let missing = scratch / "no-such-git"
    var raised = false
    try:
      discard runSeparated(missing, ["--version"], nil)
    except OSError:
      raised = true
    check raised
    let res = gitRunSeparated(missing, ["--version"], nil)
    check res.code == -1
    check res.output == ""
    check missing in res.diagnostic

  test "a real git failure's message is in diagnostic, not in output":
    let git = findExe("git")
    if git.len == 0:
      skip("git is not on PATH")
    else:
      let scratch = createTempDir("repro-gitsep-real-", "")
      defer: removeDir(scratch)
      let res = gitRunSeparated(git, ["-C", scratch, "rev-parse",
        "--git-path", "index"], nil)
      check res.code != 0
      check res.output == ""
      check "not a git repository" in res.diagnostic.toLowerAscii()

  test "the run ends when the child exits, not when a grandchild lets go":
    when defined(windows):
      skip("the stand-in child is a /bin/sh script")
    else:
      # The background `sleep` inherits both pipes and holds them for 60 s;
      # the shell itself answers and exits at once.
      let scratch = createTempDir("repro-gitsep-grandchild-", "")
      defer: removeDir(scratch)
      let pidFile = scratch / "pid"
      let started = getMonoTime()
      let run = sh("sleep 60 & echo $! > " & quoteShell(pidFile) &
        "; printf answer; printf warn >&2; exit 4")
      let elapsed = getMonoTime() - started
      # Release the grandchild now rather than leave it to its timer.
      discard runSeparated(Sh, ["-c", "kill \"$(cat \"$0\")\"", pidFile],
        nil)
      check elapsed < initDuration(seconds = 30)
      check run.code == 4
      check run.stdoutText == "answer"
      check run.stderrText == "warn"
