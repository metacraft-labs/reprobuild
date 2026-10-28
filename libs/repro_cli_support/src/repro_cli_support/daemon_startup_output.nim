## Nonblocking, bounded diagnostics from invocation-owned POSIX daemons.
## Drain both pipes while waiting for readiness: reading only after exit can
## deadlock a child whose refusal fills either pipe before it can exit.
import std/[os, strutils]
import std/posix

const startupOutputLimit = 64 * 1024

type StartupOutput* = object
  text: string
  truncated: bool

proc prepareStartupOutput*(fd: cint) =
  ## Make the read end nonblocking without changing its other file flags.
  let flags = fcntl(fd, F_GETFL)
  if flags < 0 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0:
    raiseOSError(osLastError(), "cannot capture runquotad startup output")

proc drainStartupOutput*(output: var StartupOutput; fd: cint) =
  ## A finite drain also bounds work if a broken child writes continuously.
  ## Retain the tail: the refusal is generally the last thing a daemon says.
  var buffer: array[4096, char]
  var remaining = 256 * 1024
  while remaining > 0:
    let count = posix.read(fd, addr buffer[0], buffer.len)
    if count <= 0:
      if count < 0 and errno == EINTR:
        continue
      return
    remaining -= int(count)
    let oldLen = output.text.len
    output.text.setLen(oldLen + int(count))
    copyMem(addr output.text[oldLen], addr buffer[0], int(count))
    if output.text.len > startupOutputLimit:
      output.text = output.text[^startupOutputLimit .. ^1]
      output.truncated = true

proc startupDiagnostic*(output: StartupOutput; label: string): string =
  ## Label retained output and disclose any bytes excluded by the bound.
  if output.text.len > 0:
    result = "\nrunquotad " & label & ":\n" &
      (if output.truncated: "[truncated; last 65536 bytes]\n" else: "") &
      output.text.strip(leading = false)
