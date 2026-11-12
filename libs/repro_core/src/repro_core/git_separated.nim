## Running ``git`` with its stdout and stderr kept APART.
##
## This is ``gitRunSeparated``, the reader for a git command whose stdout is
## the answer, and ``runSeparated``, the drain under it. They live in their
## own module, importing nothing outside the standard library but
## ``repro_core``'s own process helpers, so the callers that cannot depend on
## ``repro_workspace_vcs`` -- the DSL stdlib, the agent backend, the workspace
## snapshot, and the tools that do not link the workspace libraries
## (``tools/catalog-harvester``, ``tools/test-runner``) -- read git's answers through the same code as the
## engine instead of a copy of it. ``git_tool`` re-exports it, so every
## existing ``import git_tool`` keeps seeing it.
##
## NO SHELL, NO TEMPORARY FILES. The program is started with a structured
## argv (``startProcess``), so neither ``PATH`` lookup by a shell nor shell
## quoting can select or alter the program, and both pipes are drained in one
## ``poll(2)`` loop (POSIX, ``process_exec.drainPipesUntilChildExits``, which
## also stops once the child has exited even if a grandchild it detached
## still holds a pipe) or one ``PeekNamedPipe`` loop (Windows). Reading one
## pipe to EOF and only then the other hangs the moment the unread pipe
## fills, and git's stderr is unbounded in principle (per-ref fetch lines,
## per-object lfs lines). The bytes are captured verbatim on both platforms.
##
## References: poll(2) -- https://man7.org/linux/man-pages/man2/poll.2.html;
## PeekNamedPipe -- https://learn.microsoft.com/windows/win32/api/namedpipeapi/nf-namedpipeapi-peeknamedpipe.

import std/[os, osproc, streams, strtabs, strutils]

import ./ambient_execution
import ./process_close

when defined(windows):
  import std/winlean
else:
  import ./process_exec

type
  SeparatedRun* = object
    ## One finished child, its two output streams kept apart.
    code*: int
      ## The exit status; ``-1`` when the run was cut short (``truncated``).
    stdoutText*: string
      ## stdout, byte for byte.
    stderrText*: string
      ## stderr, byte for byte.
    truncated*: bool
      ## stdout passed ``maxStdoutBytes``; the child was killed and
      ## ``stdoutText`` holds the first ``maxStdoutBytes + 1`` or more bytes.

