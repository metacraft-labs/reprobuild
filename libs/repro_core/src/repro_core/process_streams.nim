## Reading a child process's output stream to the END of it.
##
## N51 / M5-R5 / N50 — THE SHORT READ
## ==================================
##
## ``streams.readAll`` is NOT "read until EOF". Its loop is:
##
##     while true:
##       let readBytes = readData(s, addr buffer[0], 1024)
##       if readBytes == 0: break
##       ...
##       if readBytes < 1024: break        # <-- here
##
## so it returns at the first read that does not fill the 1 KiB buffer. For a
## FILE that means EOF. For a PIPE it means "the writer had not got round to
## it yet", which is a completely ordinary thing for a child process to do.
##
## On WINDOWS this bites, because ``osproc.outputStream`` is a raw
## ``FileHandleStream`` whose ``readData`` is one ``ReadFile`` call, and
## ``ReadFile`` on a pipe returns as soon as ANY bytes are available. Measured
## on this host against ``t_n51_drain_process_stream``'s fixture child, which
## writes 5 bytes, flushes, sleeps 900 ms, then writes the remaining 404:
##
##     naive readAll(): bytes=5   exit=7 sawTail=false
##     drain loop     : bytes=409 exit=7 sawTail=true
##
## Five bytes of a 409-byte diagnostic, and the process exit code was right in
## both cases — so nothing about the capture looked wrong. That is the same
## shape M5 reported as its R5 (one byte of a four-line child diagnostic) and
## the same one that recurred as N50, where a truncated observer log made a
## real failure read as an empty one.
##
## On POSIX ``osproc`` hands back a ``FileStream`` over a stdio ``File``, and
## ``fread`` loops internally until the full count or real EOF — so the same
## ``readAll`` is already correct there. The defect is Windows-only; the
## remedy below is not, because writing it once is cheaper than writing
## ``when defined(windows)`` at every call site.
##
## WHAT THIS CHANGES, STATED PLAINLY
## ---------------------------------
##
## ``readAll`` returns EARLY on a slow writer. ``drainStream`` does not: it
## blocks until the write end is CLOSED. For a finite child that exits, those
## differ only in completeness. They differ in KIND for a child that leaks a
## descendant holding the pipe's write handle open — there the early return
## was accidentally load-bearing and this loop would hang. That case is real
## and documented in this tree (``repro_interface_artifacts.runCommand``: on
## Windows ``nim`` exits while ``gcc`` still holds the write handle, which is
## why that path writes to a temp-file sink instead of a pipe). So this is a
## helper to apply after asking whether the child can outlive its own stdout,
## NOT a sweep to run over every ``readAll`` in the tree.
##
## A bounded alternative exists and is deliberately not duplicated here:
## ``tools/test-runner``'s ``drainProbePipe`` polls ``PeekNamedPipe`` /
## non-blocking reads against a deadline. That is the right answer where the
## child is arbitrary and untrusted, and it is ~60 lines of per-platform
## handle code. Sites whose child is a known, finite tool take this instead.

import std/[streams]

proc drainStream*(s: Stream): string =
  ## Read ``s`` until its write end closes, rather than until the first short
  ## read. A nil stream reads as "".
  ##
  ## The loop is ``9c8a97d6``'s: ``atEnd`` is accurate on both backends
  ## (Nim 2.2's ``hsAtEnd`` is set only on a zero-byte read — the
  ## ``br < bufLen`` variant that would have made this loop useless is
  ## commented out in ``osproc``), so repeating ``readAll`` until ``atEnd``
  ## terminates exactly at EOF.
  if s == nil:
    return ""
  result = ""
  while not s.atEnd():
    result.add(s.readAll())
