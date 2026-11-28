## Preserve the process's real stdout before ``std/unittest`` initialises.
##
## The protocol-carrying codetracer Nim fork reserves stdout for its own
## ``--list``/``--list-json`` document at module initialisation: it duplicates
## descriptor 1, then points descriptor 1 at stderr so arbitrary suite-body
## output cannot corrupt the document.  ``ct_test_unittest_parallel`` owns a
## separate protocol registry and exit hook, so its document cannot use the
## fork's private saved descriptor.  This leaf module is deliberately imported
## before ``std/unittest`` and retains the same original stream for the shim.
##
## The tests entry (``<binary> --entrypoint=tests --list``, the run-time
## selector of nim-entrypoints, https://github.com/metacraft-labs/nim-entrypoints)
## needs one more step with a fork before ``4fda9ccd``.  That fork reads that
## ``--list`` as its own and points descriptor 1 at stderr (from ``4fda9ccd``
## on the fork knows the selector and does not); in a program built with
## nim-entrypoints it is
## nim-entrypoints that prints the list, on descriptor 1, so the list would
## land on stderr.  ``restoreEntryStdout`` points descriptor 1 back at the
## stream kept here, and ``divertStdoutToStderr`` is the fork's protection,
## taken back up by the shim when it is the one printing the list (through
## ``writeShimProtocolLine``, which never needed descriptor 1).

import std/[os, strutils]

when declared(stdout):
  when defined(windows):
    proc shimDupFd(fd: cint): cint {.importc: "_dup", header: "<io.h>".}
    proc shimDup2Fd(oldFd, newFd: cint): cint {.
      importc: "_dup2", header: "<io.h>".}
    proc shimCloseFd(fd: cint): cint {.importc: "_close", header: "<io.h>".}
  else:
    proc shimDupFd(fd: cint): cint {.importc: "dup", header: "<unistd.h>".}
    proc shimDup2Fd(oldFd, newFd: cint): cint {.
      importc: "dup2", header: "<unistd.h>".}
    proc shimCloseFd(fd: cint): cint {.importc: "close", header: "<unistd.h>".}

  var
    shimProtocolStdout: File
    shimProtocolStdoutPreserved = false
    shimSavedFd: cint = -1
      ## The descriptor ``shimProtocolStdout`` writes to: a duplicate of the
      ## original descriptor 1.
    shimStdoutDiverted = false

  proc entrySelectorName*(): tuple[name: string; taken: int] =
    ## The entry nim-entrypoints' run-time selector names: the FIRST argument
    ## ``--entrypoint=<name>`` (one argument taken) or ``--entrypoint <name>``
    ## (two). ``taken`` is 0 when the arguments select no entry. Only the
    ## first argument is a selector, as in nim-entrypoints, so a test filter
    ## or a program option further on is never read as one.
    if paramCount() >= 1:
      let first = paramStr(1)
      if first.startsWith("--entrypoint="):
        return (first["--entrypoint=".len .. ^1], 1)
      if first == "--entrypoint":
        if paramCount() >= 2:
          return (paramStr(2), 2)
        return ("", 1)

  proc shimClaimsStdout(): bool =
    ## Match the shim's first-protocol-flag-wins parser.  Keeping the duplicate
    ## list-only avoids adding a spare descriptor to ordinary test execution.
    ## Under the tests entry the listing flags are ``--list`` and
    ## ``--list-test-cases``, and the entry list (``--entrypoint=list``) is a
    ## document too.
    let selector = entrySelectorName()
    if selector.taken > 0:
      if selector.name == "list":
        return true
      if selector.name != "tests":
        return false
      for i in selector.taken + 1 .. paramCount():
        if paramStr(i) in ["--list", "--list-test-cases"]:
          return true
      return false
    var i = 1
    while i <= paramCount():
      let argument = paramStr(i)
      if argument == "--list" or argument == "--list-json":
        return true
      if argument == "--run" or argument.startsWith("--run="):
        return false
      inc i

  proc preserveShimProtocolStdout() =
    if not shimClaimsStdout():
      return
    let outFd = cint(getFileHandle(stdout))
    let errFd = cint(getFileHandle(stderr))
    flushFile(stdout)
    let saved = shimDupFd(outFd)
    if saved < 0:
      return
    if saved == errFd:
      # stderr was closed, so the duplicate took descriptor 2.  Treat that as
      # an unavailable separate channel rather than confusing output streams.
      discard shimCloseFd(saved)
      return
    var preserved: File
    if not open(preserved, FileHandle(saved), fmWrite):
      discard shimCloseFd(saved)
      return
    shimProtocolStdout = preserved
    shimProtocolStdoutPreserved = true
    shimSavedFd = saved

  preserveShimProtocolStdout()

  proc writeShimProtocolLine*(line: string) =
    ## Write only the machine-readable document to the pre-redirection stream.
    if shimProtocolStdoutPreserved:
      shimProtocolStdout.write(line)
      shimProtocolStdout.write("\n")
      flushFile(shimProtocolStdout)
    else:
      echo line

  proc restoreEntryStdout*() =
    ## Point descriptor 1 back at the original standard output, undoing the
    ## fork's redirection, so that a list printed on descriptor 1 (by
    ## nim-entrypoints' tests entry) reaches standard output. Called once the
    ## fork has initialised (this module's importer imports ``std/unittest``
    ## first). A no-op when nothing was preserved: no listing was asked for,
    ## or descriptor 1 already pointed elsewhere when this module started.
    if not shimProtocolStdoutPreserved:
      return
    flushFile(stdout)
    if shimDup2Fd(shimSavedFd, cint(getFileHandle(stdout))) >= 0:
      shimStdoutDiverted = false

  proc divertStdoutToStderr*() =
    ## Point descriptor 1 at standard error for the rest of the process, so
    ## that output of the test module (a suite body runs while its tests are
    ## listed) cannot reach the list the shim prints through
    ## ``writeShimProtocolLine``. Only meaningful when that stream was
    ## preserved; idempotent.
    if not shimProtocolStdoutPreserved or shimStdoutDiverted:
      return
    flushFile(stdout)
    if shimDup2Fd(cint(getFileHandle(stderr)),
        cint(getFileHandle(stdout))) >= 0:
      shimStdoutDiverted = true

else:
  proc entrySelectorName*(): tuple[name: string; taken: int] =
    ## No argument vector on this backend: no entry is ever selected.
    ("", 0)

  proc writeShimProtocolLine*(line: string) =
    echo line

  proc restoreEntryStdout*() =
    discard

  proc divertStdoutToStderr*() =
    discard