proc runSeparated*(program: string; args: openArray[string];
                   env: StringTableRef; workingDir = ""; input = "";
                   maxStdoutBytes = -1): SeparatedRun =
  ## Start ``program`` with ``args`` (no shell; ``PATH`` is searched only for
  ## a bare name, as ``startProcess``'s ``poUsePath`` does) under ``env``
  ## (``nil``: this process's environment), in ``workingDir`` (empty: this
  ## process's), and capture stdout and stderr SEPARATELY and completely.
  ##
  ## ``input`` is written to the child's stdin, which is then closed, before
  ## its output is read -- keep it to what the command consumes without
  ## answering line by line (``--stdin`` id lists), as ``execCmdEx`` does.
  ##
  ## ``maxStdoutBytes`` >= 0 stops reading once stdout exceeds it: the child
  ## is killed and ``truncated`` set, so an oversized answer is never
  ## buffered whole.
  ##
  ## Raises ``OSError`` when the child cannot be started (as ``startProcess``
  ## does) or a pipe read fails.
  ##
  ## The child is released with ``closeProcessOnce``, so this is safe on a
  ## thread whose process has other threads allocating descriptors.
  let process = uncontrolledStartProcess(program, workingDir = workingDir,
    args = @args, env = env, options = {poUsePath})
  try:
    let stdinStream = process.inputStream
    if input.len > 0:
      stdinStream.write(input)
    stdinStream.close()
    when defined(windows):
      var buf {.noinit.}: array[16384, char]
      template sinkAppend(sink: var string; count: int) =
        let previousLen = sink.len
        sink.setLen(previousLen + count)
        copyMem(addr sink[previousLen], addr buf[0], count)
      template overLimit(): bool =
        maxStdoutBytes >= 0 and result.stdoutText.len > maxStdoutBytes
      # Nim 2.2's ``readAll`` stops at the first short pipe read on Windows,
      # so a blocking read of either stream would also truncate; peek both
      # handles and read only what is there.
      const PollSleepMs = 2
      let handles = [Handle(process.outputHandle),
                     Handle(process.errorHandle)]
      while true:
        var moved = false
        for i in 0 .. 1:
          var bytesAvail: int32 = 0
          let peeked = peekNamedPipe(handles[i],
            lpTotalBytesAvail = addr bytesAvail)
          if peeked and bytesAvail > 0:
            var bytesRead: int32 = 0
            let toRead = min(int(bytesAvail), buf.len).int32
            let ok = winlean.readFile(handles[i], addr buf[0], toRead,
              addr bytesRead, nil)
            if ok != 0 and bytesRead > 0:
              if i == 0: sinkAppend(result.stdoutText, int(bytesRead))
              else: sinkAppend(result.stderrText, int(bytesRead))
              moved = true
        if overLimit():
          result.truncated = true
          break
        # Only consult the exit code once BOTH pipes are momentarily empty,
        # so everything the child buffered before exiting is still collected.
        if moved: continue
        result.code = process.peekExitCode()
        if result.code != -1: break
        sleep(PollSleepMs)
    else:
      # Both pipes polled together, and the drain stops once the CHILD has
      # exited rather than at EOF: a grandchild git detached (its automatic
      # maintenance) can hold the pipes open long after git answered
      # (``process_exec.drainPipesUntilChildExits``).
      var sinks = ["", ""]
      let drained = drainPipesUntilChildExits(process,
        [process.outputHandle.cint, process.errorHandle.cint], sinks,
        maxFirstBytes = maxStdoutBytes)
      result.stdoutText = move sinks[0]
      result.stderrText = move sinks[1]
      result.truncated = drained.truncated
      result.code = drained.exitCode
    if result.truncated:
      process.kill()
      discard process.waitForExit()
      result.code = -1
  finally:
    closeProcessOnce(process)

proc gitRunSeparated*(gitBin: string; args: openArray[string];
                      env: StringTableRef; exactStdout = false;
                      workingDir = ""; input = ""):
    tuple[code: int; output: string; diagnostic: string] =
  ## Invoke ``gitBin`` with ``args`` under ``env`` for an answer that will be
  ## PARSED, keeping git's stderr OUT of ``output``.
  ##
  ## Merging the two streams (``poStdErrToStdOut``) is right for a caller
  ## that only tests the exit code, or that reads the text precisely BECAUSE
  ## it wants git's diagnostic. It is wrong for a caller that parses git's
  ## ANSWER: a benign diagnostic then arrives indistinguishable from the
  ## answer. Measured: a repository whose split commit-graph chain names a
  ## pruned graph file makes ``git rev-parse HEAD^{commit}``, ``git cat-file
  ## -t`` and ``git rev-list`` print ``warning: unable to find all
  ## commit-graph files`` on stderr while still exiting 0 with the right
  ## answer on stdout; merged, that warning became part of an object id.
  ##
  ## ``output`` is stdout ALONE, byte for byte. ``diagnostic`` is the merged,
  ## trimmed text (stderr first), so a caller reporting a FAILURE still
  ## surfaces git's message, which lives on stderr.
  ##
  ## Never raises for a git that cannot be started: that is a failed run
  ## (``code`` -1) whose ``diagnostic`` says why, like any other failure.
  ##
  ## ``exactStdout`` is kept for the callers that state they need git's bytes
  ## verbatim (a certificate note blob, Transport §3.1; NUL-delimited
  ## listings). Every run is captured verbatim now, so it changes nothing.
  ##
  ## ``workingDir`` is the child's working directory (empty: this process's).
  ## ``input`` is written to the child's stdin, which is then closed, before
  ## its output is read -- keep it to what the command consumes without
  ## answering line by line (``--stdin`` id lists), as ``execCmdEx`` does.
  discard exactStdout
  var run: SeparatedRun
  try:
    run = runSeparated(gitBin, args, env, workingDir = workingDir,
      input = input)
  except CatchableError as err:
    result.code = -1
    result.diagnostic = "cannot run " & gitBin & ": " & err.msg
    return
  result.code = run.code
  result.output = run.stdoutText
  result.diagnostic = (run.stderrText & run.stdoutText).strip()
