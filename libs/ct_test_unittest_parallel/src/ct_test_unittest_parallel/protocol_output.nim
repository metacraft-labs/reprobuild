## Preserve the process's real stdout before ``std/unittest`` initialises.
##
## The protocol-carrying codetracer Nim fork reserves stdout for its own
## ``--list``/``--list-json`` document at module initialisation: it duplicates
## descriptor 1, then points descriptor 1 at stderr so arbitrary suite-body
## output cannot corrupt the document.  ``ct_test_unittest_parallel`` owns a
## separate protocol registry and exit hook, so its document cannot use the
## fork's private saved descriptor.  This leaf module is deliberately imported
## before ``std/unittest`` and retains the same original stream for the shim.

import std/[os, strutils]

when declared(stdout):
  when defined(windows):
    proc shimDupFd(fd: cint): cint {.importc: "_dup", header: "<io.h>".}
    proc shimCloseFd(fd: cint): cint {.importc: "_close", header: "<io.h>".}
  else:
    proc shimDupFd(fd: cint): cint {.importc: "dup", header: "<unistd.h>".}
    proc shimCloseFd(fd: cint): cint {.importc: "close", header: "<unistd.h>".}

  var
    shimProtocolStdout: File
    shimProtocolStdoutPreserved = false

  proc shimClaimsStdout(): bool =
    ## Match the shim's first-protocol-flag-wins parser.  Keeping the duplicate
    ## list-only avoids adding a spare descriptor to ordinary test execution.
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

  preserveShimProtocolStdout()

  proc writeShimProtocolLine*(line: string) =
    ## Write only the machine-readable document to the pre-redirection stream.
    if shimProtocolStdoutPreserved:
      shimProtocolStdout.write(line)
      shimProtocolStdout.write("\n")
      flushFile(shimProtocolStdout)
    else:
      echo line

else:
  proc writeShimProtocolLine*(line: string) =
    echo line
